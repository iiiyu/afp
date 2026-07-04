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

  test "app detail shows overview, the build surface, and event history", %{conn: conn} do
    app = app_fixture()

    {:ok, _view, html} = live(conn, ~p"/apps/#{app.id}")

    assert html =~ app.name
    assert html =~ "Overview"
    assert html =~ "Build runs"
    assert html =~ "Event history"
    refute html =~ "Transitions"
  end
end
