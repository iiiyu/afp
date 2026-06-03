# @input  - Portfolio context fixtures and local repository paths
# @output - Assertions for app inventory validation and cwd matching
# @pos    - Context tests for app lifecycle inventory behavior
defmodule Afp.Factory.PortfolioTest do
  use Afp.DataCase, async: true

  import Afp.FactoryFixtures

  alias Afp.Factory.Portfolio

  test "create_app saves invalid repository paths with warning health" do
    {:ok, app} =
      Portfolio.create_app(%{
        "name" => "Missing Repo",
        "repo_path" => "/definitely/missing/#{unique_integer()}",
        "lifecycle_stage" => "build_ready",
        "next_action" => "Fix repo path"
      })

    assert app.health_state == "repo_missing"
  end

  test "active apps without next action are marked and listed" do
    {:ok, app} =
      Portfolio.create_app(%{
        "name" => "Needs Action",
        "repo_path" => unique_repo_path(),
        "lifecycle_stage" => "build_ready"
      })

    assert app.health_state == "needs_next_action"
    assert Enum.any?(Portfolio.apps_without_next_action(), &(&1.id == app.id))
  end

  test "duplicate repository paths are rejected" do
    repo_path = unique_repo_path()
    _app = app_fixture(%{"repo_path" => repo_path})

    assert {:error, changeset} =
             Portfolio.create_app(%{
               "name" => "Duplicate Repo",
               "repo_path" => repo_path,
               "lifecycle_stage" => "build_ready"
             })

    assert %{repo_path: ["has already been taken"]} = errors_on(changeset)
  end

  test "match_app_by_cwd selects the app whose repo contains cwd" do
    app = app_fixture()
    cwd = Path.join(app.repo_path, "nested")
    File.mkdir_p!(cwd)

    assert Portfolio.match_app_by_cwd(cwd).id == app.id
  end
end
