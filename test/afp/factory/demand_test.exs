# @input  - Demand context fixtures and promotion params
# @output - Assertions for demand capture, launch requests, and app promotion
# @pos    - Context tests for pre-app demand management behavior
defmodule Afp.Factory.DemandTest do
  use Afp.DataCase, async: true

  import Afp.FactoryFixtures

  alias Afp.Factory.Demand

  test "create_source_repo reads unified demand repo manifest and health" do
    source_repo = demand_source_repo_fixture()

    assert source_repo.health_state == "healthy"
    assert source_repo.kind == "product_demand_repo"
    assert source_repo.lanes == ["app", "game"]
    assert source_repo.agent_entrypoint == "AGENTS.md"
    assert source_repo.sqlite_path == "demand.sqlite3"
  end

  test "create_source_repo_from_template scaffolds and registers a healthy source" do
    path = unique_repo_path()

    assert {:ok, source_repo} =
             Demand.create_source_repo_from_template(%{
               "repo_path" => path,
               "display_name" => "Standard Product Demand"
             })

    assert source_repo.health_state == "healthy"
    assert source_repo.display_name == "Standard Product Demand"
    assert source_repo.lanes == ["app", "game"]
    assert "read_index" in source_repo.sqlite_allowed_operations
    assert File.regular?(Path.join(path, "afp-demand-source.json"))
    assert File.regular?(Path.join(path, "AGENTS.md"))
    assert File.regular?(Path.join(path, "README.md"))
    assert File.regular?(Path.join(path, "sqlite/schema.sql"))
    assert File.regular?(Path.join(path, "demand.sqlite3"))
    assert File.dir?(Path.join(path, ".git"))
    assert File.read!(Path.join(path, "AGENTS.md")) =~ "proven demand"
    assert File.read!(Path.join(path, "AGENTS.md")) =~ "IP safety"

    assert {:ok, result} = Demand.refresh_source_repo_index(source_repo)
    assert result.candidates == []
  end

  test "create_source_repo_from_template refuses non-empty paths" do
    path = unique_repo_path()
    File.write!(Path.join(path, "existing.md"), "# Existing\n")

    assert {:error, :target_not_empty} =
             Demand.create_source_repo_from_template(%{"repo_path" => path})
  end

  test "create_source_repo marks required sqlite as missing" do
    path = demand_repo_fixture(%{"demand.sqlite3" => nil})

    {:ok, source_repo} = Demand.create_source_repo(%{"repo_path" => path})

    assert source_repo.health_state == "sqlite_missing"
    assert Enum.any?(source_repo.missing_paths, &String.ends_with?(&1, "demand.sqlite3"))
  end

  test "create_source_repo detects legacy AppIdeas layout without adopting it" do
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

    {:ok, source_repo} = Demand.create_source_repo(%{"repo_path" => path})

    assert source_repo.health_state == "manifest_missing"
    assert source_repo.payload["legacy_adapter"]["kind"] == "legacy_app_ideas"
    assert source_repo.payload["legacy_adapter"]["confidence"] == "high"
    assert source_repo.health_summary =~ "Legacy AppIdeas"
  end

  test "run_scheduled_research drafts scan handoffs for due healthy sources" do
    source_repo =
      demand_source_repo_fixture(%{
        "repo_path" => demand_repo_fixture(),
        "schedule_enabled" => true,
        "schedule_interval_hours" => 12
      })

    assert [due_source] = Demand.list_due_scheduled_source_repos()
    assert due_source.id == source_repo.id

    assert {:ok, summary} = Demand.run_scheduled_research()

    assert summary.created == 1
    assert [run] = Demand.list_research_runs(%{"run_type" => "scheduled_scan"})
    assert run.status == "draft"
    assert run.demand_source_repo_id == source_repo.id
    assert run.launch_request.status == "draft"
    assert Demand.get_source_repo!(source_repo.id).last_run_at != nil
  end

  test "refresh_source_repo_index imports candidates from repo-local sqlite" do
    source_repo = demand_source_repo_fixture(%{"repo_path" => sqlite_demand_repo_fixture()})

    assert {:ok, result} = Demand.refresh_source_repo_index(source_repo)

    assert length(result.candidates) == 1
    candidate = hd(result.candidates)
    assert candidate.source_status == "validation-ready"
    assert candidate.confidence == "medium"
    assert candidate.score == 86
    assert candidate.primary_path == "candidates/app/sqlite-candidate.md"
    assert candidate.payload["sqlite_row"]["confidence"] == "medium-high"
    assert result.source_repo.latest_index_at != nil
    assert result.research_run.status == "completed"
  end

  test "refresh_source_repo_index requires declared sqlite read operation" do
    path =
      sqlite_demand_repo_fixture([], %{
        "afp-demand-source.json" => """
        {
          "schema_version": 2,
          "kind": "product_demand_repo",
          "display_name": "No Read Demand",
          "lanes": ["app"],
          "agent_contract": {"entrypoint": "AGENTS.md", "required": true},
          "write_targets": {"candidates": "candidates"},
          "sqlite": {
            "path": "demand.sqlite3",
            "mode": "required",
            "owner": "repo",
            "allowed_operations": ["upsert_candidate"]
          }
        }
        """
      })

    source_repo = demand_source_repo_fixture(%{"repo_path" => path})

    assert {:error, :read_operation_not_allowed} = Demand.refresh_source_repo_index(source_repo)
  end

  test "index_candidate keeps repo source status separate from afp status" do
    source_repo = demand_source_repo_fixture()

    {:ok, candidate} =
      Demand.index_candidate(source_repo, %{
        "lane" => "game",
        "title" => "Tiny Territory Runner",
        "source_status" => "validation-ready",
        "afp_status" => "not_picked_up",
        "score" => 79,
        "confidence" => "high"
      })

    assert candidate.external_id == "tiny-territory-runner"
    assert candidate.source_status == "validation-ready"
    assert candidate.afp_status == "not_picked_up"
    assert candidate.source_repo.id == source_repo.id
  end

  test "pick_up_candidate creates a linked demand item" do
    candidate = demand_candidate_fixture()

    assert {:ok, picked_up_candidate, demand_item} = Demand.pick_up_candidate(candidate)

    assert picked_up_candidate.afp_status == "picked_up"
    assert picked_up_candidate.demand_item_id == demand_item.id
    assert demand_item.status == "validating"
    assert demand_item.validation_action == candidate.validation_action
  end

  test "create_candidate_launch_request renders template and stores run history" do
    candidate = demand_candidate_fixture()
    template = message_template_fixture()

    assert {:ok, records} =
             Demand.create_candidate_launch_request(candidate, template, %{
               "risk_level" => "normal",
               "status" => "ready",
               "edited_body" => "Edited handoff for {{candidate_title}}"
             })

    assert records.launch_request.source_type == "demand_candidate"
    assert records.launch_request.source_id == candidate.id
    assert records.launch_request.handoff_text == "Edited handoff for {{candidate_title}}"
    assert records.research_run.status == "ready"
    assert records.research_run.rendered_message =~ candidate.title
    assert records.sent_message.status == "confirmed"
  end

  test "create_source_launch_request records manual idea research before a candidate exists" do
    source_repo = demand_source_repo_fixture()

    template =
      message_template_fixture(%{
        "name" => "Manual Idea Source Research",
        "default_run_type" => "manual_idea",
        "required_variables" => "repo_path\ninput_text",
        "body" => "Follow {{agent_entrypoint}} in {{repo_path}} and research {{input_text}}."
      })

    assert {:ok, records} =
             Demand.create_source_launch_request(source_repo, template, %{
               "run_type" => "manual_idea",
               "lane" => "app",
               "input_text" => "receipt scanner for tiny businesses",
               "risk_level" => "normal",
               "status" => "ready"
             })

    assert records.launch_request.source_type == "demand_source_repo"
    assert records.launch_request.source_id == source_repo.id
    assert records.research_run.demand_source_repo_id == source_repo.id
    assert records.research_run.input_text == "receipt scanner for tiny businesses"
    assert records.research_run.status == "ready"
    assert records.sent_message.rendered_body =~ "receipt scanner"
  end

  test "launch_research_request_with_codex records direct Codex session state" do
    source_repo = demand_source_repo_fixture()

    template =
      message_template_fixture(%{
        "name" => "Codex Source Research",
        "default_run_type" => "manual_idea",
        "required_variables" => "repo_path\ninput_text",
        "body" => "Follow {{agent_entrypoint}} in {{repo_path}} and research {{input_text}}."
      })

    {:ok, records} =
      Demand.create_source_launch_request(source_repo, template, %{
        "run_type" => "manual_idea",
        "lane" => "app",
        "input_text" => "receipt scanner for tiny businesses",
        "risk_level" => "normal",
        "status" => "ready"
      })

    assert {:ok, launched} = Demand.launch_research_request_with_codex(records.launch_request)

    assert launched.launch_request.status == "launched"
    assert launched.launch_request.launch_mode == "direct_codex"
    assert launched.research_run.status == "completed"
    assert launched.research_run.codex_session_id == launched.codex_session.id
    assert launched.sent_message.status == "sent"
    assert launched.sent_message.codex_session_id == launched.codex_session.id
    assert launched.codex_session.external_session_id =~ "fake-session-"
    assert launched.codex_session.cwd == source_repo.repo_path
    assert launched.codex_result["turn_status"] == "completed"
    assert launched.codex_result["final_answer"] =~ "Fake Codex completed"
  end

  test "launch_research_request_with_codex requires confirmation for high risk requests" do
    source_repo = demand_source_repo_fixture()

    template =
      message_template_fixture(%{
        "required_variables" => "repo_path",
        "body" => "Follow {{agent_entrypoint}} in {{repo_path}}."
      })

    {:ok, records} =
      Demand.create_source_launch_request(source_repo, template, %{
        "risk_level" => "high",
        "status" => "draft"
      })

    assert {:error, :confirmation_required} =
             Demand.launch_research_request_with_codex(records.launch_request)

    assert Demand.get_research_run!(records.research_run.id).status == "draft"
  end

  test "create_session_followup links a message to an existing Codex session" do
    source_repo = demand_source_repo_fixture()

    {:ok, research_run} =
      Demand.create_research_run(%{
        "demand_source_repo_id" => source_repo.id,
        "run_type" => "manual_idea",
        "lane" => "app",
        "objective" => "Research follow-up target",
        "input_text" => "receipt scanner"
      })

    session = codex_session_fixture(%{"cwd" => source_repo.repo_path})

    template =
      message_template_fixture(%{
        "name" => "Continue Demand Session",
        "default_target" => "existing_session",
        "required_variables" => "session_id\nreview_note",
        "body" => "Continue {{session_id}} with reviewer note: {{review_note}}"
      })

    assert {:ok, records} =
             Demand.create_session_followup(research_run, session, template, %{
               "review_note" => "Tighten the evidence table",
               "risk_level" => "normal",
               "status" => "ready"
             })

    assert records.launch_request.source_type == "demand_research_run"
    assert records.launch_request.source_id == research_run.id
    assert records.research_run.codex_session_id == session.id
    assert records.sent_message.codex_session_id == session.id
    assert records.sent_message.target == "existing_session"
    assert records.sent_message.rendered_body =~ "Tighten the evidence table"
  end

  test "verify_candidate_package marks app package ready when required files exist" do
    package_path = "packages/app/ready-app"

    files =
      ~w(README.md PRD.md VALIDATION_PLAN.md MVP_SCOPE.md DATA_MODEL.md UX_FLOW.md PROTOTYPE.md)
      |> Map.new(&{Path.join(package_path, &1), "# #{&1}\n"})

    source_repo = demand_source_repo_fixture(%{"repo_path" => demand_repo_fixture(files)})
    candidate = demand_candidate_fixture(source_repo, %{"package_path" => package_path})

    assert {:ok, package_candidate} = Demand.verify_candidate_package(candidate)

    assert package_candidate.afp_status == "package_ready"
    assert package_candidate.approved_for_package_at != nil
  end

  test "verify_candidate_package reports missing required files" do
    package_path = "packages/game/missing-game"
    source_repo = demand_source_repo_fixture(%{"repo_path" => demand_repo_fixture(%{})})

    candidate =
      demand_candidate_fixture(source_repo, %{"lane" => "game", "package_path" => package_path})

    assert {:error, {:package_missing, missing_paths}} =
             Demand.verify_candidate_package(candidate)

    assert "PRD.md" in missing_paths
    assert "DESIGN_KIT.md" in missing_paths
    assert "IMPLEMENTATION_BRIEF.md" in missing_paths
  end

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
