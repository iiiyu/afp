# @input  - Work context fixtures, evidence links, and harness packet params
# @output - Assertions for ticket and harness packet state rules
# @pos    - Context tests for workflow and executable contract enforcement
defmodule Afp.Factory.WorkTest do
  use Afp.DataCase, async: true

  import Afp.FactoryFixtures

  alias Afp.Factory.Evidence
  alias Afp.Factory.Work

  test "moving ticket to done requires review note or linked evidence" do
    app = app_fixture()
    ticket = ticket_fixture(app, %{"status" => "active"})

    assert {:error, :review_or_evidence_required} = Work.transition_ticket(ticket, "done", %{})

    assert {:ok, done_ticket} =
             Work.transition_ticket(ticket, "done", %{"review_note" => "Reviewed diff"})

    assert done_ticket.status == "done"
  end

  test "moving ticket to blocked requires blocked reason" do
    app = app_fixture()
    ticket = ticket_fixture(app, %{"status" => "active"})

    assert {:error, :blocked_reason_required} = Work.transition_ticket(ticket, "blocked", %{})

    assert {:ok, blocked_ticket} =
             Work.transition_ticket(ticket, "blocked", %{"blocked_reason" => "Waiting on review"})

    assert blocked_ticket.status == "blocked"
  end

  test "linked evidence can satisfy done transition" do
    app = app_fixture()
    ticket = ticket_fixture(app, %{"status" => "active"})
    evidence = evidence_fixture(app)
    {:ok, _link} = Evidence.attach_evidence(evidence, "ticket", ticket.id, "Review proof")

    assert {:ok, done_ticket} = Work.transition_ticket(ticket, "done", %{})
    assert done_ticket.status == "done"
  end

  test "ready harness packets require expected output and review route" do
    app = app_fixture()

    assert {:error, changeset} =
             Work.create_harness_packet(%{
               "app_id" => app.id,
               "objective" => "Do the work",
               "state" => "ready"
             })

    assert %{expected_output: ["can't be blank"], review_route: ["can't be blank"]} =
             errors_on(changeset)
  end

  test "high-risk packets require explicit confirmation before ready" do
    app = app_fixture()

    {:ok, packet} =
      Work.create_harness_packet(%{
        "app_id" => app.id,
        "objective" => "Change release signing",
        "risk_level" => "high"
      })

    attrs = %{"expected_output" => "Signed build", "review_route" => "Manual review"}

    assert {:error, :high_risk_confirmation_required} =
             Work.mark_harness_packet_ready(packet, attrs)

    assert {:ok, ready_packet} =
             Work.mark_harness_packet_ready(packet, Map.put(attrs, "confirm_high_risk", "true"))

    assert ready_packet.state == "ready"
  end
end
