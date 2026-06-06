# @input  - Demand LiveView forms and demand fixtures
# @output - Assertions for demand creation and app promotion from the UI
# @pos    - LiveView tests for the pre-app demand management surface
defmodule AfpWeb.DemandLiveTest do
  use AfpWeb.ConnCase, async: true

  import Afp.FactoryFixtures

  alias Afp.Factory.Demand
  alias Afp.Factory.Portfolio

  test "creates source repo, candidate, template, and candidate handoff", %{conn: conn} do
    path = demand_repo_fixture()

    {:ok, view, _html} = live(conn, ~p"/demand")

    html =
      view
      |> form("#source-repo-form",
        source_repo: %{
          repo_path: path,
          display_name: "Live Demand Source"
        }
      )
      |> render_submit()

    assert html =~ "Demand source added."
    source_repo = hd(Demand.list_source_repos())

    html =
      view
      |> form("#candidate-form",
        candidate: %{
          demand_source_repo_id: source_repo.id,
          lane: "app",
          title: "Live Indexed Candidate",
          source_status: "validation-ready",
          afp_status: "pickup_recommended",
          confidence: "medium",
          validation_action: "Collect three buyer signals"
        }
      )
      |> render_submit()

    assert html =~ "Demand candidate indexed."
    candidate = hd(Demand.list_candidates())

    html =
      view
      |> form("#message-template-form",
        message_template: %{
          name: "Live Candidate Research",
          purpose: "Research candidate",
          default_run_type: "manual_idea",
          default_lane: "app",
          default_target: "manual_handoff",
          required_variables: "repo_path\ncandidate_title",
          body: "Follow {{agent_entrypoint}} in {{repo_path}} for {{candidate_title}}."
        }
      )
      |> render_submit()

    assert html =~ "Message template created."
    template = hd(Demand.list_message_templates())

    html =
      view
      |> form("#candidate-launch-form",
        candidate_launch: %{
          candidate_id: candidate.id,
          message_template_id: template.id,
          risk_level: "normal",
          status: "ready",
          edited_body: "Manual handoff from LiveView"
        }
      )
      |> render_submit()

    assert html =~ "Candidate launch handoff created."
    assert Enum.any?(Demand.list_launch_requests(), &(&1.source_id == candidate.id))
    assert Enum.any?(Demand.list_research_runs(), &(&1.demand_candidate_id == candidate.id))
  end

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
