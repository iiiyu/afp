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

  test "create_source_repo marks required sqlite as missing" do
    path = demand_repo_fixture(%{"demand.sqlite3" => nil})

    {:ok, source_repo} = Demand.create_source_repo(%{"repo_path" => path})

    assert source_repo.health_state == "sqlite_missing"
    assert Enum.any?(source_repo.missing_paths, &String.ends_with?(&1, "demand.sqlite3"))
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
