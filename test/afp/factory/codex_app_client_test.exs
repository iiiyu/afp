# @input  - Fake Codex app-server stdio executable and launch attrs
# @output - Assertions for Codex app-server JSON-RPC transport behavior
# @pos    - Protocol-level tests for the Demand Codex app-server adapter
defmodule Afp.Factory.CodexAppClientTest do
  use ExUnit.Case, async: true

  import Afp.FactoryFixtures

  alias Afp.Factory.Demand.CodexAppClient

  test "launch_new_turn answers app-server approval requests before awaiting completion" do
    cwd = unique_repo_path()
    codex_executable = fake_codex_executable!(cwd)

    assert {:ok, result} =
             CodexAppClient.launch_new_turn(
               %{
                 cwd: cwd,
                 input_text: "Run a bounded fake task.",
                 client_user_message_id: "fake-message-1"
               },
               codex_executable: codex_executable,
               timeout_ms: 2_000
             )

    assert result.final_answer == "Fake app-server completed."
    assert get_in(result.turn_completed, ["params", "turn", "status"]) == "completed"

    assert [
             %{
               "method" => "item/commandExecution/requestApproval",
               "response" => %{"decision" => "decline"}
             }
           ] = result.server_request_responses
  end

  defp fake_codex_executable!(cwd) do
    path = Path.join(cwd, "fake-codex")
    transcript_path = Path.join(cwd, "thread.jsonl")

    initialize_response =
      Jason.encode!(%{"id" => "afp-initialize", "result" => %{"userAgent" => "Fake Codex"}})

    thread_response =
      Jason.encode!(%{
        "id" => "afp-thread-start",
        "result" => %{
          "thread" => %{
            "id" => "thread-1",
            "sessionId" => "session-1",
            "cwd" => cwd,
            "path" => transcript_path
          },
          "model" => "fake-codex"
        }
      })

    turn_response =
      Jason.encode!(%{
        "id" => "afp-turn-start",
        "result" => %{"turn" => %{"id" => "turn-1", "status" => "inProgress"}}
      })

    approval_request =
      Jason.encode!(%{
        "id" => "approval-1",
        "method" => "item/commandExecution/requestApproval",
        "params" => %{
          "conversationId" => "thread-1",
          "itemId" => "item-1",
          "reason" => "fake approval",
          "action" => %{"type" => "unknown", "command" => "fake command"}
        }
      })

    final_message =
      Jason.encode!(%{
        "method" => "item/completed",
        "params" => %{
          "item" => %{
            "type" => "agentMessage",
            "phase" => "final_answer",
            "text" => "Fake app-server completed."
          }
        }
      })

    turn_completed =
      Jason.encode!(%{
        "method" => "turn/completed",
        "params" => %{
          "threadId" => "thread-1",
          "turn" => %{"id" => "turn-1", "status" => "completed", "items" => []}
        }
      })

    File.write!(path, """
    #!/bin/sh
    read _initialize
    printf '%s\\n' '#{initialize_response}'
    read _initialized
    read _thread
    printf '%s\\n' '#{thread_response}'
    read _turn
    printf '%s\\n' '#{turn_response}'
    printf '%s\\n' '#{approval_request}'
    read _approval
    printf '%s\\n' '#{final_message}'
    printf '%s\\n' '#{turn_completed}'
    """)

    File.chmod!(path, 0o755)
    path
  end
end
