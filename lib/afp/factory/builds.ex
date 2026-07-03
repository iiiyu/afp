# @input  - Ready harness packets, app repos under the afp-app-repo/v1 contract
# @output - Supervised agent build runs with verify-gated evidence ingestion
# @pos    - Context boundary for the BuildRunner execution loop (Sprint C v0)
defmodule Afp.Factory.Builds do
  import Ecto.Query

  alias Afp.Factory
  alias Afp.Factory.Builds.AppRepo
  alias Afp.Factory.Builds.BuildRun
  alias Afp.Factory.Builds.VerifyRunner
  alias Afp.Factory.Demand.CodexAppClient
  alias Afp.Factory.Events
  alias Afp.Factory.Evidence
  alias Afp.Factory.Opportunities.ClaudeCodeClient
  alias Afp.Factory.Work
  alias Afp.Factory.Work.HarnessPacket
  alias Afp.Repo

  @codex_launch_supervisor Afp.Factory.Demand.CodexLaunchSupervisor
  @agents ~w(claude_code codex)

  # Build toolchain commands the agent may run on top of the client's safe
  # defaults. Destructive patterns stay denied by the client; scripts without
  # an executable bit are reachable via `sh Scripts/...`.
  @build_bash_allow [
    "xcodebuild *",
    "xcrun *",
    "swift *",
    "xcodegen *",
    "xcbeautify *",
    "make *",
    "jq *",
    "sips *",
    "plutil *",
    "touch *",
    "Scripts/*",
    "./Scripts/*",
    "sh Scripts/*",
    "bash Scripts/*",
    "git status*",
    "git diff*",
    "git log*",
    "git show*",
    "git add *",
    "git commit *"
  ]

  def agents, do: @agents

  def list_build_runs(params \\ %{}) do
    BuildRun
    |> preload([:app, :harness_packet, :ticket])
    |> apply_filter(:app_id, Map.get(params, "app_id") || Map.get(params, :app_id))
    |> apply_filter(
      :harness_packet_id,
      Map.get(params, "harness_packet_id") || Map.get(params, :harness_packet_id)
    )
    |> apply_filter(:status, Map.get(params, "status") || Map.get(params, :status))
    |> order_by([run], desc: run.inserted_at)
    |> Repo.all()
  end

  def get_build_run!(id) do
    BuildRun
    |> Repo.get!(id)
    |> Repo.preload([:app, :harness_packet, :ticket, :evidence_packet])
  end

  defdelegate inspect_app_repo(repo_path), to: AppRepo, as: :inspect_repo

  @doc """
  Launches a ready harness packet as a supervised agent build run.

  Preflights the packet's repo against the afp-app-repo/v1 contract, records
  a `BuildRun`, marks the packet launched (`launch_mode: "supervised"`), and
  runs the agent turn + verify chain sync or async per `:build_launch_mode`.
  """
  def launch_packet(%HarnessPacket{} = packet, opts \\ []) do
    repo_path = packet.repository_path

    with :ok <- ensure_launchable(packet),
         %{health_state: "healthy", manifest: manifest} <- AppRepo.inspect_repo(repo_path),
         {:ok, run} <- create_build_run(packet, manifest, opts),
         {:ok, _packet} <- mark_packet_launched(packet) do
      start_build_run(run, opts)
    else
      %{health_state: state, notes: notes} -> {:error, {:repo_unhealthy, state, notes}}
      {:error, reason} -> {:error, reason}
    end
  end

  def complete_build_run(run_id, opts \\ []) do
    run = get_build_run!(run_id)

    {:ok, run} = update_build_run(run, %{status: "running", started_at: Factory.now()})
    record_run_event(run, "build_run_started")

    attrs = agent_launch_attrs(run)

    launch_result =
      launch_client(run.agent, opts).launch_new_turn(attrs, launch_opts(opts))

    case launch_result do
      {:ok, result} -> handle_agent_success(run, result, opts)
      {:error, reason} -> fail_build_run(run, {:agent_failed, reason})
    end
  rescue
    error -> fail_build_run(get_build_run!(run_id), {:unhandled, Exception.message(error)})
  catch
    kind, reason -> fail_build_run(get_build_run!(run_id), {:unhandled, {kind, reason}})
  end

  defp ensure_launchable(%HarnessPacket{} = packet) do
    cond do
      packet.state not in ["ready", "launched"] -> {:error, :packet_not_ready}
      Factory.blank?(packet.repository_path) -> {:error, :repository_path_missing}
      is_nil(packet.app_id) -> {:error, :app_missing}
      true -> :ok
    end
  end

  defp create_build_run(packet, manifest, opts) do
    %BuildRun{}
    |> BuildRun.changeset(%{
      status: "queued",
      agent: launch_agent(opts),
      model: Keyword.get(opts, :model),
      repository_path: packet.repository_path,
      prompt: build_prompt(packet, manifest),
      app_id: packet.app_id,
      harness_packet_id: packet.id,
      ticket_id: packet.ticket_id
    })
    |> Repo.insert()
  end

  defp mark_packet_launched(packet) do
    Work.update_harness_packet(packet, %{
      "state" => "launched",
      "launch_mode" => "supervised"
    })
  end

  defp start_build_run(run, opts) do
    case launch_mode(opts) do
      :sync ->
        complete_build_run(run.id, opts)

      :async ->
        Task.Supervisor.start_child(@codex_launch_supervisor, fn ->
          complete_build_run(run.id, opts)
        end)

        {:ok, run}
    end
  end

  defp handle_agent_success(run, result, opts) do
    {:ok, run} =
      update_build_run(run, %{
        status: "verifying",
        final_answer: result[:final_answer],
        agent_payload: agent_payload(result)
      })

    manifest = current_manifest(run)

    case VerifyRunner.run(Factory.expand_path(run.repository_path), manifest, opts) do
      {:ok, verify_result} -> finish_build_run(run, verify_result)
      {:error, reason} -> fail_build_run(run, {:verify_failed, reason})
    end
  end

  defp finish_build_run(run, verify_result) do
    {:ok, evidence_packet} = ingest_evidence(run, verify_result)

    {:ok, run} =
      update_build_run(run, %{
        status: "completed",
        verify_result: verify_result,
        evidence_packet_id: evidence_packet && evidence_packet.id,
        finished_at: Factory.now()
      })

    route_packet_to_review(run, verify_result)
    record_run_event(run, "build_run_completed", %{verify_pass: verify_result["pass"]})
    {:ok, run}
  end

  defp fail_build_run(run, reason) do
    {:ok, run} =
      update_build_run(run, %{
        status: "failed",
        error: inspect(reason, limit: :infinity, printable_limit: 2_000),
        finished_at: Factory.now()
      })

    record_run_event(run, "build_run_failed")
    {:error, reason}
  end

  defp ingest_evidence(run, verify_result) do
    links =
      [%{subject_type: "harness_packet", subject_id: run.harness_packet_id}] ++
        if run.ticket_id do
          [%{subject_type: "ticket", subject_id: run.ticket_id, link_reason: "build_run_verify"}]
        else
          []
        end

    attrs = %{
      app_id: run.app_id,
      type: "command_log",
      title: "Verify report — #{verify_verdict(verify_result)}",
      summary: verify_summary(verify_result),
      source_path: Path.join(run.repository_path, verify_result["report_path"] || ""),
      reliability: if(verify_result["pass"] == true, do: "verified", else: "high"),
      payload: %{"verify" => verify_result, "build_run_id" => run.id}
    }

    case Evidence.create_evidence_packet(attrs, links) do
      {:ok, packet, _links} -> {:ok, packet}
      {:error, _changeset} -> {:ok, nil}
    end
  end

  defp route_packet_to_review(run, verify_result) do
    packet = Work.get_harness_packet!(run.harness_packet_id)

    Work.update_harness_packet(packet, %{
      "state" => "review",
      "result_summary" => verify_summary(verify_result)
    })
  end

  defp verify_verdict(%{"pass" => true}), do: "pass"
  defp verify_verdict(_verify_result), do: "fail"

  defp verify_summary(verify_result) do
    gates =
      verify_result
      |> Map.get("gates", [])
      |> Enum.map_join(", ", fn gate -> "#{gate["id"]}=#{gate["status"]}" end)

    "verify #{verify_verdict(verify_result)} (#{gates})"
  end

  defp build_prompt(packet, manifest) do
    entrypoint = AppRepo.verify_entrypoint(manifest)

    """
    You are executing a build harness packet inside an AFP app repo
    (contract #{AppRepo.contract()}).

    Read `AGENTS.md` first and follow it exactly, then `afp/manifest.json`.
    `#{entrypoint}` is the only oracle: run it and treat the work as done
    only when its report says pass. On red gates read the distilled failure
    summaries, not raw logs. Record milestone results in the repo state db
    per the AGENTS.md recording contract.

    #{Work.handoff_text(packet)}
    """
    |> String.trim()
  end

  defp agent_launch_attrs(run) do
    repo_path = Factory.expand_path(run.repository_path)
    manifest = current_manifest(run)

    %{
      cwd: repo_path,
      input_text: run.prompt,
      model: run.model,
      client_user_message_id: run.id,
      approval_policy: "on-request",
      sandbox_mode: "workspace-write",
      source_repo_root: repo_path,
      extra_bash_allow: @build_bash_allow,
      sqlite_path: AppRepo.state_db_path(manifest),
      network_access: true,
      sandbox_policy: %{
        "type" => "workspaceWrite",
        "writableRoots" => [repo_path],
        "networkAccess" => true,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }
    }
  end

  defp current_manifest(run) do
    case AppRepo.inspect_repo(run.repository_path) do
      %{manifest: manifest} when map_size(manifest) > 0 -> manifest
      _result -> %{}
    end
  end

  defp agent_payload(result) do
    thread = get_in(result, [:thread_response, "result", "thread"]) || %{}
    turn = get_in(result, [:turn_completed, "params", "turn"]) || %{}

    %{
      "session_id" => thread["sessionId"] || thread["id"],
      "thread_id" => thread["id"],
      "turn_id" => turn["id"],
      "turn_status" => turn["status"],
      "transcript_path" => thread["path"]
    }
  end

  defp update_build_run(run, attrs) do
    run
    |> BuildRun.changeset(attrs)
    |> Repo.update()
  end

  defp record_run_event(run, event_type, payload \\ %{}) do
    Events.record_event(
      "build_run",
      run.id,
      event_type,
      Map.merge(
        %{
          app_id: run.app_id,
          harness_packet_id: run.harness_packet_id,
          status: run.status
        },
        payload
      )
    )
  end

  defp launch_agent(opts) do
    agent = Keyword.get(opts, :agent, "claude_code")
    if agent in @agents, do: agent, else: "claude_code"
  end

  defp launch_mode(opts) do
    Keyword.get(opts, :mode) || Application.get_env(:afp, :build_launch_mode, :async)
  end

  defp launch_opts(opts) do
    Keyword.take(opts, [:timeout_ms, :on_launch_event, :claude_executable])
  end

  defp launch_client(agent, opts) do
    Keyword.get(opts, :client) || launch_client(agent)
  end

  defp launch_client("claude_code") do
    Application.get_env(:afp, :claude_code_client, ClaudeCodeClient)
  end

  defp launch_client(_agent) do
    Application.get_env(:afp, :codex_app_client, CodexAppClient)
  end

  defp apply_filter(query, _field, value) when value in [nil, ""], do: query

  defp apply_filter(query, field, value),
    do: where(query, [record], field(record, ^field) == ^value)
end
