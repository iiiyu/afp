# @input  - Approval profiles and request params, no transport
# @output - Table-driven verdict assertions for the safety-critical decisions
# @pos    - Direct tests of the Approvals interface (the seam is the test surface)
defmodule Afp.Factory.AgentClient.ApprovalsTest do
  use ExUnit.Case, async: true

  alias Afp.Factory.AgentClient.Approvals
  alias Afp.Factory.AgentClient.CommandPolicy

  defp profile(overrides \\ %{}) do
    Approvals.profile(
      Map.merge(
        %{
          cwd: "/repo",
          source_repo_root: "/repo",
          write_targets: %{"opportunities" => "opportunities", "skills" => ".skills"},
          sqlite_path: "base.sqlite",
          sqlite_allowed_operations: ["upsert_opportunity", "upsert_step_result"],
          network_access: true
        },
        overrides
      )
    )
  end

  describe "decide_command/2" do
    test "declines cwd outside the source repo" do
      assert {"decline", reason} =
               Approvals.decide_command(profile(), %{"cwd" => "/elsewhere", "command" => "ls"})

      assert reason =~ "outside the source repo"
    end

    test "accepts network approvals when network access is enabled" do
      params = %{"cwd" => "/repo", "networkApprovalContext" => %{"host" => "apps.apple.com"}}
      assert {"accept", _reason} = Approvals.decide_command(profile(), params)
    end

    test "declines network approvals when network access is disabled" do
      params = %{"cwd" => "/repo", "networkApprovalContext" => %{"host" => "apps.apple.com"}}

      assert {"decline", _reason} =
               Approvals.decide_command(profile(%{network_access: false}), params)
    end

    test "declines destructive commands even with an rtk prefix" do
      for command <- [
            "rm -rf opportunities",
            "sudo ls",
            "git push origin main",
            "git reset --hard",
            "chmod +x script.sh",
            "rtk rm -rf opportunities"
          ] do
        assert {"decline", reason} =
                 Approvals.decide_command(profile(), %{"cwd" => "/repo", "command" => command}),
               "expected decline for #{command}"

        assert reason =~ "destructive", "expected destructive reason for #{command}"
      end
    end

    test "declines command actions outside the source repo" do
      params = %{
        "cwd" => "/repo",
        "command" => "cat /etc/passwd",
        "commandActions" => [%{"type" => "read", "path" => "/etc/passwd"}]
      }

      assert {"decline", reason} = Approvals.decide_command(profile(), params)
      assert reason =~ "outside the source repo"
    end

    test "accepts read-only command actions inside the repo" do
      params = %{
        "cwd" => "/repo",
        "command" => "custom-tool scan",
        "commandActions" => [%{"type" => "read", "path" => "/repo/opportunities/a.md"}]
      }

      assert {"accept", _reason} = Approvals.decide_command(profile(), params)
    end

    test "accepts sqlite writes only against the declared db with allowed operations" do
      params = %{"cwd" => "/repo", "command" => "sqlite3 base.sqlite \"INSERT INTO ...\""}
      assert {"accept", reason} = Approvals.decide_command(profile(), params)
      assert reason =~ "SQLite"

      assert {"decline", _reason} =
               Approvals.decide_command(
                 profile(%{sqlite_allowed_operations: []}),
                 params
               )

      other_db = %{"cwd" => "/repo", "command" => "sqlite3 other.sqlite \"INSERT ...\""}
      assert {"decline", _reason} = Approvals.decide_command(profile(), other_db)
    end

    test "accepts recognized safe reads and declines everything unrecognized" do
      for command <- ["ls -la", "rg pattern", "git status", "git diff", "rtk cat README.md"] do
        assert {"accept", _reason} =
                 Approvals.decide_command(profile(), %{"cwd" => "/repo", "command" => command}),
               "expected accept for #{command}"
      end

      for command <- ["cat foo > bar", "make build", "python script.py"] do
        assert {"decline", _reason} =
                 Approvals.decide_command(profile(), %{"cwd" => "/repo", "command" => command}),
               "expected decline for #{command}"
      end
    end
  end

  describe "decide_file_change/2" do
    test "accepts empty grant roots, in-bounds roots, and the sqlite path" do
      assert {"accept", _} = Approvals.decide_file_change(profile(), %{})

      assert {"accept", _} =
               Approvals.decide_file_change(profile(), %{
                 "grantRoot" => "/repo/opportunities/abc"
               })

      assert {"accept", _} =
               Approvals.decide_file_change(profile(), %{"grantRoot" => "/repo/base.sqlite"})
    end

    test "declines grant roots outside the write targets" do
      assert {"decline", reason} =
               Approvals.decide_file_change(profile(), %{"grantRoot" => "/repo/lib"})

      assert reason =~ "outside"
    end
  end

  describe "decide_permissions/2" do
    test "grants network only when enabled" do
      request = %{"permissions" => %{"network" => %{"enabled" => true}}}

      assert {%{"network" => %{"enabled" => true}}, _reason} =
               Approvals.decide_permissions(profile(), request)

      assert {%{}, reason} =
               Approvals.decide_permissions(profile(%{network_access: false}), request)

      assert reason =~ "disabled"
    end
  end

  describe "CommandPolicy renderings" do
    test "claude deny rules derive from the destructive vocabulary" do
      deny = CommandPolicy.claude_deny_rules()
      assert "Bash(rm *)" in deny
      assert "Bash(sudo *)" in deny
      assert "Bash(git push *)" in deny
      assert "Bash(git reset *)" in deny
    end

    test "claude allow rules include safe reads plus per-launch extras" do
      allow = CommandPolicy.claude_allow_rules(["xcodebuild *"])
      assert "Bash(cat *)" in allow
      assert "Bash(sqlite3 *)" in allow
      assert "Bash(xcodebuild *)" in allow
    end

    test "both transports agree on what is destructive" do
      for command <- ["rm -rf x", "sudo reboot", "git push", "chmod 777 f", "osascript evil"] do
        assert CommandPolicy.destructive?(command), "expected destructive: #{command}"
      end

      refute CommandPolicy.destructive?("git status")
      refute CommandPolicy.destructive?("ls -la")
    end
  end
end
