defmodule Afp.Factory.BuildsTest.FailingAgentClient do
  @behaviour Afp.Factory.AgentClient

  def launch_new_turn(_attrs, _opts), do: {:error, {:claude_run_failed, "simulated", %{}}}
end

defmodule Afp.Factory.BuildsTest do
  use Afp.DataCase, async: true

  alias Afp.Factory.BuildsTest.FailingAgentClient

  alias Afp.Factory.Builds
  alias Afp.Factory.Evidence
  alias Afp.Factory.Portfolio
  alias Afp.Factory.Work

  describe "inspect_app_repo/1" do
    test "reports healthy for a contract-complete repo" do
      repo_path = create_app_repo!()

      assert %{health_state: "healthy", manifest: manifest} =
               Builds.inspect_app_repo(repo_path)

      assert manifest["contract"] == "afp-app-repo/v1"
    end

    test "reports missing directory" do
      assert %{health_state: "missing"} = Builds.inspect_app_repo("/nonexistent/repo")
    end

    test "reports manifest and contract problems" do
      repo_path = create_app_repo!()

      File.rm!(Path.join(repo_path, "afp/manifest.json"))
      assert %{health_state: "manifest_missing"} = Builds.inspect_app_repo(repo_path)

      File.write!(
        Path.join(repo_path, "afp/manifest.json"),
        Jason.encode!(%{"contract" => "other/v9"})
      )

      assert %{health_state: "invalid_manifest"} = Builds.inspect_app_repo(repo_path)
    end

    test "reports missing verify entrypoint and state db tables" do
      repo_path = create_app_repo!()

      File.rm!(Path.join(repo_path, "Scripts/verify.sh"))
      assert %{health_state: "verify_missing"} = Builds.inspect_app_repo(repo_path)

      write_verify_script!(repo_path, pass: true)
      File.rm!(Path.join(repo_path, "afp/state.sqlite"))
      assert %{health_state: "state_db_missing"} = Builds.inspect_app_repo(repo_path)

      {_output, 0} =
        System.cmd("sqlite3", [
          Path.join(repo_path, "afp/state.sqlite"),
          "CREATE TABLE unrelated (id TEXT);"
        ])

      assert %{health_state: "state_db_invalid"} = Builds.inspect_app_repo(repo_path)
    end
  end

  describe "launch_packet/2" do
    test "runs the agent, verifies, ingests evidence, and routes packet to review" do
      {packet, repo_path} = create_ready_packet!()

      assert {:ok, run} = Builds.launch_packet(packet)

      run = Builds.get_build_run!(run.id)
      assert run.status == "completed"
      assert run.verify_result["pass"] == true
      assert Enum.any?(run.verify_result["gates"], &(&1["id"] == "unit_tests"))
      assert run.final_answer =~ "Fake Claude Code completed"
      assert run.agent_payload["session_id"] =~ "fake-claude-session"
      assert run.prompt =~ "AGENTS.md"
      assert run.prompt =~ packet.objective
      assert run.repository_path == repo_path

      packet = Work.get_harness_packet!(packet.id)
      assert packet.state == "review"
      assert packet.launch_mode == "supervised"
      assert packet.result_summary =~ "verify pass"

      assert %{type: "command_log", reliability: "verified"} =
               Evidence.get_evidence_packet!(run.evidence_packet_id)

      packet_links = Evidence.list_links_for_subject("harness_packet", packet.id)
      assert Enum.any?(packet_links, &(&1.evidence_packet_id == run.evidence_packet_id))

      ticket_links = Evidence.list_links_for_subject("ticket", packet.ticket_id)
      assert Enum.any?(ticket_links, &(&1.evidence_packet_id == run.evidence_packet_id))
    end

    test "records a completed run with failing verify when gates are red" do
      {packet, _repo_path} = create_ready_packet!(verify_pass: false)

      assert {:ok, run} = Builds.launch_packet(packet)

      run = Builds.get_build_run!(run.id)
      assert run.status == "completed"
      assert run.verify_result["pass"] == false

      assert %{reliability: "high"} = Evidence.get_evidence_packet!(run.evidence_packet_id)
      assert Work.get_harness_packet!(packet.id).result_summary =~ "verify fail"
    end

    test "marks the run failed when the agent launch fails" do
      {packet, _repo_path} = create_ready_packet!()

      assert {:error, {:agent_failed, _reason}} =
               Builds.launch_packet(packet, client: FailingAgentClient)

      assert [run] = Builds.list_build_runs(%{harness_packet_id: packet.id})
      assert run.status == "failed"
      assert run.error =~ "claude_run_failed"
    end

    test "refuses packets without a ready state or healthy repo" do
      {packet, repo_path} = create_ready_packet!()

      draft = %{packet | state: "draft"}
      assert {:error, :packet_not_ready} = Builds.launch_packet(draft)

      File.rm!(Path.join(repo_path, "AGENTS.md"))
      assert {:error, {:repo_unhealthy, "agents_missing", _notes}} = Builds.launch_packet(packet)
    end
  end

  defp create_ready_packet!(opts \\ []) do
    repo_path = create_app_repo!(opts)

    {:ok, app} =
      Portfolio.create_app(%{
        "name" => "Build App #{System.unique_integer([:positive])}",
        "repo_path" => repo_path
      })

    {:ok, ticket} =
      Work.create_ticket(%{"app_id" => app.id, "title" => "Implement milestone m1"})

    {:ok, packet} =
      Work.create_harness_packet_from_ticket(ticket, %{
        "expected_output" => "milestone m1 implemented, verify green",
        "review_route" => "AFP board review"
      })

    {:ok, packet} = Work.mark_harness_packet_ready(packet, %{})
    {packet, repo_path}
  end

  defp create_app_repo!(opts \\ []) do
    repo_path =
      Path.join(
        System.tmp_dir!(),
        "afp-app-repo-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(repo_path) end)

    File.mkdir_p!(Path.join(repo_path, "afp/artifacts"))
    File.mkdir_p!(Path.join(repo_path, "Scripts"))
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

    {_output, 0} =
      System.cmd("sqlite3", [
        Path.join(repo_path, "afp/state.sqlite"),
        "CREATE TABLE build_milestones (id TEXT); CREATE TABLE build_evidence (id TEXT);"
      ])

    write_verify_script!(repo_path, pass: Keyword.get(opts, :verify_pass, true))
    repo_path
  end

  defp write_verify_script!(repo_path, pass: pass) do
    {status, exit_code} = if pass, do: {"pass", 0}, else: {"fail", 1}

    script = """
    #!/bin/sh
    mkdir -p afp/artifacts
    cat > afp/artifacts/verify.json <<'JSON'
    {"contract": "afp-app-repo/v1", "pass": #{pass},
     "gates": [{"id": "build_ios", "status": "pass"},
               {"id": "unit_tests", "status": "#{status}"}]}
    JSON
    exit #{exit_code}
    """

    path = Path.join(repo_path, "Scripts/verify.sh")
    File.write!(path, script)
    File.chmod!(path, 0o755)
  end
end
