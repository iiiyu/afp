# @input  - Fake Codex app-server stdio executable and launch attrs
# @output - Assertions for Codex app-server JSON-RPC transport behavior
# @pos    - Protocol-level tests for the Demand Codex app-server adapter
defmodule Afp.Factory.CodexAppClientTest do
  use ExUnit.Case, async: true

  import Afp.FactoryFixtures

  alias Afp.Factory.CodexAppClient

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
    assert result.turn_status == "completed"
    assert result.session_id == "session-1"

    assert [
             %{
               "method" => "item/commandExecution/requestApproval",
               "response" => %{
                 "decision" => "decline",
                 "reason" => "Command is not recognized as safe or manifest-bounded."
               }
             }
           ] = result.raw.server_request_responses
  end

  test "launch_new_turn reports thread and turn progress callbacks" do
    cwd = unique_repo_path()
    codex_executable = fake_codex_executable!(cwd, [file_change_approval_request()])
    parent = self()

    assert {:ok, _result} =
             CodexAppClient.launch_new_turn(
               %{
                 cwd: cwd,
                 input_text: "Run a bounded fake task with progress.",
                 client_user_message_id: "fake-message-progress",
                 write_targets: %{"runs" => "runs"}
               },
               codex_executable: codex_executable,
               timeout_ms: 2_000,
               on_launch_event: fn event, payload ->
                 send(parent, {:codex_progress, event, payload})
                 :ok
               end
             )

    assert_receive {:codex_progress, :thread_started,
                    %{session_id: "session-1", thread_id: "thread-1"}}

    assert_receive {:codex_progress, :turn_started, %{turn_id: "turn-1"}}

    assert_receive {:codex_progress, :activity,
                    %{"kind" => "message", "text" => "Fake app-server completed."}}
  end

  test "launch_new_turn accepts file changes governed by the current sandbox" do
    cwd = unique_repo_path()

    codex_executable =
      fake_codex_executable!(cwd, [
        file_change_approval_request()
      ])

    assert {:ok, result} =
             CodexAppClient.launch_new_turn(
               %{
                 cwd: cwd,
                 input_text: "Write a bounded fake artifact.",
                 client_user_message_id: "fake-message-2",
                 write_targets: %{"runs" => "runs"}
               },
               codex_executable: codex_executable,
               timeout_ms: 2_000
             )

    assert [
             %{
               "method" => "item/fileChange/requestApproval",
               "response" => %{
                 "decision" => "accept",
                 "reason" =>
                   "No extra grant root requested; turn sandbox and source repo contract apply."
               }
             }
           ] = result.raw.server_request_responses
  end

  test "launch_new_turn declines file grant roots outside manifest write targets" do
    cwd = unique_repo_path()
    outside_path = Path.expand("../outside", cwd)

    codex_executable =
      fake_codex_executable!(cwd, [
        file_change_approval_request(%{"grantRoot" => outside_path})
      ])

    assert {:ok, result} =
             CodexAppClient.launch_new_turn(
               %{
                 cwd: cwd,
                 input_text: "Try an out-of-bounds fake artifact.",
                 client_user_message_id: "fake-message-3",
                 write_targets: %{"runs" => "runs"}
               },
               codex_executable: codex_executable,
               timeout_ms: 2_000
             )

    assert [
             %{
               "method" => "item/fileChange/requestApproval",
               "request" => %{"grantRoot" => ^outside_path},
               "response" => %{
                 "decision" => "decline",
                 "reason" => "Requested grant root is outside manifest-declared write targets."
               }
             }
           ] = result.raw.server_request_responses
  end

  test "launch_new_turn accepts network approvals for bounded research turns" do
    cwd = unique_repo_path()

    codex_executable =
      fake_codex_executable!(cwd, [
        command_approval_request(cwd, %{
          "command" => nil,
          "networkApprovalContext" => %{"host" => "apps.apple.com"}
        })
      ])

    assert {:ok, result} =
             CodexAppClient.launch_new_turn(
               %{
                 cwd: cwd,
                 input_text: "Fetch bounded market evidence.",
                 client_user_message_id: "fake-message-4",
                 network_access: true
               },
               codex_executable: codex_executable,
               timeout_ms: 2_000
             )

    assert [
             %{
               "method" => "item/commandExecution/requestApproval",
               "response" => %{
                 "decision" => "accept",
                 "reason" => "Network access is enabled for this bounded research turn."
               }
             }
           ] = result.raw.server_request_responses
  end

  defp fake_codex_executable!(cwd, approval_requests \\ nil) do
    path = Path.join(cwd, "fake-codex")
    transcript_path = Path.join(cwd, "thread.jsonl")
    approval_requests = approval_requests || [command_approval_request(cwd)]

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

    approval_script =
      approval_requests
      |> Enum.map(&Jason.encode!/1)
      |> Enum.map_join("\n", fn request ->
        """
        printf '%s\\n' #{shell_quote(request)}
        read _approval
        """
      end)
      |> String.trim()

    File.write!(path, """
    #!/bin/sh
    read _initialize
    printf '%s\\n' #{shell_quote(initialize_response)}
    read _initialized
    read _thread
    printf '%s\\n' #{shell_quote(thread_response)}
    read _turn
    printf '%s\\n' #{shell_quote(turn_response)}
    #{approval_script}
    printf '%s\\n' #{shell_quote(final_message)}
    printf '%s\\n' #{shell_quote(turn_completed)}
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp command_approval_request(cwd, params \\ %{}) do
    %{
      "id" => "approval-1",
      "method" => "item/commandExecution/requestApproval",
      "params" =>
        Map.merge(
          %{
            "threadId" => "thread-1",
            "turnId" => "turn-1",
            "itemId" => "item-1",
            "startedAtMs" => 1,
            "cwd" => cwd,
            "reason" => "fake approval",
            "command" => "fake command",
            "commandActions" => [
              %{"type" => "unknown", "command" => "fake command"}
            ]
          },
          params
        )
    }
  end

  defp file_change_approval_request(params \\ %{}) do
    %{
      "id" => "approval-1",
      "method" => "item/fileChange/requestApproval",
      "params" =>
        Map.merge(
          %{
            "threadId" => "thread-1",
            "turnId" => "turn-1",
            "itemId" => "item-1",
            "startedAtMs" => 1,
            "reason" => "fake file approval"
          },
          params
        )
    }
  end

  defp shell_quote(value) do
    "'#{String.replace(value, "'", "'\"'\"'")}'"
  end
end
