# @input  - Codex app-server JSON-RPC launch parameters and stdio responses
# @output - New Codex thread/turn launch result with final task metadata
# @pos    - Transport adapter between demand launch requests and Codex app-server
defmodule Afp.Factory.Demand.CodexAppClient do
  @moduledoc false

  require Logger

  @callback launch_new_turn(map(), keyword()) :: {:ok, map()} | {:error, term()}

  @client_info %{
    "name" => "afp",
    "title" => "AFP",
    "version" => "0.1.0"
  }

  @initialize_request_id "afp-initialize"
  @thread_start_request_id "afp-thread-start"
  @turn_start_request_id "afp-turn-start"

  @modern_approval_methods [
    "item/commandExecution/requestApproval",
    "item/fileChange/requestApproval"
  ]
  @legacy_approval_methods ["applyPatchApproval", "execCommandApproval"]
  @sqlite_write_operations [
    "upsert_research_run",
    "upsert_candidate",
    "upsert_source",
    "upsert_sources",
    "upsert_score",
    "upsert_scores",
    "link_artifact"
  ]
  @safe_read_commands ~w(cat date find head ls pwd rg sed tail wc)
  @dangerous_command_markers [
    " rm ",
    " rm\t",
    " rm\n",
    " rm -",
    "git checkout",
    "git clean",
    "git reset",
    "chmod ",
    "chown ",
    "open ",
    "osascript"
  ]

  def launch_new_turn(attrs, opts \\ []) when is_map(attrs) do
    timeout_ms = Keyword.get(opts, :timeout_ms, default_timeout_ms())

    case open_port(opts) do
      {:ok, port} ->
        try do
          conn = new_conn(port, attrs, opts)

          with {:ok, conn, initialize_response} <- initialize(conn, timeout_ms),
               {:ok, conn, thread_response} <- start_thread(conn, attrs, timeout_ms),
               {:ok, conn, turn_response} <- start_turn(conn, attrs, thread_response, timeout_ms),
               {:ok, conn, turn_completed} <-
                 await_turn_completed(conn, turn_id(turn_response), timeout_ms) do
            {:ok,
             %{
               initialize_response: initialize_response,
               thread_response: thread_response,
               turn_response: turn_response,
               turn_completed: turn_completed,
               notifications: conn.events,
               server_request_responses: conn.server_request_responses,
               final_answer: final_answer(conn.events)
             }}
          else
            {:error, reason} -> {:error, reason}
          end
        after
          close_port(port)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp new_conn(port, attrs, opts) do
    %{
      port: port,
      buffer: "",
      events: [],
      handled_server_request_ids: MapSet.new(),
      server_request_responses: [],
      approval_decision:
        Keyword.get(opts, :approval_decision, Map.get(attrs, :approval_decision)),
      approval_profile: approval_profile(attrs)
    }
  end

  defp initialize(conn, timeout_ms) do
    with :ok <-
           send_message(conn.port, %{
             "id" => @initialize_request_id,
             "method" => "initialize",
             "params" => %{
               "clientInfo" => @client_info,
               "capabilities" => %{
                 "experimentalApi" => true,
                 "requestAttestation" => false
               }
             }
           }),
         {:ok, conn, response} <- receive_response(conn, @initialize_request_id, timeout_ms),
         :ok <- send_message(conn.port, %{"method" => "initialized"}) do
      {:ok, conn, response}
    end
  end

  defp start_thread(conn, attrs, timeout_ms) do
    cwd = Map.fetch!(attrs, :cwd)

    request = %{
      "id" => @thread_start_request_id,
      "method" => "thread/start",
      "params" => %{
        "cwd" => cwd,
        "approvalPolicy" => Map.get(attrs, :approval_policy, "on-request"),
        "sandbox" => Map.get(attrs, :sandbox_mode, "workspace-write"),
        "model" => Map.get(attrs, :model),
        "ephemeral" => Map.get(attrs, :ephemeral, false),
        "threadSource" => thread_source(attrs)
      }
    }

    with :ok <- send_message(conn.port, request) do
      receive_response(conn, @thread_start_request_id, timeout_ms)
    end
  end

  defp start_turn(conn, attrs, thread_response, timeout_ms) do
    cwd = Map.fetch!(attrs, :cwd)
    thread_id = get_in(thread_response, ["result", "thread", "id"])

    request = %{
      "id" => @turn_start_request_id,
      "method" => "turn/start",
      "params" => %{
        "threadId" => thread_id,
        "input" => [%{"type" => "text", "text" => Map.fetch!(attrs, :input_text)}],
        "cwd" => cwd,
        "approvalPolicy" => Map.get(attrs, :approval_policy, "on-request"),
        "sandboxPolicy" => sandbox_policy(cwd, attrs),
        "clientUserMessageId" => Map.get(attrs, :client_user_message_id)
      }
    }

    with :ok <- send_message(conn.port, request) do
      receive_response(conn, @turn_start_request_id, timeout_ms)
    end
  end

  defp await_turn_completed(conn, turn_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_turn_completed(conn, turn_id, deadline, nil)
  end

  defp await_turn_completed(conn, turn_id, deadline, latest_completion) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    if timeout == 0 do
      {:error, :codex_turn_timeout}
    else
      receive do
        {port, {:data, chunk}} when port == conn.port ->
          case handle_chunk_and_server_requests(conn, chunk) do
            {:ok, conn} -> maybe_complete_turn(conn, turn_id, deadline, latest_completion)
            {:error, reason} -> {:error, reason}
          end

        {port, {:exit_status, status}} when port == conn.port ->
          {:error, {:codex_app_server_exited, status}}
      after
        timeout ->
          {:error, :codex_turn_timeout}
      end
    end
  end

  defp maybe_complete_turn(conn, turn_id, deadline, latest_completion) do
    latest_completion = latest_turn_terminal_event(conn.events, turn_id) || latest_completion

    case latest_completion do
      nil ->
        await_turn_completed(conn, turn_id, deadline, latest_completion)

      %{"method" => "turn/completed", "params" => %{"turn" => %{"status" => "completed"}}} ->
        {:ok, conn, latest_completion}

      %{"method" => "turn/completed", "params" => %{"turn" => %{"status" => status}}} ->
        {:error, {:codex_turn_incomplete, status}}

      %{"method" => "turn/aborted"} ->
        {:error, {:codex_turn_aborted, terminal_reason(latest_completion)}}

      %{"method" => "turn/failed"} ->
        {:error, {:codex_turn_failed, terminal_reason(latest_completion)}}

      %{"type" => "event_msg", "payload" => %{"type" => "turn_aborted"}} ->
        {:error, {:codex_turn_aborted, terminal_reason(latest_completion)}}

      %{"type" => "turn_aborted"} ->
        {:error, {:codex_turn_aborted, terminal_reason(latest_completion)}}

      _completion ->
        {:error, :codex_turn_completion_unrecognized}
    end
  end

  defp receive_response(conn, request_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    receive_response_until(conn, request_id, deadline)
  end

  defp receive_response_until(conn, request_id, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    if timeout == 0 do
      {:error, {:codex_response_timeout, request_id}}
    else
      receive do
        {port, {:data, chunk}} when port == conn.port ->
          case handle_chunk_and_server_requests(conn, chunk) do
            {:ok, conn} ->
              case response_for(conn.events, request_id) do
                {:ok, response} -> {:ok, conn, response}
                {:error, reason} -> {:error, reason}
                :none -> receive_response_until(conn, request_id, deadline)
              end

            {:error, reason} ->
              {:error, reason}
          end

        {port, {:exit_status, status}} when port == conn.port ->
          {:error, {:codex_app_server_exited, status}}
      after
        timeout ->
          {:error, {:codex_response_timeout, request_id}}
      end
    end
  end

  defp handle_chunk_and_server_requests(conn, chunk) do
    conn
    |> handle_chunk(chunk)
    |> respond_to_server_requests()
  end

  defp handle_chunk(conn, chunk) do
    text = conn.buffer <> chunk
    {lines, buffer} = split_lines(text)

    events =
      lines
      |> Enum.map(&decode_line/1)
      |> Enum.reject(&is_nil/1)

    %{conn | buffer: buffer, events: conn.events ++ events}
  end

  defp split_lines(text) do
    case String.split(text, "\n") do
      [] ->
        {[], ""}

      [buffer] ->
        {[], buffer}

      parts ->
        {Enum.slice(parts, 0, length(parts) - 1), List.last(parts) || ""}
    end
  end

  defp response_for(events, request_id) do
    Enum.find_value(events, :none, fn
      %{"id" => ^request_id, "result" => _} = response -> {:ok, response}
      %{"id" => ^request_id, "error" => error} -> {:error, {:codex_request_error, error}}
      _event -> false
    end)
  end

  defp latest_turn_terminal_event(events, turn_id) do
    events
    |> Enum.reverse()
    |> Enum.find(fn
      %{"method" => "turn/completed", "params" => %{"turn" => %{"id" => ^turn_id}}} ->
        true

      %{"method" => method, "params" => %{"turn" => %{"id" => ^turn_id}}}
      when method in ["turn/aborted", "turn/failed"] ->
        true

      %{"type" => "event_msg", "payload" => %{"type" => "turn_aborted", "turn_id" => ^turn_id}} ->
        true

      %{"type" => "turn_aborted", "turn_id" => ^turn_id} ->
        true

      _event ->
        false
    end)
  end

  defp terminal_reason(event) do
    get_in(event, ["params", "reason"]) ||
      get_in(event, ["params", "turn", "reason"]) ||
      get_in(event, ["payload", "reason"]) ||
      Map.get(event, "reason") ||
      "unknown"
  end

  defp respond_to_server_requests(conn) do
    Enum.reduce_while(conn.events, {:ok, conn}, fn event, {:ok, acc} ->
      cond do
        not server_request?(event) ->
          {:cont, {:ok, acc}}

        MapSet.member?(acc.handled_server_request_ids, event["id"]) ->
          {:cont, {:ok, acc}}

        true ->
          case respond_to_server_request(acc, event) do
            {:ok, acc} -> {:cont, {:ok, acc}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp server_request?(%{"id" => _id, "method" => method}) when is_binary(method), do: true
  defp server_request?(_event), do: false

  defp respond_to_server_request(conn, %{"id" => id, "method" => method} = request) do
    outcome = server_request_outcome(conn, request)
    response = outcome.response

    case send_message(conn.port, response) do
      :ok ->
        log_server_request_response(method, outcome.summary)

        {:ok,
         %{
           conn
           | handled_server_request_ids: MapSet.put(conn.handled_server_request_ids, id),
             server_request_responses:
               conn.server_request_responses ++
                 [
                   %{
                     "id" => id,
                     "method" => method,
                     "request" => server_request_summary(request),
                     "response" => outcome.summary
                   }
                 ]
         }}

      {:error, reason} ->
        {:error, {:codex_server_request_response_failed, method, reason}}
    end
  end

  defp server_request_outcome(conn, %{"id" => id, "method" => method} = request)
       when method in @modern_approval_methods do
    {decision, reason} = modern_approval_decision(conn, request)

    %{
      response: %{"id" => id, "result" => %{"decision" => decision}},
      summary: %{"decision" => decision, "reason" => reason}
    }
  end

  defp server_request_outcome(conn, %{"id" => id, "method" => method} = request)
       when method in @legacy_approval_methods do
    {decision, reason} = legacy_approval_decision(conn, request)

    %{
      response: %{"id" => id, "result" => %{"decision" => decision}},
      summary: %{"decision" => decision, "reason" => reason}
    }
  end

  defp server_request_outcome(
         conn,
         %{
           "id" => id,
           "method" => "item/permissions/requestApproval"
         } = request
       ) do
    permissions = granted_permissions(conn, request)

    %{
      response: %{
        "id" => id,
        "result" => %{
          "permissions" => permissions,
          "scope" => "turn",
          "strictAutoReview" => true
        }
      },
      summary: %{
        "permissions" => permissions,
        "reason" => permissions_reason(conn, request, permissions)
      }
    }
  end

  defp server_request_outcome(_conn, %{
         "id" => id,
         "method" => "mcpServer/elicitation/request"
       }) do
    %{
      response: %{"id" => id, "result" => %{"action" => "decline"}},
      summary: %{"action" => "decline", "reason" => "AFP does not answer elicitation prompts."}
    }
  end

  defp server_request_outcome(_conn, %{"id" => id, "method" => "item/tool/requestUserInput"}) do
    %{
      response: %{"id" => id, "result" => %{"answers" => %{}}},
      summary: %{"answers" => %{}, "reason" => "AFP does not collect live tool input."}
    }
  end

  defp server_request_outcome(_conn, %{"id" => id, "method" => "item/tool/call"}) do
    %{
      response: %{
        "id" => id,
        "result" => %{
          "success" => false,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => "AFP Codex app-server client does not support client-side tool calls."
            }
          ]
        }
      },
      summary: %{"success" => false, "reason" => "Client-side tool calls are unsupported."}
    }
  end

  defp server_request_outcome(_conn, %{"id" => id, "method" => method}) do
    error = %{
      "code" => -32601,
      "message" => "AFP Codex app-server client does not support #{method}."
    }

    %{
      response: %{
        "id" => id,
        "error" => error
      },
      summary: %{"error" => error, "reason" => "Unsupported app-server request method."}
    }
  end

  defp modern_approval_decision(conn, request) do
    case configured_modern_approval_decision(conn) do
      nil -> app_server_approval_decision(conn, request, :modern)
      decision -> {decision, "Operator-configured approval decision."}
    end
  end

  defp legacy_approval_decision(conn, request) do
    case configured_legacy_approval_decision(conn) do
      nil ->
        {decision, reason} = app_server_approval_decision(conn, request, :legacy)
        {legacy_decision(decision), reason}

      decision ->
        {decision, "Operator-configured approval decision."}
    end
  end

  defp configured_modern_approval_decision(%{approval_decision: decision}) do
    case decision do
      "accept" -> "accept"
      :accept -> "accept"
      "acceptForSession" -> "acceptForSession"
      :accept_for_session -> "acceptForSession"
      "cancel" -> "cancel"
      :cancel -> "cancel"
      "decline" -> "decline"
      :decline -> "decline"
      nil -> nil
      _decision -> "decline"
    end
  end

  defp configured_legacy_approval_decision(%{approval_decision: decision}) do
    case decision do
      "accept" -> "approved"
      :accept -> "approved"
      "acceptForSession" -> "approved_for_session"
      :accept_for_session -> "approved_for_session"
      "cancel" -> "abort"
      :cancel -> "abort"
      "decline" -> "denied"
      :decline -> "denied"
      nil -> nil
      _decision -> "denied"
    end
  end

  defp app_server_approval_decision(conn, %{"method" => method} = request, _protocol)
       when method == "item/fileChange/requestApproval" do
    file_change_approval_decision(conn, request)
  end

  defp app_server_approval_decision(conn, %{"method" => method} = request, _protocol)
       when method == "item/commandExecution/requestApproval" do
    command_execution_approval_decision(conn, request)
  end

  defp app_server_approval_decision(conn, %{"method" => method} = request, _protocol)
       when method == "applyPatchApproval" do
    file_change_approval_decision(conn, request)
  end

  defp app_server_approval_decision(conn, %{"method" => method} = request, _protocol)
       when method == "execCommandApproval" do
    command_execution_approval_decision(conn, request)
  end

  defp app_server_approval_decision(_conn, _request, _protocol),
    do: {"decline", "Unsupported approval request."}

  defp legacy_decision("accept"), do: "approved"
  defp legacy_decision("acceptForSession"), do: "approved_for_session"
  defp legacy_decision("cancel"), do: "abort"
  defp legacy_decision(_decision), do: "denied"

  defp file_change_approval_decision(%{approval_profile: profile}, request) do
    grant_root = request |> request_params() |> Map.get("grantRoot")

    cond do
      blank?(grant_root) ->
        {"accept", "No extra grant root requested; turn sandbox and source repo contract apply."}

      path_within_any?(grant_root, profile.write_roots) ->
        {"accept", "Requested grant root is inside manifest-declared write targets."}

      sqlite_path?(profile, grant_root) ->
        {"accept", "Requested grant root matches the manifest-declared SQLite path."}

      true ->
        {"decline", "Requested grant root is outside manifest-declared write targets."}
    end
  end

  defp command_execution_approval_decision(%{approval_profile: profile}, request) do
    params = request_params(request)
    cwd = params["cwd"] || profile.cwd
    command = params["command"]
    command_actions = params["commandActions"]

    cond do
      not path_within?(cwd, profile.source_root) ->
        {"decline", "Command cwd is outside the source repo."}

      network_approval?(params) and profile.network_access ->
        {"accept", "Network access is enabled for this bounded research turn."}

      command_actions_outside_source?(command_actions, profile) ->
        {"decline", "Command action path is outside the source repo."}

      dangerous_command?(command) ->
        {"decline", "Command matches a blocked destructive or out-of-band pattern."}

      read_only_command_actions?(command_actions) ->
        {"accept", "Command actions are read-only and source-repo bounded."}

      sqlite_command_allowed?(command, profile) ->
        {"accept",
         "Command targets the manifest-declared SQLite database with allowed operations."}

      safe_read_command?(command) ->
        {"accept", "Command appears read-only and source-repo bounded."}

      true ->
        {"decline", "Command is not recognized as safe or manifest-bounded."}
    end
  end

  defp granted_permissions(%{approval_profile: profile}, request) do
    requested = request |> request_params() |> Map.get("permissions") || %{}
    network = requested["network"] || %{}

    if network["enabled"] == true and profile.network_access do
      %{"network" => %{"enabled" => true}}
    else
      %{}
    end
  end

  defp permissions_reason(%{approval_profile: profile}, request, permissions) do
    requested = request |> request_params() |> Map.get("permissions") || %{}

    cond do
      permissions != %{} ->
        "Granted requested network permission; filesystem permissions remain bounded by sandbox."

      get_in(requested, ["network", "enabled"]) == true and not profile.network_access ->
        "Network permission was requested but network access is disabled for this launch."

      true ->
        "No additional permissions granted; filesystem writes stay inside the turn sandbox."
    end
  end

  defp server_request_summary(%{"params" => params}) when is_map(params) do
    params
    |> Map.take(["cwd", "command", "grantRoot", "reason", "networkApprovalContext"])
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp server_request_summary(_request), do: %{}

  defp request_params(%{"params" => params}) when is_map(params), do: params
  defp request_params(_request), do: %{}

  defp approval_profile(attrs) do
    cwd = attrs |> Map.fetch!(:cwd) |> Path.expand()
    source_root = attrs |> Map.get(:source_repo_root, cwd) |> Path.expand(cwd)
    write_roots = approval_write_roots(source_root, attrs)
    sqlite_path = sqlite_path(source_root, attrs)

    %{
      cwd: cwd,
      source_root: source_root,
      write_roots: write_roots,
      sqlite_path: sqlite_path,
      sqlite_allowed_operations: Map.get(attrs, :sqlite_allowed_operations, []),
      network_access: Map.get(attrs, :network_access, true)
    }
  end

  defp approval_write_roots(source_root, attrs) do
    write_targets =
      attrs
      |> Map.get(:write_targets, %{})
      |> write_target_paths()
      |> Enum.map(&expand_source_path(source_root, &1))

    fallback_roots =
      if write_targets == [] do
        [source_root]
      else
        write_targets
      end

    fallback_roots
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp write_target_paths(write_targets) when is_map(write_targets) do
    write_targets
    |> Map.values()
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&blank?/1)
  end

  defp write_target_paths(_write_targets), do: []

  defp sqlite_path(source_root, attrs) do
    case Map.get(attrs, :sqlite_path) do
      path when is_binary(path) and path != "" -> expand_source_path(source_root, path)
      _path -> nil
    end
  end

  defp sqlite_path?(%{sqlite_path: nil}, _path), do: false

  defp sqlite_path?(%{sqlite_path: sqlite_path}, path) do
    expanded_path = Path.expand(path)
    expanded_path == sqlite_path or String.starts_with?(expanded_path, sqlite_path <> "-")
  end

  defp expand_source_path(source_root, path) do
    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      Path.expand(path, source_root)
    end
  end

  defp path_within?(nil, _root), do: false

  defp path_within?(path, root) when is_binary(path) and is_binary(root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)

    expanded_path == expanded_root or String.starts_with?(expanded_path, expanded_root <> "/")
  end

  defp path_within?(_path, _root), do: false

  defp path_within_any?(path, roots) when is_binary(path) do
    Enum.any?(roots, &path_within?(path, &1))
  end

  defp path_within_any?(_path, _roots), do: false

  defp network_approval?(params) do
    match?(%{}, params["networkApprovalContext"])
  end

  defp command_actions_outside_source?(actions, profile) when is_list(actions) do
    Enum.any?(actions, fn action ->
      case Map.get(action, "path") do
        path when is_binary(path) -> not path_within?(path, profile.source_root)
        _path -> false
      end
    end)
  end

  defp command_actions_outside_source?(_actions, _profile), do: false

  defp read_only_command_actions?(actions) when is_list(actions) and actions != [] do
    Enum.all?(actions, fn action ->
      Map.get(action, "type") in ["read", "listFiles", "search"]
    end)
  end

  defp read_only_command_actions?(_actions), do: false

  defp sqlite_command_allowed?(command, %{sqlite_path: sqlite_path} = profile)
       when is_binary(command) and is_binary(sqlite_path) do
    sqlite_requested? =
      String.contains?(command, "sqlite3") and
        (String.contains?(command, sqlite_path) ||
           String.contains?(command, Path.basename(sqlite_path)))

    sqlite_write_allowed? =
      Enum.any?(profile.sqlite_allowed_operations || [], &(&1 in @sqlite_write_operations))

    sqlite_requested? and sqlite_write_allowed?
  end

  defp sqlite_command_allowed?(_command, _profile), do: false

  defp safe_read_command?(command) when is_binary(command) do
    normalized = command |> String.trim() |> strip_rtk_prefix()
    first = normalized |> String.split(~r/\s+/, parts: 2) |> List.first()

    cond do
      first in @safe_read_commands and not command_writes?(normalized) -> true
      String.starts_with?(normalized, "git status") -> true
      String.starts_with?(normalized, "git diff") -> true
      String.starts_with?(normalized, "git log") -> true
      String.starts_with?(normalized, "sqlite3 -readonly") -> true
      true -> false
    end
  end

  defp safe_read_command?(_command), do: false

  defp strip_rtk_prefix("rtk " <> rest), do: String.trim(rest)
  defp strip_rtk_prefix(command), do: command

  defp command_writes?(command) do
    String.contains?(command, ">") or
      String.contains?(command, " tee ") or
      String.contains?(command, " -i ")
  end

  defp dangerous_command?(command) when is_binary(command) do
    padded = " " <> String.trim(command) <> " "
    Enum.any?(@dangerous_command_markers, &String.contains?(padded, &1))
  end

  defp dangerous_command?(_command), do: false

  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")

  defp log_server_request_response(method, summary) do
    console_message =
      "[codex-app-server] request=#{method} response=#{inspect(summary)}"

    IO.puts(:stdio, console_message)

    case summary do
      %{"decision" => decision} ->
        Logger.warning("Codex app-server approval request answered",
          method: method,
          decision: decision,
          reason: Map.get(summary, "reason")
        )

      %{"error" => error} ->
        Logger.error("Codex app-server request is unsupported",
          method: method,
          error: inspect(error),
          reason: Map.get(summary, "reason")
        )

      summary ->
        Logger.warning("Codex app-server interactive request answered",
          method: method,
          response: inspect(summary)
        )
    end
  end

  defp final_answer(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{
        "method" => "item/completed",
        "params" => %{
          "item" => %{
            "type" => "agentMessage",
            "phase" => "final_answer",
            "text" => text
          }
        }
      } ->
        text

      _event ->
        nil
    end)
  end

  defp turn_id(%{"result" => %{"turn" => %{"id" => id}}}), do: id

  defp sandbox_policy(cwd, attrs) do
    Map.get(attrs, :sandbox_policy) ||
      %{
        "type" => "workspaceWrite",
        "writableRoots" => [cwd],
        "networkAccess" => Map.get(attrs, :network_access, true),
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }
  end

  defp thread_source(attrs) do
    case Map.get(attrs, :thread_source, "user") do
      source when source in ["user", "subagent", "memory_consolidation"] ->
        source

      source ->
        Logger.warning("Ignoring unsupported Codex app-server threadSource",
          thread_source: inspect(source)
        )

        "user"
    end
  end

  defp send_message(port, message) do
    payload = Jason.encode!(message) <> "\n"

    if Port.command(port, payload) do
      :ok
    else
      {:error, :codex_port_closed}
    end
  end

  defp decode_line(line) do
    line
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> decode_json(trimmed)
    end
  end

  defp decode_json(line) do
    case Jason.decode(line) do
      {:ok, value} -> value
      {:error, _reason} -> nil
    end
  end

  defp open_port(opts) do
    case Keyword.get(opts, :codex_executable) || System.find_executable("codex") do
      nil ->
        {:error, :codex_cli_not_found}

      codex ->
        {:ok,
         Port.open({:spawn_executable, codex}, [
           :binary,
           :exit_status,
           args: ["app-server", "--stdio"]
         ])}
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  end

  defp default_timeout_ms do
    Application.get_env(:afp, :codex_app_task_timeout_ms, 10_800_000)
  end
end
