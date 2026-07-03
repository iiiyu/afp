# @input  - Opportunity LiveView forms, temporary repos, and fake Codex launch results
# @output - Assertions for setup, prompt launch, table state, and detail file browser rendering
# @pos    - LiveView tests for the opportunities repo console
defmodule AfpWeb.OpportunitiesLiveTest do
  use AfpWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Afp.FactoryFixtures

  alias Afp.Factory.Opportunities

  test "initializes a new opportunity repo from the setup screen", %{conn: conn} do
    path = unique_repo_path()

    {:ok, view, html} = live(conn, ~p"/opportunities")

    assert html =~ "No opportunity repo configured."

    html =
      view
      |> form("#opportunity-repo-template-form",
        opportunity_repo_template: %{
          repo_path: path,
          display_name: "Live Opportunities"
        }
      )
      |> render_submit()

    assert html =~ "Opportunity repo initialized."
    assert html =~ "New Opportunity"
    assert File.regular?(Path.join(path, "base.sqlite"))
    assert File.regular?(Path.join(path, "AGENTS.md"))
    assert File.dir?(Path.join(path, ".skills"))
  end

  test "creates an opportunity from a prompt and renders the detail file browser", %{conn: conn} do
    path = unique_repo_path()
    {:ok, _repo} = Opportunities.create_repo_from_template(%{"repo_path" => path})

    {:ok, view, html} = live(conn, ~p"/opportunities")
    assert html =~ "New Opportunity"

    submit_result =
      view
      |> form("#opportunity-prompt-form",
        opportunity: %{
          raw_input: "Receipt packet for restaurant shift disputes",
          agent: "codex"
        }
      )
      |> render_submit()

    [opportunity] = Opportunities.list_opportunities()
    assert opportunity.status == "researched"

    case submit_result do
      {:error, {:live_redirect, %{to: to}}} ->
        assert to == ~p"/opportunities/#{opportunity.id}"

      html when is_binary(html) ->
        assert html =~ opportunity.title
    end

    {:ok, detail_view, detail_html} = live(conn, ~p"/opportunities/#{opportunity.id}")

    assert detail_html =~ "Files"
    assert detail_html =~ "README.md"
    assert detail_html =~ "Receipt packet for restaurant shift disputes"
    assert detail_html =~ "Fake Codex completed"
    assert has_element?(detail_view, "#generate-build-spec-#{opportunity.id}")
  end

  test "creates an opportunity with the Claude Code agent", %{conn: conn} do
    path = unique_repo_path()
    {:ok, _repo} = Opportunities.create_repo_from_template(%{"repo_path" => path})

    {:ok, view, html} = live(conn, ~p"/opportunities")
    assert html =~ "New Opportunity"

    # Switching the agent re-renders the model dropdown with Claude models.
    changed_html =
      view
      |> form("#opportunity-prompt-form", opportunity: %{agent: "claude_code"})
      |> render_change()

    assert changed_html =~ "claude-opus-4-8"
    assert changed_html =~ "claude-fable-5"

    view
    |> form("#opportunity-prompt-form",
      opportunity: %{
        raw_input: "Local-first habit tracker for shift workers",
        agent: "claude_code",
        model: "claude-opus-4-8"
      }
    )
    |> render_submit()

    [opportunity] = Opportunities.list_opportunities()
    assert opportunity.agent == "claude_code"
    assert opportunity.status == "researched"

    {:ok, detail_view, detail_html} = live(conn, ~p"/opportunities/#{opportunity.id}")

    assert detail_html =~ "Agent Session"
    assert detail_html =~ "Claude Code"
    assert detail_html =~ "claude-opus-4-8"
    assert detail_html =~ "Fake Claude Code completed"

    assert detail_html =~ "Research Steps"
    assert detail_html =~ "Competitor Discovery"
    assert detail_html =~ "Score Aggregator"
    assert has_element?(detail_view, "#research-step-demand_proof")
  end

  test "renders registered step evidence under its step", %{conn: conn} do
    path = unique_repo_path()
    {:ok, _repo} = Opportunities.create_repo_from_template(%{"repo_path" => path})

    {:ok, %{opportunity: opportunity}} =
      Opportunities.create_opportunity(%{"raw_input" => "Receipt packet for shift disputes"})

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
            ('ev-live-1', '#{opportunity.id}', 'pain_strength',
             'Top complaint themes', 'source_excerpt',
             'steps/02-pain-strength/top-complaint-themes.md',
             'Backs the repeated-complaint pattern', '',
             '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
          """
        ],
        stderr_to_stdout: true
      )

    {:ok, view, html} = live(conn, ~p"/opportunities/#{opportunity.id}")

    assert html =~ "Top complaint themes"
    assert has_element?(view, "#research-step-pain_strength #step-evidence-ev-live-1")
  end

  test "detail page launches build spec generation for researched opportunities", %{conn: conn} do
    path = unique_repo_path()
    {:ok, _repo} = Opportunities.create_repo_from_template(%{"repo_path" => path})

    {:ok, %{opportunity: opportunity}} =
      Opportunities.create_opportunity(%{
        "raw_input" => "Receipt packet for shift disputes",
        "agent" => "codex"
      })

    {:ok, view, _html} = live(conn, ~p"/opportunities/#{opportunity.id}")
    assert has_element?(view, "#generate-build-spec-#{opportunity.id}")

    view
    |> element("#generate-build-spec-#{opportunity.id}")
    |> render_click()

    html = render(view)
    assert html =~ "PRD/spec generation launched"
    refute has_element?(view, "#generate-build-spec-#{opportunity.id}")

    {:ok, updated} = Opportunities.get_opportunity(opportunity.id)
    assert updated.status == "build_spec_ready"

    assert [build_spec_run, initial_run] = Opportunities.list_runs(opportunity.id)
    assert build_spec_run.run_type == "build_spec"
    assert initial_run.run_type == "initial_research"
  end

  test "launches with a custom model typed into the free-text field", %{conn: conn} do
    path = unique_repo_path()
    {:ok, _repo} = Opportunities.create_repo_from_template(%{"repo_path" => path})

    {:ok, view, html} = live(conn, ~p"/opportunities")

    # Claude Code is the default agent, so its models render first.
    assert html =~ "claude-fable-5"
    refute html =~ "Custom model"

    codex_html =
      view
      |> form("#opportunity-prompt-form", opportunity: %{agent: "codex"})
      |> render_change()

    assert codex_html =~ "gpt-5.5"

    custom_html =
      view
      |> form("#opportunity-prompt-form", opportunity: %{agent: "codex", model: "__custom__"})
      |> render_change()

    assert custom_html =~ "Custom model"

    view
    |> form("#opportunity-prompt-form",
      opportunity: %{
        raw_input: "Niche invoice tracker",
        agent: "codex",
        model: "__custom__",
        model_custom: "gpt-6-experimental"
      }
    )
    |> render_submit()

    [opportunity] = Opportunities.list_opportunities()
    [run] = Opportunities.list_runs(opportunity.id)
    assert run.model == "gpt-6-experimental"
  end

  test "renders live run activity on the detail page", %{conn: conn} do
    path = unique_repo_path()
    {:ok, _repo} = Opportunities.create_repo_from_template(%{"repo_path" => path})

    {:ok, %{opportunity: opportunity}} =
      Opportunities.create_opportunity(%{
        "raw_input" => "Local-first habit tracker for shift workers",
        "agent" => "claude_code"
      })

    {:ok, view, html} = live(conn, ~p"/opportunities/#{opportunity.id}")
    refute html =~ "Live activity"

    send(
      view.pid,
      {:opportunity_run_activity,
       %{
         opportunity_id: opportunity.id,
         run_id: "run-1",
         activity: %{
           "kind" => "tool",
           "text" => "Bash: sqlite3 base.sqlite",
           "agent" => "claude_code",
           "at" => "2026-01-01T00:00:00Z"
         }
       }}
    )

    html = render(view)
    assert html =~ "Live activity"
    assert html =~ "Bash: sqlite3 base.sqlite"

    send(
      view.pid,
      {:opportunity_run_activity,
       %{
         opportunity_id: "another-opportunity",
         run_id: "run-2",
         activity: %{"kind" => "message", "text" => "Unrelated activity"}
       }}
    )

    html = render(view)
    refute html =~ "Unrelated activity"
  end
end
