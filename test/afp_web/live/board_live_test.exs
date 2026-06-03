# @input  - Board LiveView fixtures and hook event payloads
# @output - Assertions for draggable ticket cards and drop-based movement
# @pos    - LiveView coverage for board drag-and-drop behavior
defmodule AfpWeb.BoardLiveTest do
  use AfpWeb.ConnCase, async: true

  import Afp.FactoryFixtures

  alias Afp.Factory.Work

  test "ticket cards render draggable and drop events move them", %{conn: conn} do
    app = app_fixture()
    ticket = ticket_fixture(app, %{"status" => "ready"})

    {:ok, view, html} = live(conn, ~p"/board")

    assert html =~ ~s(id="ticket-board")
    assert html =~ ~s(phx-hook="TicketBoardDrag")
    assert html =~ ~s(id="ticket-column-active")
    assert html =~ ~s(data-ticket-drop-status="active")
    assert html =~ ~s(id="ticket-card-#{ticket.id}")
    assert html =~ ~s(data-ticket-id="#{ticket.id}")
    assert html =~ ~s(data-ticket-status="ready")
    assert html =~ ~s(draggable="true")

    assert render_hook(view, "drop_ticket", %{
             "ticket_id" => ticket.id,
             "status" => "active"
           }) =~ "Ticket moved."

    assert Work.get_ticket!(ticket.id).status == "active"
    assert render(view) =~ ~s(data-ticket-status="active")
  end

  test "drop events preserve transition requirements", %{conn: conn} do
    app = app_fixture()
    ticket = ticket_fixture(app, %{"status" => "active"})

    {:ok, view, _html} = live(conn, ~p"/board")

    assert render_hook(view, "drop_ticket", %{
             "ticket_id" => ticket.id,
             "status" => "done"
           }) =~ "Done requires a review note or linked evidence."

    assert Work.get_ticket!(ticket.id).status == "active"
  end
end
