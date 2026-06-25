# @input  - A configured opportunity repo, opportunity/run maps, and launch opts
# @output - Sync/async agent launches with run+opportunity state persisted to SQLite
# @pos    - Agent-run launch orchestration for opportunities (Codex / Claude Code)
defmodule Afp.Factory.Opportunities.AgentRun do
  @moduledoc """
  Runs an opportunity research or build-spec turn through the chosen agent
  (Codex app-server or the Claude Code CLI), synchronously or under a
  Task.Supervisor, and persists the run/opportunity state transitions (started,
  progress, success, failure) to the repo-local `base.sqlite`. Resolves the
  agent client and refreshes the file index on success via `Opportunities.Files`.
  """

  require Logger

  alias Afp.Factory
  alias Afp.Factory.Demand.CodexAppClient
  alias Afp.Factory.Events
  alias Afp.Factory.Opportunities
  alias Afp.Factory.Opportunities.ClaudeCodeClient
  alias Afp.Factory.Opportunities.Files
  alias Afp.Factory.Opportunities.Storage

  @default_agent "claude_code"
  @codex_launch_supervisor Afp.Factory.Demand.CodexLaunchSupervisor
  @base_sqlite_path "base.sqlite"
  @opportunities_path "opportunities"
  @skills_path ".skills"

  def start_agent_run(repo, opportunity, run, opts) do
    agent = run["agent"] || @default_agent

    case launch_mode(opts) do
      :sync ->
        case complete_agent_run(repo, opportunity, run, opts) do
          {:ok, completion} ->
            {:ok, Map.merge(completion, %{opportunity: fetch_opportunity!(opportunity["id"])})}

          {:error, reason} ->
            {:error, reason}
        end

      :async ->
        with :ok <- ensure_codex_launch_supervisor(),
             {:ok, pid} <-
               safe_start_codex_launch_worker(fn ->
                 complete_agent_run(repo, opportunity, run, opts)
               end) do
          {:ok, %{opportunity: opportunity, run: run, launch_worker_pid: pid}}
        else
          {:error, reason} ->
            mark_agent_run_failed(repo, opportunity["id"], run, agent, reason)
            {:error, reason}
        end
    end
  end

  defp complete_agent_run(repo, opportunity, run, opts) do
    agent = run["agent"] || @default_agent
    persist_agent_run_started(repo, opportunity["id"], run["id"], agent)

    attrs = agent_launch_attrs(repo, opportunity, run)

    opts =
      opts
      |> Keyword.drop([:mode, :supervisor])
      |> Keyword.put(:on_launch_event, fn event, payload ->
        persist_agent_progress(repo, opportunity["id"], run["id"], agent, event, payload)
      end)

    case launch_client(agent).launch_new_turn(attrs, opts) do
      {:ok, launch_result} ->
        persist_agent_success(repo, opportunity["id"], run, agent, launch_result)

      {:error, reason} ->
        mark_agent_run_failed(repo, opportunity["id"], run, agent, reason)
        {:error, reason}
    end
  rescue
    exception ->
      reason = {:agent_launch_unhandled_failure, Exception.message(exception)}
      mark_agent_run_failed(repo, opportunity["id"], run, run["agent"], reason)
      {:error, reason}
  catch
    kind, reason ->
      failure = {:agent_launch_unhandled_failure, {kind, reason}}
      mark_agent_run_failed(repo, opportunity["id"], run, run["agent"], failure)
      {:error, failure}
  end

  defp launch_mode(opts) do
    case Keyword.get(opts, :mode, Application.get_env(:afp, :codex_launch_mode, :async)) do
      :sync -> :sync
      "sync" -> :sync
      _mode -> :async
    end
  end

  defp ensure_codex_launch_supervisor do
    if Process.whereis(@codex_launch_supervisor) do
      :ok
    else
      child_spec =
        Supervisor.child_spec({Task.Supervisor, name: @codex_launch_supervisor},
          id: @codex_launch_supervisor
        )

      safe_supervisor_call(fn -> Supervisor.start_child(Afp.Supervisor, child_spec) end)
      |> case do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, {:already_present, _id}} -> :ok
        {:error, reason} -> {:error, {:codex_launch_supervisor_start_failed, reason}}
      end
    end
  end

  defp safe_start_codex_launch_worker(fun) when is_function(fun, 0) do
    safe_supervisor_call(fn -> Task.Supervisor.start_child(@codex_launch_supervisor, fun) end)
  end

  defp safe_supervisor_call(fun) when is_function(fun, 0) do
    try do
      fun.()
    catch
      :exit, reason -> {:error, {:codex_launch_supervisor_exit, reason}}
    end
  end

  defp persist_agent_run_started(repo, opportunity_id, run_id, agent) do
    :ok =
      Storage.mark_run_started(
        repo,
        %{
          opportunity_id: opportunity_id,
          run_id: run_id,
          stage: "#{Opportunities.agent_label(agent)} starting"
        }
      )

    Events.record_event("opportunity_run", run_id, "opportunity_run_started", %{
      opportunity_id: opportunity_id
    })

    {:ok, %{run_id: run_id}}
  end

  defp persist_agent_progress(repo, opportunity_id, run_id, agent, :thread_started, payload) do
    thread = get_in(payload, ["result", "thread"]) || %{}
    session_id = thread["sessionId"] || thread["id"]

    :ok =
      Storage.mark_thread_started(
        repo,
        %{
          opportunity_id: opportunity_id,
          run_id: run_id,
          stage: "#{Opportunities.agent_label(agent)} session started",
          session_id: session_id,
          thread_id: thread["id"],
          transcript_path: thread["path"]
        }
      )

    Events.record_event("opportunity_run", run_id, "opportunity_run_thread_started", %{
      opportunity_id: opportunity_id,
      agent: agent,
      codex_session_id: session_id
    })

    :ok
  end

  defp persist_agent_progress(repo, opportunity_id, run_id, agent, :turn_started, payload) do
    turn = get_in(payload, ["result", "turn"]) || %{}

    :ok =
      Storage.mark_turn_started(
        repo,
        %{
          opportunity_id: opportunity_id,
          run_id: run_id,
          stage: "#{Opportunities.agent_label(agent)} turn started",
          turn_id: turn["id"]
        }
      )

    Events.record_event("opportunity_run", run_id, "opportunity_run_turn_started", %{
      opportunity_id: opportunity_id,
      agent: agent,
      codex_turn_id: turn["id"]
    })

    :ok
  end

  defp persist_agent_progress(_repo, opportunity_id, run_id, agent, :activity, payload)
       when is_map(payload) do
    Events.broadcast_run_activity(opportunity_id, run_id, Map.put(payload, "agent", agent))
    :ok
  end

  defp persist_agent_progress(_repo, _opportunity_id, _run_id, _agent, _event, _payload), do: :ok

  defp persist_agent_success(repo, opportunity_id, run, agent, launch_result) do
    run_id = run["id"]
    run_type = run["run_type"] || "initial_research"
    now = now_iso()
    thread = get_in(launch_result, [:thread_response, "result", "thread"]) || %{}
    turn = get_in(launch_result, [:turn_response, "result", "turn"]) || %{}
    completed_turn = get_in(launch_result, [:turn_completed, "params", "turn"]) || %{}
    session_id = thread["sessionId"] || thread["id"]
    final_answer = Map.get(launch_result, :final_answer)
    payload_json = Jason.encode!(agent_payload(agent, run["model"], launch_result, now))

    with :ok <- Files.refresh_index(repo, opportunity_id),
         :ok <-
           Storage.mark_run_completed(
             repo,
             %{
               opportunity_id: opportunity_id,
               run_id: run_id,
               stage: completion_stage(run_type, agent),
               opportunity_status: completion_status(run_type),
               session_id: session_id,
               thread_id: thread["id"],
               turn_id: turn["id"] || completed_turn["id"],
               transcript_path: thread["path"],
               final_answer: final_answer,
               payload_json: payload_json
             }
           ) do
      Events.record_event("opportunity_run", run_id, "opportunity_run_completed", %{
        opportunity_id: opportunity_id,
        agent: agent,
        codex_session_id: session_id
      })

      {:ok, %{run: fetch_run!(opportunity_id, run_id), codex_result: launch_result}}
    end
  end

  defp mark_agent_run_failed(repo, opportunity_id, run, agent, reason) do
    run_id = run["id"]
    run_type = run["run_type"] || "initial_research"
    error_text = inspect(reason)

    Storage.mark_run_failed(
      repo,
      %{
        opportunity_id: opportunity_id,
        run_id: run_id,
        stage: failure_stage(run_type, agent),
        opportunity_status: failure_status(run_type),
        error_text: error_text
      }
    )

    Events.record_event("opportunity_run", run_id, "opportunity_run_failed", %{
      opportunity_id: opportunity_id,
      agent: agent,
      reason: error_text
    })

    Logger.warning("Opportunity agent launch failed",
      opportunity_id: opportunity_id,
      run_id: run_id,
      agent: agent,
      reason: error_text
    )

    :ok
  end

  defp completion_stage("build_spec", _agent), do: "Build spec PRD completed"

  defp completion_stage(_run_type, agent),
    do: "Initial #{Opportunities.agent_label(agent)} research completed"

  defp completion_status("build_spec"), do: "build_spec_ready"
  defp completion_status(_run_type), do: "researched"

  defp failure_stage("build_spec", _agent), do: "Build spec PRD generation failed"

  defp failure_stage(_run_type, agent),
    do: "#{Opportunities.agent_label(agent)} launch failed"

  defp failure_status("build_spec"), do: "researched"
  defp failure_status(_run_type), do: "failed"

  defp agent_launch_attrs(repo, opportunity, run) do
    repo_path = repo["repo_path"]

    %{
      cwd: repo_path,
      input_text: run["prompt"],
      model: run["model"],
      opportunity_id: opportunity["id"],
      opportunity_run_id: run["id"],
      client_user_message_id: run["id"],
      approval_policy: "on-request",
      sandbox_mode: "workspace-write",
      source_repo_root: repo_path,
      write_targets: %{
        "opportunities" => @opportunities_path,
        "base_sqlite" => @base_sqlite_path,
        "skills" => @skills_path
      },
      sqlite_path: @base_sqlite_path,
      sqlite_allowed_operations: [
        "upsert_opportunity",
        "upsert_run",
        "upsert_step_result",
        "upsert_evidence",
        "link_file",
        "upsert_candidate"
      ],
      network_access: true,
      sandbox_policy: %{
        "type" => "workspaceWrite",
        "writableRoots" => [
          Path.join(repo_path, @opportunities_path),
          Path.join(repo_path, @base_sqlite_path),
          Path.join(repo_path, @skills_path)
        ],
        "networkAccess" => true,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }
    }
  end

  defp agent_payload(agent, model, launch_result, now) do
    thread = get_in(launch_result, [:thread_response, "result", "thread"]) || %{}
    turn = get_in(launch_result, [:turn_response, "result", "turn"]) || %{}
    completed_turn = get_in(launch_result, [:turn_completed, "params", "turn"]) || %{}

    %{
      "agent" => agent,
      "model" => model,
      "launch_status" => "completed",
      "session_id" => thread["sessionId"] || thread["id"],
      "thread_id" => thread["id"],
      "turn_id" => turn["id"] || completed_turn["id"],
      "turn_status" => completed_turn["status"],
      "transcript_path" => thread["path"],
      "final_answer" => Map.get(launch_result, :final_answer),
      "completed_at" => now
    }
  end

  defp fetch_opportunity!(id) do
    {:ok, opportunity} = Opportunities.get_opportunity(id)
    opportunity
  end

  defp fetch_run!(opportunity_id, run_id) do
    opportunity_id
    |> Opportunities.list_runs()
    |> Enum.find(&(&1["id"] == run_id))
  end

  defp launch_client("claude_code") do
    Application.get_env(:afp, :claude_code_client, ClaudeCodeClient)
  end

  defp launch_client(_agent) do
    Application.get_env(:afp, :codex_app_client, CodexAppClient)
  end

  defp now_iso, do: Factory.now() |> DateTime.to_iso8601()
end
