# @input  - Portfolio apps whose repos follow afp-app-repo/v1, and launch requests
# @output - Supervised milestone/task build runs with AFP-authoritative verify
# @pos    - Context boundary for the execution layer (docs/build-runner-v2-design.md)
defmodule Afp.Factory.Builds do
  require Logger

  alias Afp.Factory
  alias Afp.Factory.AgentClient
  alias Afp.Factory.Builds.AppRepo
  alias Afp.Factory.Builds.BuildRun
  alias Afp.Factory.Builds.Storage
  alias Afp.Factory.Builds.VerifyQueue
  alias Afp.Factory.Builds.VerifyRunner
  alias Afp.Factory.CodexAppClient
  alias Afp.Factory.Events
  alias Afp.Factory.Opportunities.ClaudeCodeClient
  alias Afp.Factory.Portfolio.App

  @launch_supervisor Afp.Factory.AgentLaunchSupervisor
  @agents ~w(claude_code codex)
  @default_agent "claude_code"
  @stale_grace_ms 10 * 60 * 1000
  @stale_hard_ms 4 * 60 * 60 * 1000

  # Build-toolchain commands on top of the CommandPolicy defaults. Destructive
  # patterns stay denied; scripts without an executable bit run via `sh Scripts/...`.
  @build_command_allow [
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

  defdelegate inspect_app_repo(repo_path), to: AppRepo, as: :inspect_repo

  def list_milestones(%App{} = app) do
    with {:ok, repo} <- healthy_repo(app),
         {:ok, milestones} <- Storage.list_milestones(repo.db_path) do
      milestones
    else
      _error -> []
    end
  end

  def list_runs(%App{} = app) do
    with {:ok, repo} <- healthy_repo(app),
         {:ok, runs} <- Storage.list_runs(repo.db_path) do
      runs
    else
      _error -> []
    end
  end

  @doc """
  Why the app cannot launch right now, or nil when it can:
  `{:active_run, run}` (per-app serial) or `{:unreviewed_run, run}` (the hard
  review gate — a completed run must be marked reviewed first).
  """
  def launch_blocked(%App{} = app) do
    runs = list_runs(app)

    cond do
      run = Enum.find(runs, &BuildRun.active?/1) -> {:active_run, run}
      run = Enum.find(runs, &BuildRun.awaiting_review?/1) -> {:unreviewed_run, run}
      true -> nil
    end
  end

  @doc "Launches the agent against a repo milestone (`implement-milestone` skill)."
  def launch_milestone(%App{} = app, milestone_key, opts \\ []) do
    with {:ok, repo} <- healthy_repo(app),
         :ok <- ensure_launchable(app),
         {:ok, milestone} <- Storage.get_milestone(repo.db_path, milestone_key),
         :ok <- ensure_milestone_launchable(milestone) do
      prompt = milestone_prompt(repo.manifest, milestone_key)
      start_run(app, repo, %{milestone_key: milestone_key, prompt: prompt}, opts)
    end
  end

  @doc "Launches an ad-hoc free-text task (the retrofit fallback)."
  def launch_task(%App{} = app, task_text, opts \\ []) do
    task_text = Factory.trim_nil(task_text)

    with :ok <- ensure_task_text(task_text),
         {:ok, repo} <- healthy_repo(app),
         :ok <- ensure_launchable(app) do
      prompt = task_prompt(repo.manifest, task_text)
      start_run(app, repo, %{task_text: task_text, prompt: prompt}, opts)
    end
  end

  @doc "Marks a completed run reviewed — the hard gate for the next launch."
  def mark_run_reviewed(%App{} = app, run_id) do
    with {:ok, repo} <- healthy_repo(app),
         {:ok, run} <- Storage.get_run(repo.db_path, run_id),
         :ok <- ensure_reviewable(run),
         :ok <- Storage.mark_run_reviewed(repo.db_path, run_id) do
      record_run_event(app, run_id, "build_run_reviewed", %{subject: BuildRun.subject(run)})
      Storage.get_run(repo.db_path, run_id)
    end
  end

  @doc "Operator escape hatch for hung runs."
  def force_fail_run(%App{} = app, run_id) do
    with {:ok, repo} <- healthy_repo(app),
         {:ok, run} <- Storage.get_run(repo.db_path, run_id),
         true <- BuildRun.active?(run) || {:error, :run_not_active} do
      fail_run(app, repo.db_path, run, "operator force-failed the run")
      Storage.get_run(repo.db_path, run_id)
    end
  end

  @doc """
  Fails zombie runs: active runs past the grace window with no agent session,
  or active runs past the hard timeout. Called on detail-page load.
  """
  def reconcile_stale_runs(%App{} = app) do
    case healthy_repo(app) do
      {:ok, repo} ->
        now = Factory.now()

        app
        |> list_runs()
        |> Enum.filter(&BuildRun.active?/1)
        |> Enum.filter(&stale?(&1, now))
        |> Enum.each(&fail_run(app, repo.db_path, &1, "stale run reconciled"))

        :ok

      _unhealthy ->
        :ok
    end
  end

  @doc "Report files (`afp/reports/*.md`) for the detail page preview."
  def list_report_files(%App{} = app) do
    with {:ok, repo} <- healthy_repo(app),
         {:ok, entries} <- File.ls(Path.join(repo.path, AppRepo.reports_dir(repo.manifest))) do
      entries |> Enum.filter(&String.ends_with?(&1, ".md")) |> Enum.sort(:desc)
    else
      _error -> []
    end
  end

  def read_report_file(%App{} = app, name) do
    with {:ok, repo} <- healthy_repo(app),
         :ok <- ensure_safe_name(name) do
      File.read(Path.join([repo.path, AppRepo.reports_dir(repo.manifest), name]))
    end
  end

  defp start_run(app, repo, attrs, opts) do
    run_id = Ecto.UUID.generate()
    agent = launch_agent(opts)

    with {:ok, run} <-
           Storage.insert_run(repo.db_path, %{
             id: run_id,
             milestone_key: attrs[:milestone_key],
             task_text: attrs[:task_text],
             agent: agent,
             prompt: attrs.prompt
           }) do
      if attrs[:milestone_key],
        do: Storage.set_milestone_in_progress(repo.db_path, attrs[:milestone_key])

      record_run_event(app, run_id, "build_run_queued", %{
        agent: agent,
        subject: BuildRun.subject(run)
      })

      case launch_mode(opts) do
        :sync ->
          complete_run(app, repo, run, opts)

        :async ->
          Task.Supervisor.start_child(@launch_supervisor, fn ->
            complete_run(app, repo, run, opts)
          end)

          {:ok, run}
      end
    end
  end

  defp complete_run(app, repo, run, opts) do
    :ok = Storage.mark_run_started(repo.db_path, run.id)
    record_run_event(app, run.id, "build_run_started", %{})

    request = launch_request(repo, run)

    launch_opts =
      opts
      |> Keyword.take([:timeout_ms, :claude_executable, :codex_executable])
      |> Keyword.put(:on_launch_event, fn event, payload ->
        handle_launch_event(app, repo.db_path, run.id, event, payload)
      end)

    case launch_client(run.agent, opts).launch_new_turn(request, launch_opts) do
      {:ok, result} -> verify_and_complete(app, repo, run, result)
      {:error, reason} -> {:error, fail_run(app, repo.db_path, run, inspect(reason))}
    end
  rescue
    exception ->
      {:error, fail_run(app, repo.db_path, run, Exception.message(exception))}
  catch
    kind, reason ->
      {:error, fail_run(app, repo.db_path, run, inspect({kind, reason}))}
  end

  defp verify_and_complete(app, repo, run, result) do
    :ok = Storage.mark_run_verifying(repo.db_path, run.id, result)
    record_run_event(app, run.id, "build_run_verifying", %{})

    case VerifyQueue.run(fn -> VerifyRunner.run(repo.path, repo.manifest) end) do
      {:ok, report} ->
        pass = report["pass"] == true
        :ok = Storage.mark_run_completed(repo.db_path, run.id, Jason.encode!(report), pass)

        record_run_event(app, run.id, "build_run_completed", %{
          verify_pass: pass,
          subject: BuildRun.subject(run)
        })

        Storage.get_run(repo.db_path, run.id)

      {:error, reason} ->
        {:error, fail_run(app, repo.db_path, run, "verify failed: #{inspect(reason)}")}
    end
  end

  defp handle_launch_event(_app, db_path, run_id, :thread_started, payload) do
    Storage.mark_run_session(db_path, run_id, payload)
    :ok
  end

  defp handle_launch_event(_app, db_path, run_id, :turn_started, payload) do
    Storage.mark_run_turn(db_path, run_id, payload.turn_id)
    :ok
  end

  defp handle_launch_event(app, _db_path, run_id, :activity, payload) when is_map(payload) do
    Events.broadcast_build_activity(app.id, run_id, payload)
    :ok
  end

  defp handle_launch_event(_app, _db_path, _run_id, _event, _payload), do: :ok

  defp fail_run(app, db_path, run, error_text) do
    Storage.mark_run_failed(db_path, run.id, error_text)
    Storage.reset_milestone_pending(db_path, run.milestone_key)

    record_run_event(app, run.id, "build_run_failed", %{
      reason: String.slice(error_text, 0, 500),
      subject: BuildRun.subject(run)
    })

    Logger.warning("Build run failed", app_id: app.id, run_id: run.id, reason: error_text)
    {:build_run_failed, run.id}
  end

  defp healthy_repo(%App{repo_path: repo_path}) do
    case AppRepo.inspect_repo(repo_path) do
      %{health_state: "healthy", manifest: manifest} ->
        path = Factory.expand_path(repo_path)
        db_path = Path.join(path, AppRepo.state_db_path(manifest))
        :ok = Storage.ensure_schema(db_path)
        {:ok, %{path: path, manifest: manifest, db_path: db_path}}

      %{health_state: state, notes: notes} ->
        {:error, {:repo_unhealthy, state, notes}}
    end
  end

  defp ensure_launchable(app) do
    case launch_blocked(app) do
      nil -> :ok
      {:active_run, run} -> {:error, {:active_run, run.id}}
      {:unreviewed_run, run} -> {:error, {:unreviewed_run, run.id}}
    end
  end

  defp ensure_milestone_launchable(milestone) do
    if Afp.Factory.Builds.Milestone.launchable?(milestone) do
      :ok
    else
      {:error, {:milestone_not_launchable, milestone.status}}
    end
  end

  defp ensure_reviewable(%BuildRun{status: "completed"}), do: :ok
  defp ensure_reviewable(%BuildRun{status: status}), do: {:error, {:run_not_completed, status}}

  defp ensure_task_text(nil), do: {:error, :task_text_required}
  defp ensure_task_text(_text), do: :ok

  defp ensure_safe_name(name) do
    if is_binary(name) and name != "" and Path.basename(name) == name and
         String.ends_with?(name, ".md") do
      :ok
    else
      {:error, :invalid_report_name}
    end
  end

  defp stale?(run, now) do
    age = run_age_ms(run, now)

    (is_nil(run.agent_session_id) and age > @stale_grace_ms) or age > @stale_hard_ms
  end

  defp run_age_ms(run, now) do
    case DateTime.from_iso8601(run.updated_at || "") do
      {:ok, updated_at, _offset} -> DateTime.diff(now, updated_at, :millisecond)
      _error -> 0
    end
  end

  # Thin prompt: the repo owns the instructions (AGENTS.md + skills); AFP only
  # injects identity and the entrypoint pointer (design decision 3).
  defp milestone_prompt(manifest, milestone_key) do
    """
    You are working inside an AFP app repo (contract #{AppRepo.contract()}).

    Read `AGENTS.md` first and follow it exactly, then `afp/manifest.json`.
    Execute exactly one milestone by following `.skills/implement-milestone/SKILL.md`.

    MILESTONE_KEY: #{milestone_key}
    VERIFY_ENTRYPOINT: #{AppRepo.verify_entrypoint(manifest)}
    """
    |> String.trim()
  end

  # Retrofit fallback: repos without build skills get the operating rules inline.
  defp task_prompt(manifest, task_text) do
    """
    You are working inside an AFP app repo (contract #{AppRepo.contract()}).

    Read `AGENTS.md` first, then `afp/manifest.json`.

    TASK:
    #{task_text}

    Operating rules:
    1. `#{AppRepo.verify_entrypoint(manifest)}` is the only oracle. Run it in the
       foreground and wait; work is done only when its report says pass.
    2. You have exactly one turn. Never launch background work expecting to
       resume — nothing resumes, and a follow-up verify runs on this machine
       after your turn, so leaving processes running will corrupt it.
    3. Commit only after the oracle reports pass. If you cannot reach pass,
       leave the work uncommitted and state exactly what is red and why.
    4. Do not touch signing configuration, credentials, or release scripts.
    """
    |> String.trim()
  end

  defp launch_request(repo, run) do
    %AgentClient.Request{
      cwd: repo.path,
      input_text: run.prompt,
      client_user_message_id: run.id,
      source_repo_root: repo.path,
      sqlite_path: AppRepo.state_db_path(repo.manifest),
      network_access: true,
      extra_command_allow: @build_command_allow
    }
  end

  defp record_run_event(app, run_id, event_type, payload) do
    Events.record_event(
      "build_run",
      run_id,
      event_type,
      Map.merge(%{app_id: app.id, app_name: app.name}, payload)
    )
  end

  defp launch_agent(opts) do
    agent = Keyword.get(opts, :agent, @default_agent)
    if agent in @agents, do: agent, else: @default_agent
  end

  defp launch_mode(opts) do
    case Keyword.get(opts, :mode, Application.get_env(:afp, :build_launch_mode, :async)) do
      :sync -> :sync
      "sync" -> :sync
      _mode -> :async
    end
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
end
