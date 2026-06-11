# @input  - Stubbed claude executable emitting canned stream-json output
# @output - Assertions for the Claude Code Port adapter envelope and launch events
# @pos    - Transport tests for the opportunities Claude Code client
defmodule Afp.Factory.Opportunities.ClaudeCodeClientTest do
  use ExUnit.Case, async: true

  alias Afp.Factory.Opportunities.ClaudeCodeClient

  test "launch_new_turn parses stream-json output and emits launch events" do
    dir = stub_dir()

    script =
      write_stub(dir, """
      {"type":"system","subtype":"init","session_id":"sess-1","model":"fake-model","uuid":"uuid-1"}
      {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"pwd"}}]}}
      {"type":"user","message":{"content":[{"type":"tool_result","content":"denied","is_error":true}]}}
      {"type":"assistant","message":{"content":[{"type":"text","text":"All done."}]}}
      {"type":"result","subtype":"success","is_error":false,"result":"Research complete."}
      """)

    parent = self()

    assert {:ok, result} =
             ClaudeCodeClient.launch_new_turn(
               %{
                 cwd: dir,
                 input_text: "do research",
                 write_targets: %{"opportunities" => "opportunities"}
               },
               claude_executable: script,
               timeout_ms: 10_000,
               on_launch_event: fn event, payload ->
                 send(parent, {:launch_event, event, payload})
                 :ok
               end
             )

    assert result.final_answer == "Research complete."
    assert get_in(result.thread_response, ["result", "thread", "sessionId"]) == "sess-1"
    assert get_in(result.turn_completed, ["params", "turn", "status"]) == "completed"

    assert_received {:launch_event, :thread_started, thread_payload}
    assert get_in(thread_payload, ["result", "thread", "id"]) == "sess-1"
    assert_received {:launch_event, :turn_started, _turn_payload}
    assert_received {:launch_event, :activity, %{"kind" => "tool", "text" => "Bash: pwd"}}
    assert_received {:launch_event, :activity, %{"kind" => "tool_error", "text" => "denied"}}
    assert_received {:launch_event, :activity, %{"kind" => "message", "text" => "All done."}}
  end

  test "launch_new_turn returns an error for failed result events" do
    dir = stub_dir()

    script =
      write_stub(dir, """
      {"type":"system","subtype":"init","session_id":"sess-2","model":"fake-model","uuid":"uuid-2"}
      {"type":"result","subtype":"error_during_execution","is_error":true,"result":"Something broke"}
      """)

    assert {:error, {:claude_run_failed, "Something broke", _diagnostics}} =
             ClaudeCodeClient.launch_new_turn(
               %{cwd: dir, input_text: "do research"},
               claude_executable: script,
               timeout_ms: 10_000
             )
  end

  defp stub_dir do
    dir =
      Path.join(System.tmp_dir!(), "claude-client-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_stub(dir, stream_output) do
    script = Path.join(dir, "fake-claude.sh")

    File.write!(script, """
    #!/bin/sh
    cat <<'EOF'
    #{String.trim(stream_output)}
    EOF
    """)

    File.chmod!(script, 0o755)
    script
  end
end
