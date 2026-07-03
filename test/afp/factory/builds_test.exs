# @input  - Fixture app repos under the afp-app-repo/v1 contract and fake agents
# @output - Assertions for the build launch loop, gates, verify, and recovery
# @pos    - Context tests for the execution layer (docs/build-runner-v2-design.md)
defmodule Afp.Factory.BuildsTest.FailingAgentClient do
  @behaviour Afp.Factory.AgentClient

  alias Afp.Factory.AgentClient.Error

  def launch_new_turn(_request, _opts),
    do: {:error, %Error{reason: :agent_run_failed, detail: "simulated"}}
end

defmodule Afp.Factory.BuildsTest do
  use Afp.DataCase, async: true

  import Afp.FactoryFixtures

  alias Afp.Factory.Builds
  alias Afp.Factory.Builds.BuildRun
  alias Afp.Factory.BuildsTest.FailingAgentClient
  alias Afp.Factory.RepoSqlite

  describe "inspect_app_repo/1" do
    test "healthy contract repo" do
      app = build_app!()
      assert %{health_state: "healthy"} = Builds.inspect_app_repo(app.repo_path)
    end

    test "unhealthy states" do
      app = build_app!()
      File.rm!(Path.join(app.repo_path, "AGENTS.md"))
      assert %{health_state: "agents_missing"} = Builds.inspect_app_repo(app.repo_path)

      assert %{health_state: "missing"} =
               Builds.inspect_app_repo("/nonexistent/#{unique_integer()}")
    end
  end

  describe "launch_milestone/3" do
    test "runs the agent, verifies with the pinned simulator, records everything" do
      app = build_app!(milestones: ["m1-core"], simulator: "iPhone Test Device")

      assert {:ok, run} = Builds.launch_milestone(app, "m1-core")

      assert run.status == "completed"
      assert run.verify_pass == true
      assert run.milestone_key == "m1-core"
      assert run.agent_session_id =~ "fake-session-"
      assert run.final_answer =~ "Fake agent completed"
      assert Enum.any?(run.verify["gates"], &(&1["id"] == "unit_tests"))
      assert run.verify["simulator_seen"] == "iPhone Test Device"

      assert [milestone] = Builds.list_milestones(app)
      assert milestone.status == "in_progress"
      assert run.prompt =~ "MILESTONE_KEY: m1-core"
      assert run.prompt =~ ".skills/implement-milestone"
    end

    test "refuses milestones that are not launchable" do
      app = build_app!(milestones: ["m1-core"])
      seed_milestone_status(app, "m1-core", "completed")

      assert {:error, {:milestone_not_launchable, "completed"}} =
               Builds.launch_milestone(app, "m1-core")

      assert {:error, :milestone_not_found} = Builds.launch_milestone(app, "nope")
    end

    test "hard review gate: a completed unreviewed run blocks the next launch" do
      app = build_app!(milestones: ["m1-core", "m2-more"])

      assert {:ok, first} = Builds.launch_milestone(app, "m1-core")
      assert BuildRun.awaiting_review?(first)

      assert {:error, {:unreviewed_run, blocked_id}} = Builds.launch_milestone(app, "m2-more")
      assert blocked_id == first.id
      assert {:unreviewed_run, _run} = Builds.launch_blocked(app)

      assert {:ok, reviewed} = Builds.mark_run_reviewed(app, first.id)
      assert reviewed.reviewed_at

      assert {:ok, second} = Builds.launch_milestone(app, "m2-more")
      assert second.status == "completed"
    end

    test "per-app serial: an active run blocks the next launch" do
      app = build_app!(milestones: ["m1-core"])
      seed_active_run(app, "running")

      assert {:error, {:active_run, _id}} = Builds.launch_milestone(app, "m1-core")
    end

    test "agent failure marks the run failed and resets the milestone to pending" do
      app = build_app!(milestones: ["m1-core"])

      assert {:error, {:build_run_failed, run_id}} =
               Builds.launch_milestone(app, "m1-core", client: FailingAgentClient)

      assert [run] = Builds.list_runs(app)
      assert run.id == run_id
      assert run.status == "failed"
      assert run.error =~ "agent_run_failed"

      assert [milestone] = Builds.list_milestones(app)
      assert milestone.status == "pending"
    end

    test "retries the verify chain once on an infrastructure false-red" do
      app = build_app!(milestones: ["m1-core"], verify_variant: :infra_false_red_once)

      assert {:ok, run} = Builds.launch_milestone(app, "m1-core")
      assert run.verify_pass == true
      assert run.verify["retried_infra_false_red"] == true
    end
  end

  describe "launch_task/3" do
    test "ad-hoc task run with the retrofit prompt" do
      app = build_app!()

      assert {:ok, run} = Builds.launch_task(app, "Fix the settings crash")
      assert run.status == "completed"
      assert run.milestone_key == nil
      assert run.task_text == "Fix the settings crash"
      assert run.prompt =~ "only oracle"
      assert run.prompt =~ "exactly one turn"
    end

    test "requires task text" do
      app = build_app!()
      assert {:error, :task_text_required} = Builds.launch_task(app, "   ")
    end
  end

  describe "recovery" do
    test "reconcile_stale_runs fails sessionless runs past the grace window" do
      app = build_app!()
      seed_active_run(app, "running", updated_at: iso_minutes_ago(30))

      :ok = Builds.reconcile_stale_runs(app)

      assert [run] = Builds.list_runs(app)
      assert run.status == "failed"
      assert run.error =~ "stale"
    end

    test "reconcile_stale_runs leaves fresh runs alone" do
      app = build_app!()
      seed_active_run(app, "running")

      :ok = Builds.reconcile_stale_runs(app)
      assert [run] = Builds.list_runs(app)
      assert run.status == "running"
    end

    test "force_fail_run fails an active run" do
      app = build_app!()
      run_id = seed_active_run(app, "verifying")

      assert {:ok, run} = Builds.force_fail_run(app, run_id)
      assert run.status == "failed"
      assert run.error =~ "force-failed"
    end
  end

  describe "report files" do
    test "lists and reads only safe markdown names" do
      app = build_app!()
      reports = Path.join(app.repo_path, "afp/reports")
      File.mkdir_p!(reports)
      File.write!(Path.join(reports, "milestone-1-report.md"), "# Report")

      assert Builds.list_report_files(app) == ["milestone-1-report.md"]
      assert {:ok, "# Report"} = Builds.read_report_file(app, "milestone-1-report.md")
      assert {:error, :invalid_report_name} = Builds.read_report_file(app, "../secrets.md")
      assert {:error, :invalid_report_name} = Builds.read_report_file(app, "verify.sh")
    end
  end

  defp build_app!(opts \\ []) do
    repo_path = build_repo!(opts)
    app_fixture(%{"repo_path" => repo_path, "name" => "Build App #{unique_integer()}"})
  end

  defp build_repo!(opts) do
    repo_path = unique_repo_path()
    File.mkdir_p!(Path.join(repo_path, "Scripts"))
    File.mkdir_p!(Path.join(repo_path, "afp"))
    File.write!(Path.join(repo_path, "AGENTS.md"), "# App Repo Agent Instructions\n")

    manifest = %{
      "contract" => "afp-app-repo/v1",
      "app" => %{"display_name" => "Test App", "bundle_id" => "test.app"},
      "state_db" => "afp/state.sqlite",
      "verify" =>
        %{"entrypoint" => "Scripts/verify.sh", "report" => "afp/artifacts/verify.json"}
        |> maybe_put("simulator", opts[:simulator])
    }

    File.write!(Path.join(repo_path, "afp/manifest.json"), Jason.encode!(manifest))

    db_path = Path.join(repo_path, "afp/state.sqlite")
    :ok = Afp.Factory.Builds.Storage.ensure_schema(db_path)

    for {key, index} <- Enum.with_index(opts[:milestones] || []) do
      # Milestone rows are agent-written in production; tests seed them the
      # same way the agent contract does — SQL against the state db.
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

    write_verify_script!(repo_path, opts[:verify_variant] || :pass)
    repo_path
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp write_verify_script!(repo_path, :pass) do
    write_script!(repo_path, """
    #!/bin/sh
    mkdir -p afp/artifacts
    cat > afp/artifacts/verify.json <<JSON
    {"contract": "afp-app-repo/v1", "pass": true, "simulator_seen": "${VERIFY_SIM:-}",
     "gates": [{"id": "build_ios", "status": "pass"}, {"id": "unit_tests", "status": "pass"}]}
    JSON
    exit 0
    """)
  end

  defp write_verify_script!(repo_path, :infra_false_red_once) do
    write_script!(repo_path, """
    #!/bin/sh
    mkdir -p afp/artifacts/logs
    if [ ! -f afp/artifacts/.attempted ]; then
      touch afp/artifacts/.attempted
      echo "Failed to install or launch the test runner" > afp/artifacts/logs/unit_tests.log
      cat > afp/artifacts/verify.json <<JSON
    {"pass": false,
     "gates": [{"id": "unit_tests", "status": "fail", "log": "afp/artifacts/logs/unit_tests.log"}]}
    JSON
      exit 1
    fi
    cat > afp/artifacts/verify.json <<JSON
    {"pass": true, "gates": [{"id": "unit_tests", "status": "pass"}]}
    JSON
    exit 0
    """)
  end

  defp write_script!(repo_path, content) do
    path = Path.join(repo_path, "Scripts/verify.sh")
    File.write!(path, content)
    File.chmod!(path, 0o755)
  end

  defp seed_milestone_status(app, key, status) do
    :ok =
      RepoSqlite.execute(db_path(app), """
      UPDATE build_milestones SET status = #{RepoSqlite.escape(status)}
      WHERE milestone_key = #{RepoSqlite.escape(key)};
      """)
  end

  defp seed_active_run(app, status, opts \\ []) do
    run_id = Ecto.UUID.generate()
    updated_at = Keyword.get(opts, :updated_at, DateTime.to_iso8601(DateTime.utc_now()))

    :ok =
      RepoSqlite.execute(db_path(app), """
      INSERT INTO build_runs (id, agent, status, prompt, created_at, updated_at)
      VALUES (#{RepoSqlite.escape(run_id)}, 'claude_code', #{RepoSqlite.escape(status)},
              'seeded', #{RepoSqlite.escape(updated_at)}, #{RepoSqlite.escape(updated_at)});
      """)

    run_id
  end

  defp db_path(app), do: Path.join(app.repo_path, "afp/state.sqlite")

  defp iso_minutes_ago(minutes) do
    DateTime.utc_now()
    |> DateTime.add(-minutes * 60, :second)
    |> DateTime.to_iso8601()
  end
end
