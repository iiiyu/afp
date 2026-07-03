# @input  - Phoenix LiveView routes and minimal seeded app data
# @output - Smoke assertions for the core control-plane screens
# @pos    - LiveView tests for navigation-level availability
defmodule AfpWeb.ControlPlaneLiveTest do
  use AfpWeb.ConnCase, async: true

  import Afp.FactoryFixtures

  test "core LiveViews render", %{conn: conn} do
    _app = app_fixture()

    for {path, text} <- [
          {~p"/", "Opportunities"},
          {~p"/opportunities", "Opportunities"},
          {~p"/apps", "Portfolio"}
        ] do
      {:ok, _view, html} = live(conn, path)
      assert html =~ text
    end
  end

  test "app detail shows overview, transitions, and event history", %{conn: conn} do
    app = app_fixture()

    {:ok, _view, html} = live(conn, ~p"/apps/#{app.id}")

    assert html =~ app.name
    assert html =~ "Overview"
    assert html =~ "Transitions"
    assert html =~ "Event history"
  end

  test "app detail lifecycle transition records an event", %{conn: conn} do
    app = app_fixture()

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.id}")

    view
    |> form("#lifecycle-form", %{
      "lifecycle" => %{"lifecycle_stage" => "in_build", "note" => "Starting the build"}
    })
    |> render_submit()

    app = Afp.Factory.Portfolio.get_app!(app.id)
    assert app.lifecycle_stage == "in_build"

    events = Afp.Factory.Events.list_subject_events("app", app.id)
    assert Enum.any?(events, &(&1.event_type == "lifecycle_transitioned"))
  end
end
