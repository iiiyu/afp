# @input  - Temporary git repositories, app fixtures, and Phase 2 context params
# @output - Assertions for repo scans, handoffs, growth reviews, and maintenance queues
# @pos    - Context tests for the dogfood operating loop
defmodule Afp.Factory.Phase2OperatingLoopTest do
  use Afp.DataCase, async: true

  import Afp.FactoryFixtures

  alias Afp.Factory.Growth
  alias Afp.Factory.Maintenance
  alias Afp.Factory.Portfolio
  alias Afp.Factory.Repositories
  alias Afp.Factory.Work

  test "repository scan uses a temporary project and updates app health when dirty" do
    repo_path = temp_git_repo_fixture(%{"mix.exs" => "defmodule Temp.MixProject do\nend\n"})
    app = app_fixture(%{"repo_path" => repo_path, "platforms" => "phoenix"})

    File.write!(Path.join(repo_path, "README.md"), "# Temporary AFP dogfood project\n")

    assert {:ok, scan} = Repositories.scan_app(app, "test_temp_project_scan")
    assert scan.repository_path == repo_path
    assert scan.status == "dirty"
    assert scan.changed_count == 0
    assert scan.untracked_count == 1
    assert "phoenix" in scan.platform_hints
    assert Portfolio.get_app!(app.id).health_state == "repo_dirty"
  end

  test "repository root scan discovers temporary git projects without touching existing apps" do
    root = unique_repo_path()
    repo_path = Path.join(root, "TempCodexProject")
    File.mkdir_p!(repo_path)
    {_output, 0} = System.cmd("git", ["init"], cd: repo_path, stderr_to_stdout: true)

    assert {:ok, result} =
             Repositories.scan_repository_roots([%{"path" => root}], reason: "test_root_scan")

    assert result.scanned == 1
    assert [%{repository_path: ^repo_path, status: "healthy"}] = result.scans
  end

  test "harness handoff text preserves execution boundaries" do
    app = app_fixture()
    ticket = ticket_fixture(app)

    {:ok, packet} =
      Work.create_harness_packet_from_ticket(ticket, %{
        "expected_output" => "A verified patch",
        "review_route" => "Return to AFP review",
        "required_evidence" => "mix test\nruntime screenshot"
      })

    handoff = Work.handoff_text(packet)

    assert handoff =~ "Harness Packet"
    assert handoff =~ app.repo_path
    assert handoff =~ "Do not mark related AFP tickets done automatically"
  end

  test "growth and maintenance due queues feed operating attention" do
    app = app_fixture(%{"lifecycle_stage" => "live", "business_posture" => "grow"})

    {:ok, experiment} =
      Growth.create_experiment(%{
        "app_id" => app.id,
        "title" => "Test paywall copy",
        "status" => "running",
        "metric" => "trial starts",
        "review_due_on" => Date.utc_today()
      })

    {:ok, obligation} =
      Maintenance.create_obligation(%{
        "app_id" => app.id,
        "title" => "Review privacy labels",
        "category" => "privacy",
        "due_on" => Date.utc_today()
      })

    assert Enum.any?(Growth.list_review_due_experiments(), &(&1.id == experiment.id))
    assert Enum.any?(Maintenance.list_due_obligations(), &(&1.id == obligation.id))
  end
end
