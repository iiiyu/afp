# @input  - Opportunity repo paths, repo-local SQLite, and template metadata
# @output - Schema creation, inspection, and upgrade helpers for base.sqlite
# @pos    - Internal schema implementation behind the Opportunity repo storage module
defmodule Afp.Factory.Opportunities.StorageSchema do
  alias Afp.Factory
  alias Afp.Factory.RepoSqlite

  @base_sqlite_path "base.sqlite"
  @schema_version 4
  @template_version 5
  @core_tables ~w(repo_metadata opportunities opportunity_runs opportunity_files)
  @required_tables @core_tables ++ ["opportunity_step_results", "opportunity_step_evidence"]
  @agent_tables ~w(opportunities opportunity_runs)

  def base_sqlite_path, do: @base_sqlite_path
  def schema_version, do: @schema_version
  def template_version, do: @template_version

  def create_base(repo_path, display_name) do
    db_path = Path.join(repo_path, @base_sqlite_path)

    case System.cmd("sqlite3", [db_path, base_sqlite_schema(display_name)],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, {:sqlite_schema_failed, String.trim(output)}}
    end
  rescue
    error in ErlangError ->
      case error.original do
        :enoent -> {:error, :sqlite3_unavailable}
        _other -> {:error, {:sqlite_schema_failed, Exception.message(error)}}
      end
  end

  def inspect_schema(db_path) do
    with {:ok, rows} <-
           RepoSqlite.query(
             db_path,
             "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
           ),
         table_names <- Enum.map(rows, &Map.get(&1, "name")),
         missing <- Enum.reject(@required_tables, &(&1 in table_names)),
         :ok <- ensure_no_missing_tables(missing),
         {:ok, version_rows} <-
           RepoSqlite.query(
             db_path,
             "SELECT value FROM repo_metadata WHERE key = 'schema_version' LIMIT 1"
           ) do
      schema_version =
        version_rows
        |> List.first()
        |> case do
          %{"value" => value} -> value
          _row -> Integer.to_string(@schema_version)
        end

      {:ok, %{"schema_version" => schema_version}}
    end
  end

  def core_schema_present?(db_path) do
    with {:ok, rows} <-
           RepoSqlite.query(db_path, "SELECT name FROM sqlite_master WHERE type = 'table'") do
      table_names = Enum.map(rows, &Map.get(&1, "name"))
      {:ok, Enum.all?(@core_tables, &(&1 in table_names))}
    end
  end

  def upgrade_schema(db_path) do
    with :ok <- ensure_agent_columns(db_path),
         :ok <- RepoSqlite.execute(db_path, step_results_table_sql()),
         :ok <- RepoSqlite.execute(db_path, step_evidence_table_sql()) do
      :ok
    end
  end

  def stored_template_version(db_path) do
    with {:ok, rows} <-
           RepoSqlite.query(
             db_path,
             "SELECT value FROM repo_metadata WHERE key = 'template_version' LIMIT 1"
           ) do
      case rows do
        [%{"value" => value} | _rest] -> {:ok, parse_version(value)}
        [] -> {:ok, 0}
      end
    end
  end

  def stored_display_name(db_path) do
    case RepoSqlite.query(
           db_path,
           "SELECT value FROM repo_metadata WHERE key = 'display_name' LIMIT 1"
         ) do
      {:ok, [%{"value" => value} | _rest]} -> Factory.trim_nil(value)
      _missing -> nil
    end
  end

  def record_versions(db_path), do: RepoSqlite.execute(db_path, metadata_versions_sql())

  def seed_step_results_sql(opportunity_id, run_id, steps, now) do
    Enum.map_join(steps, "\n", fn step ->
      """
      INSERT INTO opportunity_step_results
        (id, opportunity_id, run_id, step_key, step_index, status, artifact_path,
         payload_json, created_at, updated_at)
      VALUES
        (#{sql_value(Ecto.UUID.generate())}, #{sql_value(opportunity_id)}, #{sql_value(run_id)},
         #{sql_value(step.key)}, #{step.index}, 'pending', #{sql_value(step.artifact)},
         '{}', #{sql_value(now)}, #{sql_value(now)})
      ON CONFLICT(opportunity_id, step_key) DO UPDATE SET
        run_id = excluded.run_id,
        status = 'pending',
        updated_at = excluded.updated_at;
      """
    end)
  end

  defp ensure_no_missing_tables([]), do: :ok
  defp ensure_no_missing_tables(missing), do: {:error, {:missing_tables, missing}}

  defp ensure_agent_columns(db_path) do
    column_sql =
      Enum.map_join(@agent_tables, "\nUNION ALL\n", fn table ->
        "SELECT '#{table}' AS table_name, name FROM pragma_table_info('#{table}')"
      end)

    with {:ok, rows} <- RepoSqlite.query(db_path, column_sql) do
      @agent_tables
      |> Enum.reject(fn table ->
        Enum.any?(rows, &(&1["table_name"] == table and &1["name"] == "agent"))
      end)
      |> Enum.map_join("\n", &"ALTER TABLE #{&1} ADD COLUMN agent TEXT NOT NULL DEFAULT 'codex';")
      |> then(&RepoSqlite.execute(db_path, &1))
    end
  end

  defp metadata_versions_sql do
    now = now_iso()

    """
    INSERT INTO repo_metadata (key, value, updated_at)
    VALUES
      ('schema_version', '#{@schema_version}', #{sql_value(now)}),
      ('template_version', '#{@template_version}', #{sql_value(now)})
    ON CONFLICT(key) DO UPDATE SET
      value = excluded.value,
      updated_at = excluded.updated_at;
    """
  end

  defp base_sqlite_schema(display_name) do
    now = now_iso()

    """
    PRAGMA foreign_keys = ON;
    PRAGMA user_version = #{@schema_version};

    CREATE TABLE IF NOT EXISTS repo_metadata (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    INSERT INTO repo_metadata (key, value, updated_at)
    VALUES
      ('schema_version', '#{@schema_version}', #{sql_value(now)}),
      ('template_version', '#{@template_version}', #{sql_value(now)}),
      ('display_name', #{sql_value(display_name)}, #{sql_value(now)})
    ON CONFLICT(key) DO UPDATE SET
      value = excluded.value,
      updated_at = excluded.updated_at;

    CREATE TABLE IF NOT EXISTS opportunities (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      raw_input TEXT NOT NULL,
      source_url TEXT,
      agent TEXT NOT NULL DEFAULT 'codex',
      status TEXT NOT NULL DEFAULT 'captured',
      stage TEXT NOT NULL DEFAULT 'created',
      route TEXT,
      total_score INTEGER,
      current_run_id TEXT,
      codex_session_id TEXT,
      latest_summary TEXT,
      error TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS opportunity_runs (
      id TEXT PRIMARY KEY,
      opportunity_id TEXT NOT NULL,
      run_type TEXT NOT NULL DEFAULT 'initial_research',
      agent TEXT NOT NULL DEFAULT 'codex',
      status TEXT NOT NULL DEFAULT 'queued',
      stage TEXT NOT NULL DEFAULT 'queued',
      prompt TEXT NOT NULL,
      codex_session_id TEXT,
      codex_thread_id TEXT,
      codex_turn_id TEXT,
      transcript_path TEXT,
      final_answer TEXT,
      error TEXT,
      started_at TEXT,
      completed_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      payload_json TEXT NOT NULL DEFAULT '{}',
      FOREIGN KEY(opportunity_id) REFERENCES opportunities(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS opportunity_files (
      id TEXT PRIMARY KEY,
      opportunity_id TEXT NOT NULL,
      relative_path TEXT NOT NULL,
      file_type TEXT NOT NULL,
      size_bytes INTEGER,
      mtime TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE(opportunity_id, relative_path),
      FOREIGN KEY(opportunity_id) REFERENCES opportunities(id) ON DELETE CASCADE
    );

    #{step_results_table_sql()}

    #{step_evidence_table_sql()}

    CREATE INDEX IF NOT EXISTS idx_opportunities_status ON opportunities(status);
    CREATE INDEX IF NOT EXISTS idx_opportunities_updated_at ON opportunities(updated_at);
    CREATE INDEX IF NOT EXISTS idx_opportunity_runs_opportunity ON opportunity_runs(opportunity_id);
    CREATE INDEX IF NOT EXISTS idx_opportunity_runs_status ON opportunity_runs(status);
    CREATE INDEX IF NOT EXISTS idx_opportunity_files_opportunity ON opportunity_files(opportunity_id);
    """
  end

  defp step_results_table_sql do
    """
    CREATE TABLE IF NOT EXISTS opportunity_step_results (
      id TEXT PRIMARY KEY,
      opportunity_id TEXT NOT NULL,
      run_id TEXT,
      step_key TEXT NOT NULL,
      step_index INTEGER NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending',
      score INTEGER,
      evidence_strength TEXT,
      summary TEXT,
      artifact_path TEXT,
      payload_json TEXT NOT NULL DEFAULT '{}',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE(opportunity_id, step_key),
      FOREIGN KEY(opportunity_id) REFERENCES opportunities(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_opportunity_step_results_opportunity
      ON opportunity_step_results(opportunity_id);
    """
  end

  defp step_evidence_table_sql do
    """
    CREATE TABLE IF NOT EXISTS opportunity_step_evidence (
      id TEXT PRIMARY KEY,
      opportunity_id TEXT NOT NULL,
      run_id TEXT,
      step_key TEXT NOT NULL,
      title TEXT NOT NULL,
      kind TEXT NOT NULL DEFAULT 'analysis',
      file_path TEXT NOT NULL,
      why_it_matters TEXT,
      source_url TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE(opportunity_id, file_path),
      FOREIGN KEY(opportunity_id) REFERENCES opportunities(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_opportunity_step_evidence_opportunity
      ON opportunity_step_evidence(opportunity_id);
    """
  end

  defp parse_version(value) do
    case Integer.parse(to_string(value)) do
      {version, _rest} -> version
      :error -> 0
    end
  end

  defp sql_value(value), do: RepoSqlite.escape(value)

  defp now_iso, do: Factory.now() |> DateTime.to_iso8601()
end
