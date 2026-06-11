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
    assert File.regular?(Path.join(path, "CLAUDE.md"))
    assert File.dir?(Path.join(path, ".skills"))
    assert File.regular?(Path.join(path, ".skills/opportunity-research/SKILL.md"))
    assert File.dir?(Path.join(path, ".git"))

    for step <- ~w(competitor-discovery demand-proof pain-strength incumbent-weakness
                   wedge-clarity build-distribution-feasibility score-aggregator) do
      assert File.regular?(Path.join(path, ".skills/#{step}/SKILL.md"))
    end

    assert File.read!(Path.join(path, "AGENTS.md")) =~ "App Opportunities Agent Instructions"
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
    assert File.dir?(Path.join(opportunity_root, Opportunities.steps_path()))
    refute File.dir?(Path.join(opportunity_root, "generated_other_files"))

    assert [listed] = Opportunities.list_opportunities()
    assert listed["id"] == opportunity["id"]

    assert [run] = Opportunities.list_runs(opportunity["id"])
    assert run["status"] == "completed"
    assert run["codex_session_id"] == opportunity["codex_session_id"]

    steps = Opportunities.list_step_results(opportunity["id"])
    assert length(steps) == 7
    assert Enum.all?(steps, &(&1["status"] == "pending"))
    assert Enum.map(steps, & &1["step_index"]) == Enum.to_list(0..6)
    assert List.first(steps)["step_key"] == "competitor_discovery"
    assert List.last(steps)["artifact_path"] == "steps/06-score-aggregator.md"
    assert Enum.all?(steps, &(&1["run_id"] == run["id"]))

    assert {:ok, files} = Opportunities.list_opportunity_files(opportunity["id"])
    assert Enum.any?(files, &(&1.relative_path == "README.md"))

    assert {:ok, file} = Opportunities.read_opportunity_file(opportunity["id"], "README.md")
    assert file.type == "markdown"
    assert file.content =~ "Receipt packet for restaurant shift disputes"
  end

  test "create_opportunity with the claude_code agent records fake Claude Code completion" do
    path = unique_repo_path()
    {:ok, _repo} = Opportunities.create_repo_from_template(%{"repo_path" => path})

    :ok = Afp.Factory.Events.subscribe_run_activity()

    assert {:ok, result} =
             Opportunities.create_opportunity(%{
               "raw_input" => "Local-first habit tracker for shift workers",
               "agent" => "claude_code"
             })

    opportunity = result.opportunity

    assert_received {:opportunity_run_activity,
                     %{
                       opportunity_id: activity_opportunity_id,
                       activity: %{"kind" => "tool", "agent" => "claude_code"}
                     }}

    assert activity_opportunity_id == opportunity["id"]

    assert_received {:opportunity_run_activity,
                     %{activity: %{"kind" => "message", "text" => text}}}

    assert text =~ "Fake Claude Code analyzing"

    assert opportunity["agent"] == "claude_code"
    assert opportunity["status"] == "researched"
    assert opportunity["stage"] == "Initial Claude Code research completed"
    assert opportunity["codex_session_id"] =~ "fake-claude-session-"
    assert opportunity["latest_summary"] =~ "Fake Claude Code completed"

    assert [run] = Opportunities.list_runs(opportunity["id"])
    assert run["agent"] == "claude_code"
    assert run["status"] == "completed"
    assert run["codex_session_id"] == opportunity["codex_session_id"]
  end

  test "create_opportunity rejects unsupported agents" do
    path = unique_repo_path()
    {:ok, _repo} = Opportunities.create_repo_from_template(%{"repo_path" => path})

    assert {:error, {:unsupported_agent, "gemini"}} =
             Opportunities.create_opportunity(%{
               "raw_input" => "Some demand input",
               "agent" => "gemini"
             })
  end

  test "outdated repos are upgraded in place: columns, step table, and template files" do
    path = unique_repo_path()
    {:ok, _repo} = Opportunities.create_repo_from_template(%{"repo_path" => path})

    db_path = Path.join(path, "base.sqlite")

    # Rewind the repo to a pre-v3 state: no agent columns, no step table,
    # old metadata versions, stale AGENTS.md, missing step skills and CLAUDE.md.
    {_output, 0} =
      System.cmd(
        "sqlite3",
        [
          db_path,
          """
          ALTER TABLE opportunities DROP COLUMN agent;
          ALTER TABLE opportunity_runs DROP COLUMN agent;
          DROP TABLE opportunity_step_results;
          DROP TABLE opportunity_step_evidence;
          UPDATE repo_metadata SET value = '1' WHERE key = 'schema_version';
          DELETE FROM repo_metadata WHERE key = 'template_version';
          """
        ],
        stderr_to_stdout: true
      )

    File.write!(Path.join(path, "AGENTS.md"), "# OLD TEMPLATE\n")
    File.rm!(Path.join(path, "CLAUDE.md"))
    File.rm_rf!(Path.join(path, ".skills/competitor-discovery"))

    assert {:ok, repo} = Opportunities.refresh_configured_repo()
    assert repo["health_state"] == "healthy"
    assert repo["schema_version"] == "4"

    agents_md = File.read!(Path.join(path, "AGENTS.md"))
    refute agents_md =~ "OLD TEMPLATE"
    assert agents_md =~ "Research Pipeline"
    assert File.regular?(Path.join(path, "CLAUDE.md"))
    assert File.regular?(Path.join(path, ".skills/competitor-discovery/SKILL.md"))
    assert File.regular?(Path.join(path, ".skills/score-aggregator/SKILL.md"))

    {output, 0} =
      System.cmd("sqlite3", [db_path, "SELECT name FROM pragma_table_info('opportunities')"],
        stderr_to_stdout: true
      )

    assert output =~ "agent"

    {version_output, 0} =
      System.cmd(
        "sqlite3",
        [db_path, "SELECT value FROM repo_metadata WHERE key = 'template_version'"],
        stderr_to_stdout: true
      )

    assert String.trim(version_output) == "4"

    assert {:ok, result} =
             Opportunities.create_opportunity(%{
               "raw_input" => "Upgraded repo launch",
               "agent" => "claude_code"
             })

    assert result.opportunity["agent"] == "claude_code"
    assert length(Opportunities.list_step_results(result.opportunity["id"])) == 7
  end

  test "list_step_evidence returns registered evidence files" do
    path = unique_repo_path()
    {:ok, _repo} = Opportunities.create_repo_from_template(%{"repo_path" => path})

    {:ok, %{opportunity: opportunity}} =
      Opportunities.create_opportunity(%{"raw_input" => "Receipt packet for shift disputes"})

    assert Opportunities.list_step_evidence(opportunity["id"]) == []

    {_output, 0} =
      System.cmd(
        "sqlite3",
        [
          Path.join(path, "base.sqlite"),
          """
          INSERT INTO opportunity_step_evidence
            (id, opportunity_id, step_key, title, kind, file_path, why_it_matters,
             source_url, created_at, updated_at)
          VALUES
            ('ev-1', '#{opportunity["id"]}', 'competitor_discovery',
             'Competitor A app store listing', 'screenshot',
             'steps/00-competitor-discovery/competitor-a-app-store.png',
             'Anchors competitor A pricing and rating claims',
             'https://example.com/app', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
          """
        ],
        stderr_to_stdout: true
      )

    assert [evidence] = Opportunities.list_step_evidence(opportunity["id"])
    assert evidence["step_key"] == "competitor_discovery"
    assert evidence["kind"] == "screenshot"
    assert evidence["file_path"] == "steps/00-competitor-discovery/competitor-a-app-store.png"
  end
end
