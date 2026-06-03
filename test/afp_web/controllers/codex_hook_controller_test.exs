# @input  - Local JSON hook payloads through Phoenix ConnTest
# @output - Assertions for HTTP receiver persistence response
# @pos    - Integration test for POST /api/codex/hooks
defmodule AfpWeb.CodexHookControllerTest do
  use AfpWeb.ConnCase, async: true

  import Afp.FactoryFixtures

  test "POST /api/codex/hooks creates hook event and session", %{conn: conn} do
    app = app_fixture()

    conn =
      post(conn, ~p"/api/codex/hooks", %{
        "session_id" => "sess-#{unique_integer()}",
        "cwd" => app.repo_path,
        "hook_event_name" => "start",
        "payload" => %{"source" => "test"}
      })

    assert %{"ok" => true, "hook_event_id" => hook_event_id, "codex_session_id" => session_id} =
             json_response(conn, 200)

    assert is_binary(hook_event_id)
    assert is_binary(session_id)
  end
end
