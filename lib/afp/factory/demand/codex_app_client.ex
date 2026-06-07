# @input  - Codex app-server JSON-RPC launch parameters and stdio responses
# @output - New Codex thread/turn launch result with final task metadata
# @pos    - Transport adapter between demand launch requests and Codex app-server
defmodule Afp.Factory.Demand.CodexAppClient do
  @moduledoc false

  @callback launch_new_turn(map(), keyword()) :: {:ok, map()} | {:error, term()}

  @client_info %{
    "name" => "afp",
    "title" => "AFP",
    "version" => "0.1.0"
  }

  def launch_new_turn(attrs, opts \\ []) when is_map(attrs) do
    timeout_ms = Keyword.get(opts, :timeout_ms, default_timeout_ms())

    case open_port() do
      {:ok, port} ->
        try do
          conn = %{port: port, buffer: "", events: []}

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

  defp initialize(conn, timeout_ms) do
    with :ok <-
           send_message(conn.port, %{
             "id" => 1,
             "method" => "initialize",
             "params" => %{
               "clientInfo" => @client_info,
               "capabilities" => %{
                 "experimentalApi" => true,
                 "requestAttestation" => false
               }
             }
           }),
         {:ok, conn, response} <- receive_response(conn, 1, timeout_ms),
         :ok <- send_message(conn.port, %{"method" => "initialized"}) do
      {:ok, conn, response}
    end
  end

  defp start_thread(conn, attrs, timeout_ms) do
    cwd = Map.fetch!(attrs, :cwd)

    request = %{
      "id" => 2,
      "method" => "thread/start",
      "params" => %{
        "cwd" => cwd,
        "runtimeWorkspaceRoots" => [cwd],
        "approvalPolicy" => Map.get(attrs, :approval_policy, "on-request"),
        "sandbox" => Map.get(attrs, :sandbox_mode, "workspace-write"),
        "model" => Map.get(attrs, :model),
        "ephemeral" => Map.get(attrs, :ephemeral, false),
        "threadSource" => Map.get(attrs, :thread_source, %{"type" => "external"})
      }
    }

    with :ok <- send_message(conn.port, request) do
      receive_response(conn, 2, timeout_ms)
    end
  end

  defp start_turn(conn, attrs, thread_response, timeout_ms) do
    cwd = Map.fetch!(attrs, :cwd)
    thread_id = get_in(thread_response, ["result", "thread", "id"])

    request = %{
      "id" => 3,
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
      receive_response(conn, 3, timeout_ms)
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
          conn
          |> handle_chunk(chunk)
          |> maybe_complete_turn(turn_id, deadline, latest_completion)

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
          conn = handle_chunk(conn, chunk)

          case response_for(conn.events, request_id) do
            {:ok, response} -> {:ok, conn, response}
            {:error, reason} -> {:error, reason}
            :none -> receive_response_until(conn, request_id, deadline)
          end

        {port, {:exit_status, status}} when port == conn.port ->
          {:error, {:codex_app_server_exited, status}}
      after
        timeout ->
          {:error, {:codex_response_timeout, request_id}}
      end
    end
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

  defp open_port do
    case System.find_executable("codex") do
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
