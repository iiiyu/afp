# @input  - Evidence and metrics context fixtures
# @output - Assertions for manual proof and business snapshot behavior
# @pos    - Context tests for evidence links and partial metrics snapshots
defmodule Afp.Factory.EvidenceMetricsTest do
  use Afp.DataCase, async: true

  import Afp.FactoryFixtures

  alias Afp.Factory.Evidence
  alias Afp.Factory.Metrics

  test "evidence can link to multiple objects without deleting packet" do
    app = app_fixture()
    ticket = ticket_fixture(app)
    evidence = evidence_fixture(app)

    assert {:ok, _link} = Evidence.attach_evidence(evidence, "app", app.id, "Primary app proof")

    assert {:ok, _link} =
             Evidence.attach_evidence(evidence, "ticket", ticket.id, "Ticket review proof")

    assert Evidence.count_links("app", app.id) == 1
    assert Evidence.count_links("ticket", ticket.id) == 1
    assert Evidence.get_evidence_packet!(evidence.id).id == evidence.id
  end

  test "metrics snapshot accepts blank numeric fields" do
    app = app_fixture(%{"lifecycle_stage" => "live", "business_posture" => "grow"})

    assert {:ok, snapshot} =
             Metrics.create_metrics_snapshot(%{
               "app_id" => app.id,
               "snapshot_date" => Date.utc_today(),
               "notes" => "Manual check"
             })

    assert snapshot.downloads == nil
    assert snapshot.notes == "Manual check"
  end

  test "live apps without recent snapshot are flagged" do
    app = app_fixture(%{"lifecycle_stage" => "live", "business_posture" => "maintain"})

    assert Enum.any?(Metrics.apps_with_stale_metrics(), &(&1.id == app.id))
  end
end
