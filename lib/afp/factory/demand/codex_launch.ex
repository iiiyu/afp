# @input  - CodexLaunchRequest structs and launch opts (mode, supervisor, timeouts)
# @output - Synchronous/async Codex launches and stale-running-run reconciliation
# @pos    - Public orchestration entry for Demand's supervised Codex app-server launches
defmodule Afp.Factory.Demand.CodexLaunch do
  @moduledoc """
  Orchestrates supervised Codex app-server launches: validates the request,
  persists the started state, and runs the turn either synchronously or under a
  Task.Supervisor. Also reconciles research runs left "running" after a startup
  that never produced thread metadata. Delegates context loading to
  `CodexLaunchContext` and all persistence to `CodexLaunchRecords`.
  """

  import Ecto.Query

  alias Afp.Factory
  alias Afp.Factory.Demand
  alias Afp.Factory.Demand.CodexAppClient
  alias Afp.Factory.Demand.CodexLaunchContext, as: Context
  alias Afp.Factory.Demand.CodexLaunchRecords, as: Records
  alias Afp.Factory.Demand.CodexLaunchRequest
  alias Afp.Factory.Demand.ResearchRun
  alias Afp.Repo

  @codex_launch_supervisor Afp.Factory.Demand.CodexLaunchSupervisor

  def reconcile_stale_running_research_runs(opts \\ []) do
    now = Keyword.get(opts, :now, Factory.now())
    startup_grace_ms = Keyword.get(opts, :startup_grace_ms, codex_launch_startup_grace_ms())
    cutoff = DateTime.add(now, -div(startup_grace_ms, 1_000), :second)

    ResearchRun
    |> where([run], run.status == "running" and not is_nil(run.codex_launch_request_id))
    |> Repo.all()
    |> Repo.preload([:launch_request])
    |> Enum.filter(&stale_codex_startup_run?(&1, cutoff))
    |> Enum.map(&Records.mark_stale_codex_startup_failed(&1, now, startup_grace_ms))
  end

  def launch_research_request_with_codex(%CodexLaunchRequest{} = launch_request, opts \\ []) do
    with :ok <- Context.ensure_codex_launch_allowed(launch_request),
         {:ok, launch_context} <- Context.codex_launch_context(launch_request) do
      case codex_app_client().launch_new_turn(Context.codex_launch_attrs(launch_context), opts) do
        {:ok, codex_result} ->
          Records.persist_codex_launch_success(launch_context, codex_result)

        {:error, reason} = error ->
          Records.persist_codex_launch_failure(launch_context, reason)
          error
      end
    end
  end

  def start_research_request_with_codex(%CodexLaunchRequest{} = launch_request, opts \\ []) do
    with :ok <- Context.ensure_codex_launch_allowed(launch_request),
         {:ok, launch_context} <- Context.codex_launch_context(launch_request),
         {:ok, started_records} <- Records.persist_codex_launch_started(launch_context) do
      case codex_launch_mode(opts) do
        :sync ->
          case complete_codex_launch(started_records.launch_request.id, opts) do
            {:ok, completed_records} ->
              {:ok, Map.put(started_records, :completion, completed_records)}

            {:error, _reason} = error ->
              error
          end

        :async ->
          case start_codex_launch_worker(started_records.launch_request.id, opts) do
            {:ok, pid} ->
              {:ok, Map.put(started_records, :codex_launch_worker_pid, pid)}

            {:error, reason} ->
              Records.persist_codex_launch_worker_start_failure(launch_context, reason)
              {:error, reason}
          end
      end
    end
  end

  def complete_codex_launch(launch_request_id, opts \\ []) do
    do_complete_codex_launch(launch_request_id, opts)
  rescue
    exception ->
      persist_codex_launch_unhandled_failure(
        launch_request_id,
        {:error, Exception.message(exception)},
        __STACKTRACE__
      )
  catch
    kind, reason ->
      persist_codex_launch_unhandled_failure(launch_request_id, {kind, reason}, __STACKTRACE__)
  end

  defp do_complete_codex_launch(launch_request_id, opts) do
    launch_request = Demand.get_launch_request!(launch_request_id)

    with {:ok, launch_context} <- Context.codex_launch_context(launch_request) do
      case codex_app_client().launch_new_turn(
             Context.codex_launch_attrs(launch_context),
             codex_completion_opts(launch_request_id, opts)
           ) do
        {:ok, codex_result} ->
          Records.persist_codex_launch_success(launch_context, codex_result)

        {:error, reason} = error ->
          Records.persist_codex_launch_failure(launch_context, reason)
          error
      end
    end
  end

  defp persist_codex_launch_unhandled_failure(launch_request_id, reason, stacktrace) do
    failure_reason = {:codex_launch_unhandled_failure, reason}
    error_text = inspect(failure_reason) <> "\n\n" <> Exception.format_stacktrace(stacktrace)

    with {:ok, launch_context} <-
           Context.codex_launch_context(Demand.get_launch_request!(launch_request_id)) do
      Records.persist_codex_launch_failure(launch_context, error_text)
    end

    {:error, failure_reason}
  end

  defp codex_launch_mode(opts) do
    case Keyword.get(opts, :mode, Application.get_env(:afp, :codex_launch_mode, :async)) do
      :sync -> :sync
      "sync" -> :sync
      _mode -> :async
    end
  end

  defp start_codex_launch_worker(launch_request_id, opts) do
    supervisor = codex_launch_supervisor(opts)

    with :ok <- ensure_codex_launch_supervisor(supervisor) do
      safe_start_codex_launch_worker(supervisor, launch_request_id, opts)
    end
  end

  defp codex_launch_supervisor(opts) do
    Keyword.get(opts, :supervisor, @codex_launch_supervisor)
  end

  defp ensure_codex_launch_supervisor(@codex_launch_supervisor) do
    if Process.whereis(@codex_launch_supervisor) do
      :ok
    else
      start_default_codex_launch_supervisor()
    end
  end

  defp ensure_codex_launch_supervisor(supervisor) when is_atom(supervisor) do
    if Process.whereis(supervisor) do
      :ok
    else
      {:error, {:codex_launch_supervisor_missing, supervisor}}
    end
  end

  defp ensure_codex_launch_supervisor(_supervisor), do: :ok

  defp start_default_codex_launch_supervisor do
    child_spec =
      Supervisor.child_spec({Task.Supervisor, name: @codex_launch_supervisor},
        id: @codex_launch_supervisor
      )

    safe_supervisor_call(fn -> Supervisor.start_child(Afp.Supervisor, child_spec) end)
    |> case do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, {:already_present, _id}} -> restart_default_codex_launch_supervisor()
      {:error, reason} -> {:error, {:codex_launch_supervisor_start_failed, reason}}
    end
  end

  defp restart_default_codex_launch_supervisor do
    safe_supervisor_call(fn ->
      Supervisor.restart_child(Afp.Supervisor, @codex_launch_supervisor)
    end)
    |> case do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, {:codex_launch_supervisor_start_failed, reason}}
    end
  end

  defp safe_start_codex_launch_worker(supervisor, launch_request_id, opts) do
    safe_supervisor_call(fn ->
      Task.Supervisor.start_child(supervisor, fn ->
        complete_codex_launch(launch_request_id, opts)
      end)
    end)
  end

  defp safe_supervisor_call(fun) when is_function(fun, 0) do
    try do
      fun.()
    catch
      :exit, reason -> {:error, {:codex_launch_supervisor_exit, reason}}
    end
  end

  defp codex_completion_opts(launch_request_id, opts) do
    opts
    |> Keyword.drop([:background_timeout_ms, :mode, :supervisor])
    |> Keyword.put_new(:timeout_ms, codex_background_timeout_ms(opts))
    |> Keyword.put(:on_launch_event, fn event, payload ->
      Records.persist_codex_launch_progress(launch_request_id, event, payload)
    end)
  end

  defp codex_background_timeout_ms(opts) do
    Keyword.get(
      opts,
      :background_timeout_ms,
      Application.get_env(:afp, :codex_app_background_task_timeout_ms, 10_800_000)
    )
  end

  defp codex_app_client do
    Application.get_env(:afp, :codex_app_client, CodexAppClient)
  end

  defp codex_launch_startup_grace_ms do
    Application.get_env(:afp, :codex_launch_startup_grace_ms, 600_000)
  end

  defp stale_codex_startup_run?(%ResearchRun{} = run, cutoff) do
    payload = run.payload || %{}

    run.codex_session_id == nil and
      Context.payload_value(payload, "codex_launch_status") == "started" and
      Factory.blank?(Context.payload_value(payload, "thread_id")) and
      Factory.blank?(Context.payload_value(payload, "session_id")) and
      Factory.blank?(Context.payload_value(payload, "turn_id")) and
      Factory.blank?(Context.payload_value(payload, "transcript_path")) and
      old_enough_for_stale_startup?(run, cutoff)
  end

  defp old_enough_for_stale_startup?(%ResearchRun{} = run, cutoff) do
    timestamp = Context.payload_started_at(run.payload || %{}) || run.updated_at

    if timestamp do
      DateTime.compare(timestamp, cutoff) in [:lt, :eq]
    else
      false
    end
  end
end
