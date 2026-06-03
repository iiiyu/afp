# @input  - Demand context fixtures and promotion params
# @output - Assertions for demand capture, launch requests, and app promotion
# @pos    - Context tests for pre-app demand management behavior
defmodule Afp.Factory.DemandTest do
  use Afp.DataCase, async: true

  import Afp.FactoryFixtures

  alias Afp.Factory.Demand

  test "create_demand_item stores pre-app validation work" do
    {:ok, demand_item} =
      Demand.create_demand_item(%{
        "title" => "Lightweight ASO tracker",
        "validation_action" => "Find five App Store complaints",
        "confidence" => "low"
      })

    assert demand_item.status == "captured"
    assert demand_item.confidence == "low"
    assert demand_item.promoted_app_id == nil
  end

  test "create_launch_request_from_demand builds a manual handoff" do
    demand_item = demand_item_fixture()

    {:ok, launch_request} =
      Demand.create_launch_request_from_demand(demand_item, %{
        "risk_level" => "normal",
        "status" => "ready"
      })

    assert launch_request.demand_item_id == demand_item.id
    assert launch_request.source_type == "demand_item"
    assert launch_request.objective == demand_item.validation_action
    assert launch_request.handoff_text =~ demand_item.title
  end

  test "promote_to_app links validated demand to a new app" do
    demand_item = demand_item_fixture(%{"status" => "validated"})

    assert {:ok, promoted_demand_item, app} =
             Demand.promote_to_app(demand_item, %{
               "name" => "Demand Promoted App",
               "platforms" => "ios",
               "lifecycle_stage" => "validation_ready",
               "business_posture" => "grow"
             })

    assert promoted_demand_item.status == "promoted"
    assert promoted_demand_item.promoted_app_id == app.id
    assert app.next_action == demand_item.validation_action
    assert app.product_thesis["source_demand_item_id"] == demand_item.id
  end

  test "promote_to_app requires validated demand" do
    demand_item = demand_item_fixture(%{"status" => "validating"})

    assert {:error, :demand_not_validated} =
             Demand.promote_to_app(demand_item, %{
               "name" => "Too Early App",
               "platforms" => "ios"
             })
  end

  test "high risk launch requests require confirmation before ready" do
    demand_item = demand_item_fixture()

    assert {:error, changeset} =
             Demand.create_launch_request_from_demand(demand_item, %{
               "risk_level" => "high",
               "status" => "ready"
             })

    assert %{confirmation: ["can't be blank"]} = errors_on(changeset)
  end
end
