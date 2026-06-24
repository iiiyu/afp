# @input  - A CodexLaunchRequest plus its research run, sent message, and source repo
# @output - Validated launch context, Codex app-server attrs, and payload transforms
# @pos    - Read-only/pure side of Demand's Codex launch: loads context, builds attrs
defmodule Afp.Factory.Demand.CodexLaunchContext do
  @moduledoc """
  Loads and validates the records a Codex launch needs, and builds the pure
  data the launch turns on: app-server attrs, sandbox policy, and the payload
  maps persisted at each phase. No database writes happen here.
  """

  require Logger

  alias Afp.Factory
  alias Afp.Factory.Demand
  alias Afp.Factory.Demand.CodexLaunchRequest
  alias Afp.Factory.Demand.ResearchRun
  alias Afp.Factory.Demand.SentMessage
  alias Afp.Factory.Demand.SourceRepo
  alias Afp.Repo

  def ensure_codex_launch_allowed(%CodexLaunchRequest{status: "cancelled"}),
    do: {:error, :launch_request_cancelled}

  def ensure_codex_launch_allowed(%CodexLaunchRequest{status: "launched"}),
    do: {:error, :launch_request_already_launched}

  def ensure_codex_launch_allowed(%CodexLaunchRequest{} = launch_request) do
    if launch_request.risk_level in ["high", "critical"] and
         Factory.blank?(launch_request.confirmation) do
      {:error, :confirmation_required}
    else
      :ok
    end
  end

  def codex_launch_context(%CodexLaunchRequest{} = launch_request) do
    launch_request = Demand.get_launch_request!(launch_request.id)

    research_run =
      ResearchRun
      |> Repo.get_by(codex_launch_request_id: launch_request.id)
      |> case do
        nil -> nil
        run -> Repo.preload(run, [:source_repo, :candidate, :message_template, :codex_session])
      end

    sent_message =
      SentMessage
      |> Repo.get_by(codex_launch_request_id: launch_request.id)
      |> case do
        nil -> nil
        message -> Repo.preload(message, [:research_run, :message_template, :launch_request])
      end

    cond do
      is_nil(research_run) ->
        {:error, :launch_request_without_research_run}

      is_nil(research_run.source_repo) ->
        {:error, :launch_request_without_source_repo}

      is_nil(sent_message) ->
        {:error, :launch_request_without_sent_message}

      true ->
        {:ok,
         %{
           launch_request: launch_request,
           research_run: research_run,
           sent_message: sent_message,
           source_repo: research_run.source_repo,
           input_text: codex_launch_input_text(launch_request, sent_message)
         }}
    end
  end

  def codex_launch_attrs(%{
        launch_request: launch_request,
        research_run: research_run,
        source_repo: source_repo,
        sent_message: sent_message,
        input_text: input_text
      }) do
    %{
      cwd: source_repo.repo_path,
      input_text: input_text,
      launch_request_id: launch_request.id,
      research_run_id: research_run.id,
      source_repo_id: source_repo.id,
      client_user_message_id: sent_message.id,
      approval_policy: "on-request",
      sandbox_mode: "workspace-write",
      source_repo_root: source_repo.repo_path,
      write_targets: source_repo.write_targets || %{},
      sqlite_path: source_repo.sqlite_path,
      sqlite_allowed_operations: source_repo.sqlite_allowed_operations || [],
      network_access: true,
      sandbox_policy: codex_sandbox_policy(source_repo)
    }
  end

  def codex_sandbox_policy(%SourceRepo{} = source_repo) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => codex_writable_roots(source_repo),
      "networkAccess" => true,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  def codex_writable_roots(%SourceRepo{} = source_repo) do
    declared_roots =
      source_repo.write_targets
      |> case do
        targets when is_map(targets) -> Map.values(targets)
        _targets -> []
      end
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&Factory.blank?/1)
      |> Enum.map(&source_repo_path(source_repo.repo_path, &1))

    sqlite_roots =
      case source_repo.sqlite_path do
        path when is_binary(path) and path != "" ->
          sqlite_path = source_repo_path(source_repo.repo_path, path)
          [sqlite_path, Path.dirname(sqlite_path)]

        _path ->
          []
      end

    roots = Enum.uniq(declared_roots ++ sqlite_roots)

    if roots == [] do
      [source_repo.repo_path]
    else
      roots
    end
  end

  def source_repo_path(repo_path, path) do
    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      Path.expand(path, repo_path)
    end
  end

  def codex_launch_input_text(%CodexLaunchRequest{} = launch_request, %SentMessage{} = message) do
    Factory.trim_nil(launch_request.handoff_text) ||
      Factory.trim_nil(message.edited_body) ||
      Factory.trim_nil(message.rendered_body) ||
      Demand.launch_handoff_text(launch_request)
  end

  def merge_payload(payload, updates) when is_map(payload), do: Map.merge(payload, updates)
  def merge_payload(_payload, updates), do: updates

  def codex_session_attrs(%{source_repo: source_repo}, codex_result, now) do
    thread = get_in(codex_result, [:thread_response, "result", "thread"]) || %{}
    turn = get_in(codex_result, [:turn_response, "result", "turn"]) || %{}

    %{
      "external_session_id" => thread["sessionId"] || thread["id"],
      "cwd" => thread["cwd"] || source_repo.repo_path,
      "model" => get_in(codex_result, [:thread_response, "result", "model"]),
      "status" => "stopped",
      "transcript_path" => thread["path"],
      "latest_turn_id" => turn["id"],
      "summary" => Map.get(codex_result, :final_answer),
      "first_seen_at" => now,
      "last_seen_at" => now,
      "stopped_at" => now
    }
  end

  def codex_launch_payload(codex_result, now) do
    thread = get_in(codex_result, [:thread_response, "result", "thread"]) || %{}
    turn = get_in(codex_result, [:turn_response, "result", "turn"]) || %{}
    completed_turn = get_in(codex_result, [:turn_completed, "params", "turn"]) || %{}
    server_request_responses = Map.get(codex_result, :server_request_responses, [])

    %{
      "codex_launch_status" => "completed",
      "thread_id" => thread["id"],
      "session_id" => thread["sessionId"] || thread["id"],
      "turn_id" => turn["id"] || completed_turn["id"],
      "turn_status" => completed_turn["status"],
      "completed_at" => DateTime.to_iso8601(now),
      "latest_progress_at" => DateTime.to_iso8601(now),
      "final_answer" => Map.get(codex_result, :final_answer),
      "event_count" => length(Map.get(codex_result, :notifications, [])),
      "server_request_count" => length(server_request_responses),
      "server_request_methods" =>
        server_request_responses
        |> Enum.map(&Map.get(&1, "method"))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
    }
  end

  def codex_failure_payload(reason, error_text) do
    payload = %{
      "codex_launch_status" => "failed",
      "codex_error" => error_text,
      "failed_at" => DateTime.to_iso8601(Factory.now())
    }

    case codex_failure_diagnostics(reason) do
      nil -> payload
      diagnostics -> Map.put(payload, "codex_failure_diagnostics", diagnostics)
    end
  end

  def codex_failure_diagnostics({_reason, diagnostics}) when is_map(diagnostics), do: diagnostics

  def codex_failure_diagnostics({_reason, _detail, diagnostics}) when is_map(diagnostics),
    do: diagnostics

  def codex_failure_diagnostics({_reason, _detail, _extra, diagnostics})
      when is_map(diagnostics),
      do: diagnostics

  def codex_failure_diagnostics(_reason), do: nil

  def payload_started_at(payload) when is_map(payload) do
    case payload_value(payload, "started_at") do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          {:error, _reason} -> nil
        end

      _value ->
        nil
    end
  end

  def payload_started_at(_payload), do: nil

  def payload_value(payload, key) when is_map(payload), do: Map.get(payload, key)
end
