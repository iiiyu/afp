# @input  - Opportunity repo fixtures, fake Codex app client, and repo-local SQLite
# @output - Assertions for opportunity repo scaffold, health, launch state, and file reads
# @pos    - Context tests for the portable opportunities workflow
defmodule Afp.Factory.OpportunitiesTest do
  use Afp.DataCase, async: true

  import Afp.FactoryFixtures

  alias Afp.Factory.Opportunities

  test "create_repo_from_template scaffolds a healthy opportunity repo" do
    path = unique_repo_path()

    assert {:ok, repo} =
             Opportunities.create_repo_from_template(%{
               "repo_path" => path,
               "display_name" => "App Opportunities"
             })

    assert repo["health_state"] == "healthy"
    assert repo["display_name"] == "App Opportunities"
    assert File.regular?(Path.join(path, "base.sqlite"))
    assert File.dir?(Path.join(path, "opportunities"))
    assert File.regular?(Path.join(path, "AGENTS.md"))
    assert File.dir?(Path.join(path, ".skills"))
    assert File.regular?(Path.join(path, ".skills/opportunity-research/SKILL.md"))
    assert File.dir?(Path.join(path, ".git"))
    assert Opportunities.list_opportunities() == []
  end

  test "configure_repo reports missing base sqlite for incomplete existing repos" do
    path =
      temp_git_repo_fixture(%{
        "AGENTS.md" => "# Opportunity Repo\n",
        ".skills/.keep" => "",
        "opportunities/.keep" => ""
      })

    assert {:ok, repo} =
             Opportunities.configure_repo(%{
               "repo_path" => path,
               "display_name" => "Incomplete Opportunities"
             })

    assert repo["health_state"] == "sqlite_missing"
    assert Enum.any?(repo["missing_paths"], &String.ends_with?(&1, "base.sqlite"))
  end

  test "create_opportunity_with_codex creates files and records fake Codex completion" do
    path = unique_repo_path()
    {:ok, _repo} = Opportunities.create_repo_from_template(%{"repo_path" => path})

    assert {:ok, result} =
             Opportunities.create_opportunity_with_codex(%{
               "raw_input" => "Receipt packet for restaurant shift disputes"
             })

    opportunity = result.opportunity

    assert opportunity["status"] == "researched"
    assert opportunity["stage"] == "Initial Codex research completed"
    assert opportunity["codex_session_id"] =~ "fake-session-"
    assert opportunity["latest_summary"] =~ "Fake Codex completed"

    opportunity_root = Path.join([path, "opportunities", opportunity["id"]])
    assert File.regular?(Path.join(opportunity_root, "README.md"))
    assert File.dir?(Path.join(opportunity_root, Opportunities.generated_files_path()))

    assert [listed] = Opportunities.list_opportunities()
    assert listed["id"] == opportunity["id"]

    assert [run] = Opportunities.list_runs(opportunity["id"])
    assert run["status"] == "completed"
    assert run["codex_session_id"] == opportunity["codex_session_id"]

    assert {:ok, files} = Opportunities.list_opportunity_files(opportunity["id"])
    assert Enum.any?(files, &(&1.relative_path == "README.md"))

    assert {:ok, file} = Opportunities.read_opportunity_file(opportunity["id"], "README.md")
    assert file.type == "markdown"
    assert file.content =~ "Receipt packet for restaurant shift disputes"
  end
end
