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
          raw_input: "Receipt packet for restaurant shift disputes"
        }
      )
      |> render_submit()

    [opportunity] = Opportunities.list_opportunities()
    assert opportunity["status"] == "researched"

    case submit_result do
      {:error, {:live_redirect, %{to: to}}} ->
        assert to == ~p"/opportunities/#{opportunity["id"]}"

      html when is_binary(html) ->
        assert html =~ opportunity["title"]
    end

    {:ok, _detail_view, detail_html} = live(conn, ~p"/opportunities/#{opportunity["id"]}")

    assert detail_html =~ "Files"
    assert detail_html =~ "README.md"
    assert detail_html =~ "Receipt packet for restaurant shift disputes"
    assert detail_html =~ "Fake Codex completed"
  end

  test "creates an opportunity with the Claude Code agent", %{conn: conn} do
    path = unique_repo_path()
    {:ok, _repo} = Opportunities.create_repo_from_template(%{"repo_path" => path})

    {:ok, view, html} = live(conn, ~p"/opportunities")
    assert html =~ "New Opportunity"

    view
    |> form("#opportunity-prompt-form",
      opportunity: %{
        raw_input: "Local-first habit tracker for shift workers",
        agent: "claude_code"
      }
    )
    |> render_submit()

    [opportunity] = Opportunities.list_opportunities()
    assert opportunity["agent"] == "claude_code"
    assert opportunity["status"] == "researched"

    {:ok, detail_view, detail_html} = live(conn, ~p"/opportunities/#{opportunity["id"]}")

    assert detail_html =~ "Agent Session"
    assert detail_html =~ "Claude Code"
    assert detail_html =~ "Fake Claude Code completed"

    assert detail_html =~ "Research Steps"
    assert detail_html =~ "Competitor Discovery"
    assert detail_html =~ "Score Aggregator"
    assert has_element?(detail_view, "#research-step-demand_proof")
  end

  test "renders live run activity on the detail page", %{conn: conn} do
    path = unique_repo_path()
    {:ok, _repo} = Opportunities.create_repo_from_template(%{"repo_path" => path})

    {:ok, %{opportunity: opportunity}} =
      Opportunities.create_opportunity(%{
        "raw_input" => "Local-first habit tracker for shift workers",
        "agent" => "claude_code"
      })

    {:ok, view, html} = live(conn, ~p"/opportunities/#{opportunity["id"]}")
    refute html =~ "Live activity"

    send(
      view.pid,
      {:opportunity_run_activity,
       %{
         opportunity_id: opportunity["id"],
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
