defmodule AfpWeb.PageControllerTest do
  use AfpWeb.ConnCase

  test "GET / renders the Today command center", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Focus Queue"
  end
end
