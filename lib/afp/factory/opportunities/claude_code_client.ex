# @input  - Opportunity launch attrs and Claude Code CLI stream-json stdout events
# @output - Completed Claude Code launch result in the shared agent launch envelope
# @pos    - Transport adapter between opportunity launches and the local claude CLI
defmodule Afp.Factory.Opportunities.ClaudeCodeClient do
  @moduledoc false

  require Logger

  @behaviour Afp.Factory.AgentClient

  alias Afp.Factory.AgentClient
  alias Afp.Factory.AgentClient.CommandPolicy

  @impl Afp.Factory.AgentClient
  def launch_new_turn(attrs, opts \\ []) when is_map(attrs) do
    timeout_ms = Keyword.get(opts, :timeout_ms, default_timeout_ms())
    cwd = Map.fetch!(attrs, :cwd)

    log_transport("launch_start", %{"cwd" => cwd, "timeout_ms" => timeout_ms})

    case open_port(cwd, attrs, opts) do
      {:ok, port} ->
        conn = %{
          port: port,
          buffer: "",
          events: [],
          init_event: nil,
          session_id: nil,
          turn_id: nil,
          transcript_path: nil,
          launch_event_handler: Keyword.get(opts, :on_launch_event)
        }

        result =
          try do
            await_result(conn, cwd, System.monotonic_time(:millisecond) + timeout_ms)
          after
            close_port(port)
          end

        log_launch_result(result)

        case result do
          {:ok, launch_result} -> {:ok, launch_result}
          {:error, reason} -> {:error, AgentClient.Error.wrap(reason)}
        end

      {:error, reason} ->
        log_transport("launch_error", %{"reason" => inspect(reason)})
        {:error, AgentClient.Error.wrap(reason)}
    end
  end

  defp await_result(conn, cwd, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {port, {:data, chunk}} when port == conn.port ->
        case handle_chunk(conn, chunk, cwd) do
          {:ok, conn, nil} -> await_result(conn, cwd, deadline)
          {:ok, conn, result_event} -> finalize(conn, result_event)
          {:error, reason} -> {:error, reason}
        end

      {port, {:exit_status, status}} when port == conn.port ->
        case handle_chunk(conn, "\n", cwd) do
          {:ok, conn, nil} -> {:error, {:claude_cli_exited, status, diagnostics(conn)}}
          {:ok, conn, result_event} -> finalize(conn, result_event)
          {:error, reason} -> {:error, reason}
        end
    after
      timeout ->
        {:error, {:claude_run_timeout, diagnostics(conn)}}
    end
  end

  defp handle_chunk(conn, chunk, cwd) do
    {lines, buffer} = split_lines(conn.buffer <> chunk)
    events = Enum.flat_map(lines, &decode_line/1)
    conn = %{conn | buffer: buffer, events: conn.events ++ events}

    with {:ok, conn} <- maybe_notify_started(conn, events, cwd),
         {:ok, conn} <- notify_activities(conn, events) do
      {:ok, conn, Enum.find(events, &result_event?/1)}
    end
  end

  defp notify_activities(conn, events) do
    events
    |> Enum.flat_map(&activities/1)
    |> Enum.reduce_while({:ok, conn}, fn activity, {:ok, conn} ->
      case notify_launch_event(conn, :activity, activity) do
        {:ok, conn} -> {:cont, {:ok, conn}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp activities(%{"type" => "assistant", "message" => %{"content" => content}})
       when is_list(content) do
    Enum.flat_map(content, &content_block_activity/1)
  end

  defp activities(%{"type" => "user", "message" => %{"content" => content}})
       when is_list(content) do
    Enum.flat_map(content, &tool_result_activity/1)
  end

  defp activities(_event), do: []

  defp content_block_activity(%{"type" => "text", "text" => text}) when is_binary(text) do
    [activity("message", text)]
  end

  defp content_block_activity(%{"type" => "tool_use", "name" => name} = block) do
    [activity("tool", tool_summary(name, Map.get(block, "input")))]
  end

  defp content_block_activity(_block), do: []

  defp tool_result_activity(%{"type" => "tool_result", "is_error" => true} = block) do
    [activity("tool_error", result_text(block["content"]))]
  end

  defp tool_result_activity(_block), do: []

  defp tool_summary(name, input) when is_map(input) do
    detail =
      Enum.find_value(
        ["command", "file_path", "path", "pattern", "query", "url", "description"],
        fn key ->
          case Map.get(input, key) do
            value when is_binary(value) and value != "" -> value
            _value -> nil
          end
        end
      )

    case detail do
      nil -> name
      detail -> "#{name}: #{detail}"
    end
  end

  defp tool_summary(name, _input), do: name

  defp result_text(content) when is_binary(content), do: content

  defp result_text(content) when is_list(content) do
    content
    |> Enum.map_join(" ", fn
      %{"type" => "text", "text" => text} -> text
      _block -> ""
    end)
    |> String.trim()
  end

  defp result_text(_content), do: "Tool call failed"

  defp activity(kind, text) do
    %{
      "kind" => kind,
      "text" => trim_activity_text(text),
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp trim_activity_text(text) do
    if String.length(text) > 240 do
      String.slice(text, 0, 240) <> "..."
    else
      text
    end
  end

  defp maybe_notify_started(%{init_event: nil} = conn, events, cwd) do
    case Enum.find(events, &init_event?/1) do
      nil ->
        {:ok, conn}

      init_event ->
        session_id = init_event["session_id"]

        conn = %{
          conn
          | init_event: init_event,
            session_id: session_id,
            turn_id: init_event["uuid"] || session_id,
            transcript_path: transcript_path(cwd, session_id)
        }

        with {:ok, conn} <-
               notify_launch_event(conn, :thread_started, %{
                 session_id: session_id,
                 thread_id: session_id,
                 transcript_path: conn.transcript_path
               }) do
          notify_launch_event(conn, :turn_started, %{turn_id: conn.turn_id})
        end
    end
  end

  defp maybe_notify_started(conn, _events, _cwd), do: {:ok, conn}

  defp init_event?(%{"type" => "system", "subtype" => "init"}), do: true
  defp init_event?(_event), do: false

  defp result_event?(%{"type" => "result"}), do: true
  defp result_event?(_event), do: false

  defp finalize(conn, %{"is_error" => true} = result_event) do
    {:error,
     {:claude_run_failed, result_event["result"] || "Claude Code run failed", diagnostics(conn)}}
  end

  defp finalize(%{session_id: nil} = conn, _result_event) do
    {:error, {:claude_session_missing, diagnostics(conn)}}
  end

  defp finalize(conn, result_event) do
    {:ok,
     %AgentClient.Result{
       session_id: conn.session_id,
       thread_id: conn.session_id,
       turn_id: conn.turn_id,
       turn_status: "completed",
       transcript_path: conn.transcript_path,
       final_answer: result_event["result"],
       raw: %{initialize_response: conn.init_event, notifications: conn.events}
     }}
  end

  defp notify_launch_event(%{launch_event_handler: handler} = conn, event, payload)
       when is_function(handler, 2) do
    case handler.(event, payload) do
      :ok -> {:ok, conn}
      {:ok, _result} -> {:ok, conn}
      {:error, reason} -> {:error, {:claude_launch_progress_failed, event, reason}}
      other -> {:error, {:claude_launch_progress_failed, event, other}}
    end
  catch
    kind, reason ->
      {:error, {:claude_launch_progress_failed, event, {kind, reason}}}
  end

  defp notify_launch_event(conn, _event, _payload), do: {:ok, conn}

  defp open_port(cwd, attrs, opts) do
    case Keyword.get(opts, :claude_executable) || System.find_executable("claude") do
      nil ->
        {:error, :claude_cli_not_found}

      claude ->
        {:ok,
         Port.open({:spawn_executable, claude}, [
           :binary,
           :exit_status,
           {:cd, cwd},
           args: cli_args(attrs)
         ])}
    end
  end

  defp cli_args(attrs) do
    [
      "-p",
      Map.fetch!(attrs, :input_text),
      "--output-format",
      "stream-json",
      "--verbose",
      "--settings",
      Jason.encode!(launch_settings(attrs))
    ] ++ model_args(attrs)
  end

  defp model_args(attrs) do
    case Map.get(attrs, :model) do
      model when is_binary(model) and model != "" -> ["--model", model]
      _model -> []
    end
  end

  defp launch_settings(attrs) do
    %{
      "permissions" => %{
        "allow" => allow_rules(attrs),
        "deny" => deny_rules()
      }
    }
  end

  defp allow_rules(attrs) do
    bash_rules = CommandPolicy.claude_allow_rules(Map.get(attrs, :extra_command_allow, []))

    ["Read", "Glob", "Grep", "WebSearch", "WebFetch", "TodoWrite"] ++
      write_rules(attrs) ++ bash_rules
  end

  defp write_rules(attrs) do
    case Map.get(attrs, :write_targets) do
      targets when is_map(targets) and map_size(targets) > 0 ->
        targets
        |> Map.values()
        |> Enum.sort()
        |> Enum.flat_map(fn path ->
          pattern = write_pattern(path)
          ["Write(#{pattern})", "Edit(#{pattern})"]
        end)

      _targets ->
        ["Write(**)", "Edit(**)"]
    end
  end

  defp write_pattern(path) do
    if Path.extname(path) == "", do: "#{path}/**", else: path
  end

  defp deny_rules do
    CommandPolicy.claude_deny_rules()
  end

  defp transcript_path(cwd, session_id) when is_binary(session_id) do
    project_slug = String.replace(cwd, ~r/[^A-Za-z0-9]/, "-")
    Path.join([System.user_home!(), ".claude", "projects", project_slug, session_id <> ".jsonl"])
  end

  defp transcript_path(_cwd, _session_id), do: nil

  defp split_lines(text) do
    parts = String.split(text, "\n")
    {lines, [buffer]} = Enum.split(parts, length(parts) - 1)
    {lines, buffer}
  end

  defp decode_line(line) do
    case String.trim(line) do
      "" ->
        []

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, event} when is_map(event) ->
            [event]

          {:ok, _value} ->
            []

          {:error, _reason} ->
            log_transport("decode_skipped", %{"line" => String.slice(trimmed, 0, 200)})
            []
        end
    end
  end

  defp diagnostics(conn) do
    %{
      "event_count" => length(conn.events),
      "session_id" => conn.session_id,
      "last_events" => conn.events |> Enum.take(-3) |> Enum.map(&event_summary/1)
    }
  end

  defp event_summary(event) when is_map(event) do
    Map.take(event, ["type", "subtype", "session_id", "is_error", "num_turns"])
  end

  defp event_summary(event), do: inspect(event)

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp default_timeout_ms do
    Application.get_env(:afp, :claude_code_task_timeout_ms, 10_800_000)
  end

  defp log_launch_result({:ok, result}) do
    log_transport("launch_completed", %{
      "event_count" => length(Map.get(result.raw, :notifications, [])),
      "session_id" => result.session_id
    })
  end

  defp log_launch_result({:error, reason}) do
    log_transport("launch_error", %{"reason" => inspect(reason)})
  end

  defp log_transport(event, metadata) do
    IO.puts(:stdio, "[claude-code] #{event} #{inspect(metadata)}")
  end
end
