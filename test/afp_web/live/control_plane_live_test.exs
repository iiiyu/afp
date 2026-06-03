# @input  - Phoenix LiveView routes and minimal seeded app data
# @output - Smoke assertions for main control-plane screens
# @pos    - LiveView tests for navigation-level MVP availability
defmodule AfpWeb.ControlPlaneLiveTest do
  use AfpWeb.ConnCase, async: true

  import Afp.FactoryFixtures

  test "main LiveViews render", %{conn: conn} do
    _app = app_fixture()

    for {path, text} <- [
          {~p"/", "Focus Queue"},
          {~p"/today", "Focus Queue"},
          {~p"/apps", "Portfolio"},
          {~p"/board", "Ticket Board"},
          {~p"/sessions", "Session Inbox"},
          {~p"/releases", "Release Targets"},
          {~p"/evidence", "Evidence Store"},
          {~p"/metrics", "Metrics Snapshots"},
          {~p"/settings", "Repository Roots"}
        ] do
      {:ok, _view, html} = live(conn, path)
      assert html =~ text
    end
  end

  test "app detail shows separate lifecycle ticket and session state", %{conn: conn} do
    app = app_fixture()
    _ticket = ticket_fixture(app, %{"status" => "active"})

    {:ok, _view, html} = live(conn, ~p"/apps/#{app.id}")

    assert html =~ app.name
    assert html =~ "State Transitions"
    assert html =~ "Active Tickets"
    assert html =~ "Active Sessions"
  end
end
