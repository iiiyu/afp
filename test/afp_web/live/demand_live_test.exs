# @input  - Demand LiveView forms and demand fixtures
# @output - Assertions for demand creation and app promotion from the UI
# @pos    - LiveView tests for the pre-app demand management surface
defmodule AfpWeb.DemandLiveTest do
  use AfpWeb.ConnCase, async: true

  import Afp.FactoryFixtures

  alias Afp.Factory.Demand
  alias Afp.Factory.Portfolio

  test "creates a demand item", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/demand")

    html =
      view
      |> form("#demand-form",
        demand_item: %{
          title: "Find narrow screenshot workflow",
          validation_action: "Collect three user examples",
          confidence: "medium"
        }
      )
      |> render_submit()

    assert html =~ "Demand item created."
    assert Enum.any?(Demand.list_demand_items(), &(&1.title == "Find narrow screenshot workflow"))
  end

  test "promotes validated demand into an app", %{conn: conn} do
    demand_item = demand_item_fixture(%{"status" => "validated"})

    {:ok, view, _html} = live(conn, ~p"/demand")

    html =
      view
      |> form("#promote-demand-form",
        promotion: %{
          demand_item_id: demand_item.id,
          name: "Promoted From LiveView",
          lifecycle_stage: "validation_ready",
          business_posture: "grow"
        }
      )
      |> render_submit()

    assert html =~ "Demand promoted to Promoted From LiveView."

    assert Enum.any?(
             Portfolio.list_apps(%{"include_archived" => "true"}),
             &(&1.name == "Promoted From LiveView")
           )
  end
end
