# @input  - Factory contexts and temporary local filesystem paths
# @output - Focused test fixtures for app-factory domain records
# @pos    - Test helper module for context, controller, and LiveView coverage
defmodule Afp.FactoryFixtures do
  alias Afp.Factory.Demand
  alias Afp.Factory.Evidence
  alias Afp.Factory.Portfolio
  alias Afp.Factory.Releases
  alias Afp.Factory.Work

  def unique_integer, do: System.unique_integer([:positive])

  def unique_repo_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "afp-test-repo-#{System.os_time(:microsecond)}-#{unique_integer()}"
      )

    File.mkdir_p!(path)
    path
  end

  def temp_git_repo_fixture(files \\ %{}) do
    path = unique_repo_path()
    {_output, 0} = System.cmd("git", ["init"], cd: path, stderr_to_stdout: true)
    {_output, 0} = System.cmd("git", ["config", "user.email", "afp@example.test"], cd: path)
    {_output, 0} = System.cmd("git", ["config", "user.name", "AFP Test"], cd: path)

    files
    |> Enum.each(fn {file, content} ->
      full_path = Path.join(path, file)
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, content)
    end)

    {_output, 0} = System.cmd("git", ["add", "."], cd: path, stderr_to_stdout: true)
    {_output, 0} = System.cmd("git", ["commit", "-m", "Initial test commit"], cd: path)
    path
  end

  def demand_source_repo_fixture(attrs \\ %{}) do
    path = Map.get(attrs, "repo_path") || Map.get(attrs, :repo_path) || demand_repo_fixture()

    attrs =
      Map.merge(%{"repo_path" => path}, Map.delete(Map.delete(attrs, "repo_path"), :repo_path))

    {:ok, source_repo} = Demand.create_source_repo(attrs)
    source_repo
  end

  def demand_repo_fixture(files \\ %{}) do
    default_files = %{
      "AGENTS.md" => "# Demand Repo\n",
      "demand.sqlite3" => "",
      "sqlite/schema.sql" => "-- schema\n",
      "runs/.keep" => "",
      "candidates/.keep" => "",
      "evidence/.keep" => "",
      "reports/.keep" => "",
      "packages/.keep" => "",
      "afp-demand-source.json" => """
      {
        "schema_version": 2,
        "kind": "product_demand_repo",
        "display_name": "Product Demand",
        "description": "Unified demand research for apps and games.",
        "lanes": ["app", "game"],
        "agent_contract": {
          "entrypoint": "AGENTS.md",
          "required": true,
          "skill_policy": "repo_agents_first",
          "required_skills": [],
          "optional_skills": []
        },
        "read_order": ["AGENTS.md", "README.md", "sqlite/schema.sql"],
        "write_targets": {
          "runs": "runs",
          "candidates": "candidates",
          "evidence": "evidence",
          "reports": "reports",
          "packages": "packages"
        },
        "sqlite": {
          "path": "demand.sqlite3",
          "mode": "required",
          "owner": "repo",
          "schema_path": "sqlite/schema.sql",
          "migrations_path": "sqlite/migrations",
          "allowed_operations": ["read_index", "upsert_candidate"]
        }
      }
      """
    }

    files =
      Enum.reduce(files, default_files, fn
        {path, nil}, acc -> Map.delete(acc, path)
        {path, content}, acc -> Map.put(acc, path, content)
      end)

    temp_git_repo_fixture(files)
  end

  def sqlite_demand_repo_fixture(rows \\ [], files \\ %{}) do
    files = Map.put_new(files, "demand.sqlite3", nil)
    path = demand_repo_fixture(files)
    db_path = Path.join(path, "demand.sqlite3")
    rows = if rows == [], do: [default_sqlite_candidate_row()], else: rows

    sql = """
    CREATE TABLE candidates (
      id TEXT PRIMARY KEY,
      lane TEXT,
      title TEXT NOT NULL,
      status TEXT,
      score INTEGER,
      confidence TEXT,
      target_user TEXT,
      demand_signal TEXT,
      incumbent_weakness TEXT,
      wedge_hypothesis TEXT,
      validation_action TEXT,
      primary_path TEXT,
      current_report_path TEXT,
      package_path TEXT,
      evidence_paths TEXT,
      observed_at TEXT,
      limitations TEXT
    );
    #{Enum.map_join(rows, "\n", &sqlite_insert_candidate_sql/1)}
    """

    {_output, 0} = System.cmd("sqlite3", [db_path, sql], stderr_to_stdout: true)
    path
  end

  defp default_sqlite_candidate_row do
    %{
      "id" => "sqlite-candidate-#{unique_integer()}",
      "lane" => "app",
      "title" => "SQLite Candidate #{unique_integer()}",
      "status" => "validation_ready",
      "score" => 86,
      "confidence" => "medium-high",
      "target_user" => "solo developer",
      "demand_signal" => "SQLite source signal",
      "incumbent_weakness" => "Incumbents miss the narrow workflow",
      "wedge_hypothesis" => "Local-first indexed candidate can win",
      "validation_action" => "Run five validation interviews",
      "primary_path" => "candidates/app/sqlite-candidate.md",
      "current_report_path" => "reports/app/sqlite-candidate-report.md",
      "package_path" => "packages/app/sqlite-candidate",
      "evidence_paths" => "evidence/app/source.md",
      "observed_at" => "2026-06-06",
      "limitations" => "Imported from fixture SQLite"
    }
  end

  defp sqlite_insert_candidate_sql(row) do
    columns = [
      "id",
      "lane",
      "title",
      "status",
      "score",
      "confidence",
      "target_user",
      "demand_signal",
      "incumbent_weakness",
      "wedge_hypothesis",
      "validation_action",
      "primary_path",
      "current_report_path",
      "package_path",
      "evidence_paths",
      "observed_at",
      "limitations"
    ]

    values =
      columns
      |> Enum.map(&Map.get(row, &1))
      |> Enum.map(&sqlite_value/1)
      |> Enum.join(", ")

    "INSERT INTO candidates (#{Enum.join(columns, ", ")}) VALUES (#{values});"
  end

  defp sqlite_value(nil), do: "NULL"
  defp sqlite_value(value) when is_integer(value), do: Integer.to_string(value)
  defp sqlite_value(value), do: "'#{value |> to_string() |> String.replace("'", "''")}'"

  def demand_candidate_fixture(source_repo \\ nil, attrs \\ %{}) do
    source_repo = source_repo || demand_source_repo_fixture()

    defaults = %{
      "lane" => "app",
      "external_id" => "candidate-#{unique_integer()}",
      "title" => "Demand Candidate #{unique_integer()}",
      "source_status" => "validation-ready",
      "afp_status" => "pickup_recommended",
      "score" => 82,
      "confidence" => "medium",
      "target_user" => "solo app developer",
      "demand_signal" => "Repeated source evidence",
      "incumbent_weakness" => "Existing tools are heavyweight",
      "wedge_hypothesis" => "A narrow app-factory workflow can win",
      "validation_action" => "Run a validation sprint",
      "primary_path" => "candidates/app/candidate.md",
      "report_path" => "reports/app/candidate-report.md",
      "evidence_paths" => "evidence/app/source.md"
    }

    {:ok, candidate} = Demand.index_candidate(source_repo, Map.merge(defaults, attrs))
    candidate
  end

  def message_template_fixture(attrs \\ %{}) do
    defaults = %{
      "name" => "Manual URL Analysis #{unique_integer()}",
      "purpose" => "Research a demand candidate",
      "default_run_type" => "manual_url",
      "default_lane" => "app",
      "default_target" => "manual_handoff",
      "required_variables" => "repo_path\ncandidate_title",
      "body" => "Follow {{agent_entrypoint}} in {{repo_path}} and research {{candidate_title}}."
    }

    {:ok, template} = Demand.create_message_template(Map.merge(defaults, attrs))
    template
  end

  def app_fixture(attrs \\ %{}) do
    defaults = %{
      "name" => "Test App #{unique_integer()}",
      "repo_path" => unique_repo_path(),
      "platforms" => "ios, web",
      "lifecycle_stage" => "build_ready",
      "business_posture" => "unknown",
      "next_action" => "Prepare next release"
    }

    {:ok, app} = Portfolio.create_app(Map.merge(defaults, attrs))
    app
  end

  def demand_item_fixture(attrs \\ %{}) do
    defaults = %{
      "title" => "Demand #{unique_integer()}",
      "source" => "manual",
      "target_user" => "solo app developer",
      "demand_signal" => "Repeated user complaint",
      "incumbent_weakness" => "Existing tools are too heavy",
      "wedge_hypothesis" => "A narrow local-first workflow can win",
      "validation_action" => "Collect three concrete examples",
      "confidence" => "medium"
    }

    {:ok, demand_item} = Demand.create_demand_item(Map.merge(defaults, attrs))
    demand_item
  end

  def ticket_fixture(app, attrs \\ %{}) do
    defaults = %{
      "app_id" => app.id,
      "title" => "Ticket #{unique_integer()}",
      "status" => "ready",
      "risk_level" => "normal"
    }

    {:ok, ticket} = Work.create_ticket(Map.merge(defaults, attrs))
    ticket
  end

  def release_fixture(app, attrs \\ %{}) do
    defaults = %{
      "app_id" => app.id,
      "platform" => "ios",
      "version" => "1.0.#{unique_integer()}"
    }

    {:ok, release} = Releases.create_release_target(Map.merge(defaults, attrs))
    Releases.get_release_target!(release.id)
  end

  def evidence_fixture(app, attrs \\ %{}) do
    defaults = %{
      "app_id" => app.id,
      "type" => "manual",
      "summary" => "Evidence summary #{unique_integer()}",
      "reliability" => "verified"
    }

    {:ok, evidence} = Evidence.create_evidence_packet(Map.merge(defaults, attrs))
    evidence
  end
end
