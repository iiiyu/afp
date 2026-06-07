# @input  - Demand LiveView forms and demand fixtures
# @output - Assertions for demand creation and app promotion from the UI
# @pos    - LiveView tests for the pre-app demand management surface
defmodule AfpWeb.DemandLiveTest do
  use AfpWeb.ConnCase, async: true

  import Afp.FactoryFixtures

  alias Afp.Factory.Demand
  alias Afp.Factory.Portfolio

  test "creates a standard source repo from the demand action rail", %{conn: conn} do
    path = unique_repo_path()

    {:ok, view, _html} = live(conn, ~p"/demand")

    html =
      view
      |> form("#source-repo-template-form",
        source_repo_template: %{
          repo_path: path,
          display_name: "Created Demand Source",
          schedule_enabled: "false",
          schedule_interval_hours: "12"
        }
      )
      |> render_submit()

    assert html =~ "Standard demand source repo created."
    assert html =~ "Created Demand Source"
    assert File.regular?(Path.join(path, "AGENTS.md"))
    assert File.regular?(Path.join(path, "demand.sqlite3"))
    assert hd(Demand.list_source_repos()).health_state == "healthy"
  end

  test "refreshes a source repo index from sqlite", %{conn: conn} do
    path = sqlite_demand_repo_fixture()

    {:ok, view, _html} = live(conn, ~p"/demand")

    view
    |> form("#source-repo-form",
      source_repo: %{
        repo_path: path,
        display_name: "SQLite Demand Source"
      }
    )
    |> render_submit()

    source_repo = hd(Demand.list_source_repos())

    html =
      view
      |> form("#source-refresh-#{source_repo.id}")
      |> render_submit()

    assert html =~ "Demand source refreshed with 1 candidates."
    assert html =~ "SQLite Candidate"
    assert Enum.any?(Demand.list_candidates(), &(&1.source_repo.id == source_repo.id))
  end

  test "shows legacy source detection for manifest-missing repos", %{conn: conn} do
    path =
      temp_git_repo_fixture(%{
        "README.md" => "# AppIdeas\n",
        "config/sources.md" => "",
        "daily/.keep" => "",
        "evidence/.keep" => "",
        "reports/.keep" => "",
        "memory/.keep" => "",
        "templates/.keep" => ""
      })

    {:ok, view, _html} = live(conn, ~p"/demand")

    html =
      view
      |> form("#source-repo-form",
        source_repo: %{
          repo_path: path,
          display_name: "Legacy AppIdeas"
        }
      )
      |> render_submit()

    assert html =~ "Legacy adapter: Legacy AppIdeas"
    assert hd(Demand.list_source_repos()).health_state == "manifest_missing"
  end

  test "updates an existing source repo schedule", %{conn: conn} do
    source_repo =
      demand_source_repo_fixture(%{
        "repo_path" => demand_repo_fixture(),
        "schedule_enabled" => false,
        "schedule_interval_hours" => 12
      })

    {:ok, view, _html} = live(conn, ~p"/demand")

    html =
      view
      |> form("#source-schedule-#{source_repo.id}",
        source_repo_id: source_repo.id,
        source_schedule: %{
          schedule_enabled: "true",
          schedule_interval_hours: "6"
        }
      )
      |> render_submit()

    updated_source = Demand.get_source_repo!(source_repo.id)

    assert html =~ "Source schedule updated."
    assert updated_source.schedule_enabled
    assert updated_source.schedule_interval_hours == 6
    assert [due_source] = Demand.list_due_scheduled_source_repos()
    assert due_source.id == source_repo.id
  end

  test "runs due scheduled research from the source panel", %{conn: conn} do
    path = demand_repo_fixture()

    {:ok, view, _html} = live(conn, ~p"/demand")

    view
    |> form("#source-repo-form",
      source_repo: %{
        repo_path: path,
        display_name: "Scheduled Source",
        schedule_enabled: "true",
        schedule_interval_hours: "12"
      }
    )
    |> render_submit()

    source_repo = hd(Demand.list_source_repos())
    assert source_repo.schedule_enabled
    assert source_repo.health_state == "healthy"
    assert [due_source] = Demand.list_due_scheduled_source_repos()
    assert due_source.id == source_repo.id

    html =
      view
      |> element("#scheduled-research-button")
      |> render_click()

    assert Enum.any?(Demand.list_research_runs(), &(&1.run_type == "scheduled_scan"))
    assert html =~ "Scheduled research drafted for 1 sources."
  end

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

  test "creates a source research handoff before a candidate exists", %{conn: conn} do
    path = demand_repo_fixture()

    {:ok, view, _html} = live(conn, ~p"/demand")

    view
    |> form("#source-repo-form",
      source_repo: %{
        repo_path: path,
        display_name: "Manual Research Source"
      }
    )
    |> render_submit()

    source_repo = hd(Demand.list_source_repos())

    view
    |> form("#message-template-form",
      message_template: %{
        name: "Manual Idea Research",
        purpose: "Research manual idea",
        default_run_type: "manual_idea",
        default_lane: "app",
        default_target: "manual_handoff",
        required_variables: "repo_path\ninput_text",
        body: "Follow {{agent_entrypoint}} in {{repo_path}} and research {{input_text}}."
      }
    )
    |> render_submit()

    template = hd(Demand.list_message_templates())

    html =
      view
      |> form("#source-launch-form",
        source_launch: %{
          source_repo_id: source_repo.id,
          message_template_id: template.id,
          run_type: "manual_idea",
          lane: "app",
          input_text: "tiny business receipt scanner",
          risk_level: "normal",
          status: "ready"
        }
      )
      |> render_submit()

    assert html =~ "Source research task created."
    assert Enum.any?(Demand.list_launch_requests(), &(&1.source_type == "demand_source_repo"))

    assert Enum.any?(
             Demand.list_research_runs(),
             &(&1.input_text == "tiny business receipt scanner")
           )
  end

  test "launches a research task with Codex", %{conn: conn} do
    source_repo = demand_source_repo_fixture()

    template =
      message_template_fixture(%{
        "name" => "Live Codex Source Research",
        "default_run_type" => "manual_idea",
        "required_variables" => "repo_path\ninput_text",
        "body" => "Follow {{agent_entrypoint}} in {{repo_path}} and research {{input_text}}."
      })

    {:ok, records} =
      Demand.create_source_launch_request(source_repo, template, %{
        "run_type" => "manual_idea",
        "lane" => "app",
        "input_text" => "tiny business receipt scanner",
        "risk_level" => "normal",
        "status" => "ready"
      })

    {:ok, view, _html} = live(conn, ~p"/demand")

    html =
      view
      |> element("#launch-codex-#{records.launch_request.id}")
      |> render_click()

    assert html =~ "Codex launch started for"

    launched_request = Demand.get_launch_request!(records.launch_request.id)
    [run] = Demand.list_research_runs(%{"run_type" => "manual_idea"})

    assert launched_request.status == "launched"
    assert launched_request.launch_mode == "direct_codex"
    assert run.status == "completed"
    assert run.codex_session.external_session_id =~ "fake-session-"
  end

  test "verifies a candidate package from the source repo", %{conn: conn} do
    package_path = "packages/app/live-ready"

    files =
      ~w(README.md PRD.md VALIDATION_PLAN.md MVP_SCOPE.md DATA_MODEL.md UX_FLOW.md PROTOTYPE.md)
      |> Map.new(&{Path.join(package_path, &1), "# #{&1}\n"})

    source_repo = demand_source_repo_fixture(%{"repo_path" => demand_repo_fixture(files)})

    candidate =
      demand_candidate_fixture(source_repo, %{
        "title" => "Live Package Candidate",
        "package_path" => package_path
      })

    {:ok, view, _html} = live(conn, ~p"/demand")

    html =
      view
      |> form("#candidate-package-#{candidate.id}")
      |> render_submit()

    assert html =~ "Package verified for Live Package Candidate."
    assert Demand.get_candidate!(candidate.id).afp_status == "package_ready"
  end

  test "creates a follow-up handoff for an existing Codex session", %{conn: conn} do
    source_repo = demand_source_repo_fixture()

    {:ok, research_run} =
      Demand.create_research_run(%{
        "demand_source_repo_id" => source_repo.id,
        "run_type" => "manual_idea",
        "lane" => "app",
        "objective" => "Review a demand run",
        "input_text" => "tiny receipt scanner"
      })

    session = codex_session_fixture(%{"cwd" => source_repo.repo_path})

    template =
      message_template_fixture(%{
        "name" => "Live Continue Session",
        "default_target" => "existing_session",
        "required_variables" => "session_id\nreview_note",
        "body" => "Continue {{session_id}} using {{review_note}}."
      })

    {:ok, view, _html} = live(conn, ~p"/demand")

    html =
      view
      |> form("#session-followup-form",
        session_followup: %{
          research_run_id: research_run.id,
          codex_session_id: session.id,
          message_template_id: template.id,
          review_note: "Add package evidence",
          risk_level: "normal",
          status: "ready"
        }
      )
      |> render_submit()

    assert html =~ "Session follow-up handoff created."

    assert Enum.any?(
             Demand.list_launch_requests(),
             &(&1.source_type == "demand_research_run" and &1.source_id == research_run.id)
           )
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
