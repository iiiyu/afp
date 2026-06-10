# @input  - Test agent launch attrs produced by the Opportunities context
# @output - Deterministic fake Claude Code headless launch responses
# @pos    - Test-only replacement for the real claude CLI stream-json adapter
defmodule Afp.Factory.Opportunities.FakeClaudeCodeClient do
  @behaviour Afp.Factory.Opportunities.ClaudeCodeClient

  def launch_new_turn(attrs, opts \\ [])

  def launch_new_turn(%{input_text: "simulate claude failure"} = attrs, opts) do
    notify_progress(attrs, opts)
    {:error, {:claude_run_failed, "simulated failure", %{}}}
  end

  def launch_new_turn(attrs, opts) do
    {thread_response, turn_response, turn_id} = fake_responses(attrs)

    :ok = notify(opts, :thread_started, thread_response)
    :ok = notify(opts, :turn_started, turn_response)

    {:ok,
     %{
       initialize_response: %{"type" => "system", "subtype" => "init"},
       thread_response: thread_response,
       turn_response: turn_response,
       turn_completed: %{
         "method" => "turn/completed",
         "params" => %{
           "turn" => %{
             "id" => turn_id,
             "status" => "completed"
           }
         }
       },
       notifications: [],
       final_answer: "Fake Claude Code completed #{Path.basename(Map.fetch!(attrs, :cwd))}."
     }}
  end

  defp notify_progress(attrs, opts) do
    {thread_response, turn_response, _turn_id} = fake_responses(attrs)

    :ok = notify(opts, :thread_started, thread_response)
    :ok = notify(opts, :turn_started, turn_response)
  end

  defp fake_responses(attrs) do
    message_id = Map.fetch!(attrs, :client_user_message_id)
    session_id = "fake-claude-session-#{message_id}"
    turn_id = "fake-claude-turn-#{message_id}"

    thread_response = %{
      "result" => %{
        "thread" => %{
          "id" => session_id,
          "sessionId" => session_id,
          "cwd" => Map.fetch!(attrs, :cwd),
          "path" => "/tmp/#{session_id}.jsonl"
        },
        "model" => "fake-claude"
      }
    }

    turn_response = %{
      "result" => %{
        "turn" => %{
          "id" => turn_id,
          "status" => "inProgress"
        }
      }
    }

    {thread_response, turn_response, turn_id}
  end

  defp notify(opts, event, payload) do
    case Keyword.get(opts, :on_launch_event) do
      callback when is_function(callback, 2) -> callback.(event, payload)
      _callback -> :ok
    end
  end
end
