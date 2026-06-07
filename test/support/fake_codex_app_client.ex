# @input  - Test Codex launch attrs produced by the Demand context
# @output - Deterministic fake Codex app-server launch responses
# @pos    - Test-only replacement for the real Codex JSON-RPC stdio adapter
defmodule Afp.Factory.Demand.FakeCodexAppClient do
  @behaviour Afp.Factory.Demand.CodexAppClient

  def launch_new_turn(attrs, opts \\ [])

  def launch_new_turn(%{input_text: "simulate interrupted turn"}, _opts) do
    {:error, {:codex_turn_incomplete, "interrupted"}}
  end

  def launch_new_turn(%{input_text: "simulate aborted turn"}, _opts) do
    {:error, {:codex_turn_aborted, "interrupted"}}
  end

  def launch_new_turn(%{input_text: "simulate client crash"}, _opts) do
    raise "simulated codex client crash"
  end

  def launch_new_turn(attrs, _opts) do
    message_id = Map.fetch!(attrs, :client_user_message_id)
    thread_id = "fake-thread-#{message_id}"
    turn_id = "fake-turn-#{message_id}"

    {:ok,
     %{
       initialize_response: %{"result" => %{"userAgent" => "Fake Codex"}},
       thread_response: %{
         "result" => %{
           "thread" => %{
             "id" => thread_id,
             "sessionId" => "fake-session-#{message_id}",
             "cwd" => Map.fetch!(attrs, :cwd),
             "path" => "/tmp/#{thread_id}.jsonl"
           },
           "model" => "fake-codex"
         }
       },
       turn_response: %{
         "result" => %{
           "turn" => %{
             "id" => turn_id,
             "status" => "inProgress"
           }
         }
       },
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
end
