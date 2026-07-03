# @input  - Neutral AgentClient.Request structs from launch orchestration
# @output - Deterministic %Result{} envelopes and neutral launch events
# @pos    - The one test adapter behind the AgentClient seam (both agents)
defmodule Afp.Factory.FakeAgentClient do
  @behaviour Afp.Factory.AgentClient

  alias Afp.Factory.AgentClient.Error
  alias Afp.Factory.AgentClient.Result

  def launch_new_turn(request, opts \\ [])

  def launch_new_turn(%{input_text: "simulate agent failure"} = request, opts) do
    notify_started(request, opts)
    {:error, %Error{reason: :agent_run_failed, detail: "simulated failure"}}
  end

  def launch_new_turn(request, opts) do
    %{session_id: session_id, turn_id: turn_id} = ids = fake_ids(request)

    :ok = notify(opts, :thread_started, started_payload(ids))
    :ok = notify(opts, :turn_started, %{turn_id: turn_id})

    :ok =
      notify(opts, :activity, %{
        "kind" => "tool",
        "text" => "WebSearch: fake competitor scan",
        "at" => "2026-01-01T00:00:00Z"
      })

    :ok =
      notify(opts, :activity, %{
        "kind" => "message",
        "text" => "Fake agent analyzing demand evidence.",
        "at" => "2026-01-01T00:00:01Z"
      })

    {:ok,
     %Result{
       session_id: session_id,
       thread_id: session_id,
       turn_id: turn_id,
       turn_status: "completed",
       transcript_path: "/tmp/#{session_id}.jsonl",
       final_answer: "Fake agent completed #{Path.basename(Map.fetch!(request, :cwd))}.",
       raw: %{notifications: []}
     }}
  end

  defp fake_ids(request) do
    message_id = Map.fetch!(request, :client_user_message_id)

    %{
      session_id: "fake-session-#{message_id}",
      turn_id: "fake-turn-#{message_id}"
    }
  end

  defp started_payload(%{session_id: session_id}) do
    %{
      session_id: session_id,
      thread_id: session_id,
      transcript_path: "/tmp/#{session_id}.jsonl"
    }
  end

  defp notify(opts, event, payload) do
    case Keyword.get(opts, :on_launch_event) do
      callback when is_function(callback, 2) -> callback.(event, payload)
      _callback -> :ok
    end
  end

  defp notify_started(request, opts) do
    ids = fake_ids(request)
    :ok = notify(opts, :thread_started, started_payload(ids))
    :ok = notify(opts, :turn_started, %{turn_id: ids.turn_id})
  end
end
