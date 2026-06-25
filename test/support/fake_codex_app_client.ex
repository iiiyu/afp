# @input  - Test Codex launch attrs produced by the Demand context
# @output - Deterministic fake Codex app-server launch responses
# @pos    - Test-only replacement for the real Codex JSON-RPC stdio adapter
defmodule Afp.Factory.Demand.FakeCodexAppClient do
  @behaviour Afp.Factory.AgentClient

  def launch_new_turn(attrs, opts \\ [])

  def launch_new_turn(%{input_text: "simulate interrupted turn"} = attrs, opts) do
    notify_progress(attrs, opts)
    {:error, {:codex_turn_incomplete, "interrupted"}}
  end

  def launch_new_turn(%{input_text: "simulate aborted turn"} = attrs, opts) do
    notify_progress(attrs, opts)
    {:error, {:codex_turn_aborted, "interrupted"}}
  end

  def launch_new_turn(%{input_text: "simulate client crash"}, _opts) do
    raise "simulated codex client crash"
  end

  def launch_new_turn(attrs, opts) do
    {thread_response, turn_response, _thread_id, turn_id} = fake_responses(attrs)

    :ok = notify(opts, :thread_started, thread_response)
    :ok = notify(opts, :turn_started, turn_response)

    {:ok,
     %{
       initialize_response: %{"result" => %{"userAgent" => "Fake Codex"}},
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
       notifications: [
         %{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "type" => "agentMessage",
               "phase" => "final_answer",
               "text" => "Fake Codex completed #{Path.basename(Map.fetch!(attrs, :cwd))}."
             }
           }
         }
       ],
       final_answer: "Fake Codex completed #{Path.basename(Map.fetch!(attrs, :cwd))}."
     }}
  end

  defp notify_progress(attrs, opts) do
    {thread_response, turn_response, _thread_id, _turn_id} = fake_responses(attrs)

    :ok = notify(opts, :thread_started, thread_response)
    :ok = notify(opts, :turn_started, turn_response)
  end

  defp fake_responses(attrs) do
    message_id = Map.fetch!(attrs, :client_user_message_id)
    thread_id = "fake-thread-#{message_id}"
    turn_id = "fake-turn-#{message_id}"

    thread_response = %{
      "result" => %{
        "thread" => %{
          "id" => thread_id,
          "sessionId" => "fake-session-#{message_id}",
          "cwd" => Map.fetch!(attrs, :cwd),
          "path" => "/tmp/#{thread_id}.jsonl"
        },
        "model" => "fake-codex"
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

    {thread_response, turn_response, thread_id, turn_id}
  end

  defp notify(opts, event, payload) do
    case Keyword.get(opts, :on_launch_event) do
      callback when is_function(callback, 2) -> callback.(event, payload)
      _callback -> :ok
    end
  end
end
