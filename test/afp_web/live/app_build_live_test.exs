# @input  - A contract app repo fixture and the app detail LiveView
# @output - Assertions for the build surface: launch, review gate, reports
# @pos    - LiveView tests for BuildRunner v2 on the app repo detail page
defmodule AfpWeb.AppBuildLiveTest do
  use AfpWeb.ConnCase, async: true

  import Afp.FactoryFixtures

  alias Afp.Factory.Builds
  alias Afp.Factory.RepoSqlite

  test "detail page launches a milestone and enforces the review gate", %{conn: conn} do
    app = build_app!(milestones: ["m1-core", "m2-more"])

    {:ok, view, html} = live(conn, ~p"/apps/#{app.id}")

    assert html =~ "Build"
    assert html =~ "Milestone m1-core"
    assert html =~ "Milestone m2-more"

    view
    |> element("#milestone-m1-core button", "Launch")
    |> render_click()

    html = render(view)
    assert html =~ "awaiting review"
    assert html =~ "verify pass"
    assert html =~ "Review gate"

    assert [run] = Builds.list_runs(app)
    assert run.status == "completed"

    view
    |> element("#build-run-#{run.id} button", "Mark reviewed")
    |> render_click()

    html = render(view)
    refute html =~ "awaiting review"
    assert html =~ "reviewed"
  end

  test "detail page bootstraps a fresh spec repo through scaffold-from-spec", %{conn: conn} do
    app = build_app!()
    File.mkdir_p!(Path.join(app.repo_path, "spec"))
    File.write!(Path.join(app.repo_path, "spec/00-goal.md"), "# Goal")

    {:ok, view, html} = live(conn, ~p"/apps/#{app.id}")

    assert html =~ "First step: scaffold from the spec package"
    assert html =~ "Agent"
    assert has_element?(view, "#build-launch-settings select[name=\"task[agent]\"]")

    view |> element("#launch-scaffold") |> render_click()

    html = render(view)
    assert html =~ "Scaffold from spec package"
    assert html =~ "awaiting review"
    refute html =~ "First step: scaffold"

    assert [run] = Builds.list_runs(app)
    assert run.task_text == "Scaffold from spec package"
  end

  test "detail page shows repo reports", %{conn: conn} do
    app = build_app!()
    reports = Path.join(app.repo_path, "afp/reports")
    File.mkdir_p!(reports)
    File.write!(Path.join(reports, "milestone-1-report.md"), "# Milestone report body")

    {:ok, view, html} = live(conn, ~p"/apps/#{app.id}")
    assert html =~ "milestone-1-report.md"

    view
    |> element("button", "milestone-1-report.md")
    |> render_click()

    assert render(view) =~ "Milestone report body"
  end

  test "detail page reports unhealthy repos instead of launch controls", %{conn: conn} do
    app = build_app!()
    File.rm!(Path.join(app.repo_path, "AGENTS.md"))

    {:ok, _view, html} = live(conn, ~p"/apps/#{app.id}")
    assert html =~ "not launchable"
    assert html =~ "agents_missing"
  end

  defp build_app!(opts \\ []) do
    repo_path = unique_repo_path()
    File.mkdir_p!(Path.join(repo_path, "Scripts"))
    File.mkdir_p!(Path.join(repo_path, "afp"))
    File.write!(Path.join(repo_path, "AGENTS.md"), "# App Repo Agent Instructions\n")

    File.write!(
      Path.join(repo_path, "afp/manifest.json"),
      Jason.encode!(%{
        "contract" => "afp-app-repo/v1",
        "app" => %{"display_name" => "Test App", "bundle_id" => "test.app"},
        "state_db" => "afp/state.sqlite",
        "verify" => %{
          "entrypoint" => "Scripts/verify.sh",
          "report" => "afp/artifacts/verify.json"
        }
      })
    )

    db_path = Path.join(repo_path, "afp/state.sqlite")
    :ok = Afp.Factory.Builds.Storage.ensure_schema(db_path)

    for {key, index} <- Enum.with_index(opts[:milestones] || []) do
      :ok =
        RepoSqlite.execute(db_path, """
        INSERT INTO build_milestones
          (id, milestone_key, milestone_index, title, status, created_at, updated_at)
        VALUES
          (#{RepoSqlite.escape(Ecto.UUID.generate())}, #{RepoSqlite.escape(key)}, #{index},
           #{RepoSqlite.escape("Milestone #{key}")}, 'pending',
           '2026-07-04T00:00:00Z', '2026-07-04T00:00:00Z');
        """)
    end

    script = Path.join(repo_path, "Scripts/verify.sh")

    File.write!(script, """
    #!/bin/sh
    mkdir -p afp/artifacts
    cat > afp/artifacts/verify.json <<JSON
    {"pass": true, "gates": [{"id": "unit_tests", "status": "pass"}]}
    JSON
    exit 0
    """)

    File.chmod!(script, 0o755)

    app_fixture(%{"repo_path" => repo_path, "name" => "Build App #{unique_integer()}"})
  end
end
