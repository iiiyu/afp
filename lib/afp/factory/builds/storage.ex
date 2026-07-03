# @input  - App repo state-db paths and build run/milestone attrs
# @output - Repo-local afp/state.sqlite row DML returning typed structs
# @pos    - The Builds storage seam: SQL lives here, structs cross it
defmodule Afp.Factory.Builds.Storage do
  alias Afp.Factory
  alias Afp.Factory.Builds.BuildRun
  alias Afp.Factory.Builds.Milestone
  alias Afp.Factory.RepoSqlite

  @doc """
  Idempotently creates the build tables. Called before every write path so
  retrofit repos (and repos created under older contract versions) upgrade
  in place without a manual migration.
  """
  def ensure_schema(db_path) do
    RepoSqlite.execute(db_path, """
    CREATE TABLE IF NOT EXISTS build_milestones (
      id TEXT PRIMARY KEY,
      milestone_key TEXT NOT NULL UNIQUE,
      milestone_index INTEGER NOT NULL,
      title TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending',
      spec_ref TEXT,
      summary TEXT,
      artifact_path TEXT,
      verify_json TEXT,
      attempts INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS build_evidence (
      id TEXT PRIMARY KEY,
      milestone_key TEXT NOT NULL,
      title TEXT NOT NULL,
      kind TEXT NOT NULL,
      file_path TEXT NOT NULL,
      why_it_matters TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE (milestone_key, file_path)
    );

    CREATE TABLE IF NOT EXISTS build_runs (
      id TEXT PRIMARY KEY,
      milestone_key TEXT,
      task_text TEXT,
      agent TEXT NOT NULL DEFAULT 'claude_code',
      status TEXT NOT NULL DEFAULT 'queued',
      prompt TEXT,
      agent_session_id TEXT,
      agent_thread_id TEXT,
      agent_turn_id TEXT,
      transcript_path TEXT,
      final_answer TEXT,
      verify_json TEXT NOT NULL DEFAULT '{}',
      verify_pass INTEGER,
      reviewed_at TEXT,
      error TEXT,
      started_at TEXT,
      completed_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_build_runs_status ON build_runs(status);
    """)
  end

  def list_milestones(db_path) do
    with {:ok, rows} <-
           RepoSqlite.query(
             db_path,
             "SELECT #{Milestone.select_columns()} FROM build_milestones ORDER BY milestone_index ASC"
           ) do
      {:ok, Enum.map(rows, &Milestone.from_row/1)}
    end
  end

  def get_milestone(db_path, milestone_key) do
    with {:ok, rows} <-
           RepoSqlite.query(
             db_path,
             """
             SELECT #{Milestone.select_columns()} FROM build_milestones
             WHERE milestone_key = #{sql(milestone_key)} LIMIT 1
             """
           ) do
      case rows do
        [row | _rest] -> {:ok, Milestone.from_row(row)}
        [] -> {:error, :milestone_not_found}
      end
    end
  end

  def list_runs(db_path) do
    with {:ok, rows} <-
           RepoSqlite.query(
             db_path,
             """
             SELECT #{BuildRun.select_columns()} FROM build_runs
             ORDER BY datetime(created_at) DESC, rowid DESC
             """
           ) do
      {:ok, Enum.map(rows, &BuildRun.from_row/1)}
    end
  end

  def get_run(db_path, run_id) do
    with {:ok, rows} <-
           RepoSqlite.query(
             db_path,
             "SELECT #{BuildRun.select_columns()} FROM build_runs WHERE id = #{sql(run_id)} LIMIT 1"
           ) do
      case rows do
        [row | _rest] -> {:ok, BuildRun.from_row(row)}
        [] -> {:error, :run_not_found}
      end
    end
  end

  def insert_run(db_path, attrs) do
    now = now_iso()

    with :ok <-
           RepoSqlite.execute(db_path, """
           INSERT INTO build_runs
             (id, milestone_key, task_text, agent, status, prompt, created_at, updated_at)
           VALUES
             (#{sql(attrs.id)}, #{sql(attrs[:milestone_key])}, #{sql(attrs[:task_text])},
              #{sql(attrs.agent)}, 'queued', #{sql(attrs.prompt)}, #{sql(now)}, #{sql(now)});
           """) do
      get_run(db_path, attrs.id)
    end
  end

  def mark_run_started(db_path, run_id) do
    exec_update(db_path, run_id, """
    status = 'running',
    started_at = COALESCE(started_at, #{sql(now_iso())}),
    error = NULL
    """)
  end

  def mark_run_session(db_path, run_id, %{} = payload) do
    exec_update(db_path, run_id, """
    agent_session_id = #{sql(payload.session_id)},
    agent_thread_id = #{sql(payload.thread_id)},
    transcript_path = #{sql(payload.transcript_path)}
    """)
  end

  def mark_run_turn(db_path, run_id, turn_id) do
    exec_update(db_path, run_id, "agent_turn_id = #{sql(turn_id)}")
  end

  def mark_run_verifying(db_path, run_id, result) do
    exec_update(db_path, run_id, """
    status = 'verifying',
    agent_session_id = #{sql(result.session_id)},
    agent_thread_id = #{sql(result.thread_id)},
    agent_turn_id = #{sql(result.turn_id)},
    transcript_path = #{sql(result.transcript_path)},
    final_answer = #{sql(result.final_answer)}
    """)
  end

  def mark_run_completed(db_path, run_id, verify_json, verify_pass) do
    exec_update(db_path, run_id, """
    status = 'completed',
    verify_json = #{sql(verify_json)},
    verify_pass = #{if verify_pass, do: 1, else: 0},
    completed_at = #{sql(now_iso())}
    """)
  end

  def mark_run_failed(db_path, run_id, error_text) do
    exec_update(db_path, run_id, """
    status = 'failed',
    error = #{sql(error_text)},
    completed_at = #{sql(now_iso())}
    """)
  end

  def mark_run_reviewed(db_path, run_id) do
    exec_update(db_path, run_id, "reviewed_at = #{sql(now_iso())}")
  end

  def set_milestone_in_progress(db_path, milestone_key) do
    RepoSqlite.execute(db_path, """
    UPDATE build_milestones
    SET status = 'in_progress', updated_at = #{sql(now_iso())}
    WHERE milestone_key = #{sql(milestone_key)};
    """)
  end

  @doc "Resets a lying `in_progress` milestone back to `pending` (run died)."
  def reset_milestone_pending(db_path, milestone_key) when is_binary(milestone_key) do
    RepoSqlite.execute(db_path, """
    UPDATE build_milestones
    SET status = 'pending', updated_at = #{sql(now_iso())}
    WHERE milestone_key = #{sql(milestone_key)} AND status = 'in_progress';
    """)
  end

  def reset_milestone_pending(_db_path, _milestone_key), do: :ok

  defp exec_update(db_path, run_id, set_clause) do
    RepoSqlite.execute(db_path, """
    UPDATE build_runs
    SET #{set_clause}, updated_at = #{sql(now_iso())}
    WHERE id = #{sql(run_id)};
    """)
  end

  defp sql(value), do: RepoSqlite.escape(value)
  defp now_iso, do: Factory.now() |> DateTime.to_iso8601()
end
