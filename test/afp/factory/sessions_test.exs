# @input  - Codex hook payloads, app cwd fixtures, and linked tickets
# @output - Assertions for raw hook storage, cwd matching, deduplication, and review prompts
# @pos    - Context tests for Codex session bridge behavior
defmodule Afp.Factory.SessionsTest do
  use Afp.DataCase, async: true

  import Afp.FactoryFixtures

  alias Afp.Factory.Sessions
  alias Afp.Factory.Work
  alias Afp.Repo

  test "receive_hook stores raw event, preserves unknown fields, and matches cwd to app" do
    app = app_fixture()

    assert {:ok, hook_event, session} =
             Sessions.receive_hook(%{
               "session_id" => "sess-#{unique_integer()}",
               "cwd" => Path.join(app.repo_path, "subdir"),
               "hook_event_name" => "start",
               "model" => "gpt-5",
               "turn_id" => "turn-1",
               "unexpected" => "kept"
             })

    assert hook_event.payload["unexpected"] == "kept"
    assert session.app_id == app.id
    assert session.status == "running"
  end

  test "duplicate hook events update one session instead of creating duplicates" do
    app = app_fixture()
    session_id = "sess-#{unique_integer()}"

    {:ok, _hook_event, session} =
      Sessions.receive_hook(%{
        "session_id" => session_id,
        "cwd" => app.repo_path,
        "hook_event_name" => "start"
      })

    {:ok, _hook_event, updated_session} =
      Sessions.receive_hook(%{
        "session_id" => session_id,
        "cwd" => app.repo_path,
        "hook_event_name" => "stop"
      })

    assert session.id == updated_session.id
    assert updated_session.status == "stopped"
    assert Repo.aggregate(Afp.Factory.Sessions.CodexSession, :count) == 1
  end

  test "stopped linked session moves ticket into review prompt state" do
    app = app_fixture()
    ticket = ticket_fixture(app, %{"status" => "active"})
    session_id = "sess-#{unique_integer()}"

    {:ok, _hook_event, session} =
      Sessions.receive_hook(%{
        "session_id" => session_id,
        "cwd" => app.repo_path,
        "hook_event_name" => "start"
      })

    {:ok, _session} = Sessions.link_session(session, app.id, ticket.id, "Testing")

    {:ok, _hook_event, _session} =
      Sessions.receive_hook(%{
        "session_id" => session_id,
        "cwd" => app.repo_path,
        "hook_event_name" => "stop"
      })

    assert Work.get_ticket!(ticket.id).status == "review"
  end

  test "reviewing a stopped session can create evidence and route linked ticket done" do
    app = app_fixture()
    ticket = ticket_fixture(app, %{"status" => "active"})
    session_id = "sess-#{unique_integer()}"

    {:ok, _hook_event, session} =
      Sessions.receive_hook(%{
        "session_id" => session_id,
        "cwd" => app.repo_path,
        "hook_event_name" => "start"
      })

    {:ok, linked_session} = Sessions.link_session(session, app.id, ticket.id, "Testing")

    {:ok, _hook_event, stopped_session} =
      Sessions.receive_hook(%{
        "session_id" => session_id,
        "cwd" => app.repo_path,
        "hook_event_name" => "stop"
      })

    assert {:ok, reviewed_session} =
             stopped_session
             |> Sessions.review_session(%{
               "decision" => "pass",
               "evidence_summary" => "Tests passed and diff reviewed."
             })

    assert reviewed_session.id == linked_session.id
    assert Work.get_ticket!(ticket.id).status == "done"
    assert Afp.Factory.Evidence.count_links("codex_session", reviewed_session.id) == 1
    assert Afp.Factory.Evidence.count_links("ticket", ticket.id) == 1
  end
end
