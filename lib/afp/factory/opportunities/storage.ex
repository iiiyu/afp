# @input  - Configured opportunity repo maps, opportunity rows, run rows, and file metadata
# @output - Repo-local base.sqlite reads and writes for the portable Opportunity repo
# @pos    - Internal storage interface behind the Opportunity context and agent launch modules
defmodule Afp.Factory.Opportunities.Storage do
  alias Afp.Factory
  alias Afp.Factory.Opportunities.StorageSchema
  alias Afp.Factory.RepoSqlite

  defdelegate base_sqlite_path, to: StorageSchema
  defdelegate schema_version, to: StorageSchema
  defdelegate template_version, to: StorageSchema
  defdelegate create_base(repo_path, display_name), to: StorageSchema
  defdelegate inspect_schema(db_path), to: StorageSchema
  defdelegate core_schema_present?(db_path), to: StorageSchema
  defdelegate upgrade_schema(db_path), to: StorageSchema
  defdelegate stored_template_version(db_path), to: StorageSchema
  defdelegate stored_display_name(db_path), to: StorageSchema
  defdelegate record_versions(db_path), to: StorageSchema

  def list_opportunities(repo) do
    with {:ok, rows} <- sqlite_json(repo, opportunity_select_sql()) do
      {:ok, Enum.map(rows, &normalize_opportunity_row/1)}
    end
  end

  def get_opportunity(repo, id) do
    with {:ok, rows} <- sqlite_json(repo, opportunity_select_sql("WHERE id = #{sql_value(id)}")) do
      case rows do
        [row | _rest] -> {:ok, normalize_opportunity_row(row)}
        [] -> {:error, :opportunity_not_found}
      end
    end
  end

  def list_runs(repo, opportunity_id) do
    sqlite_json(
      repo,
      """
      SELECT id, opportunity_id, run_type, agent, status, stage, prompt, codex_session_id,
             codex_thread_id, codex_turn_id, transcript_path, final_answer,
             error, started_at, completed_at, created_at, updated_at, payload_json
      FROM opportunity_runs
      WHERE opportunity_id = #{sql_value(opportunity_id)}
      ORDER BY datetime(updated_at) DESC, rowid DESC
      """
    )
    |> case do
      {:ok, rows} -> {:ok, Enum.map(rows, &normalize_run_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_step_results(repo, opportunity_id) do
    sqlite_json(
      repo,
      """
      SELECT id, opportunity_id, run_id, step_key, step_index, status, score,
             evidence_strength, summary, artifact_path, created_at, updated_at
      FROM opportunity_step_results
      WHERE opportunity_id = #{sql_value(opportunity_id)}
      ORDER BY step_index ASC
      """
    )
  end

  def list_step_evidence(repo, opportunity_id) do
    sqlite_json(
      repo,
      """
      SELECT id, opportunity_id, run_id, step_key, title, kind, file_path,
             why_it_matters, source_url, created_at, updated_at
      FROM opportunity_step_evidence
      WHERE opportunity_id = #{sql_value(opportunity_id)}
      ORDER BY datetime(created_at) ASC, file_path ASC
      """
    )
  end

  def insert_opportunity(repo, attrs) do
    now = Map.fetch!(attrs, :now)
    opportunity_id = Map.fetch!(attrs, :id)

    with :ok <-
           sqlite_exec(
             repo,
             """
             INSERT INTO opportunities
               (id, title, raw_input, source_url, agent, status, stage, created_at, updated_at)
             VALUES
               (#{sql_value(opportunity_id)}, #{sql_value(attrs.title)}, #{sql_value(attrs.raw_input)},
                #{sql_value(attrs.source_url)}, #{sql_value(attrs.agent)}, 'captured', 'created',
                #{sql_value(now)}, #{sql_value(now)});
             """
           ) do
      {:ok,
       %{
         "id" => opportunity_id,
         "title" => attrs.title,
         "raw_input" => attrs.raw_input,
         "source_url" => attrs.source_url,
         "agent" => attrs.agent,
         "status" => "captured",
         "stage" => "created",
         "created_at" => now,
         "updated_at" => now
       }}
    end
  end

  def insert_initial_run(repo, attrs) do
    run_id = Map.fetch!(attrs, :id)
    now = Factory.now() |> DateTime.to_iso8601()
    payload_json = Jason.encode!(%{"model" => attrs.model})

    with :ok <-
           sqlite_exec(
             repo,
             """
             INSERT INTO opportunity_runs
               (id, opportunity_id, run_type, agent, status, stage, prompt, payload_json, created_at, updated_at)
             VALUES
               (#{sql_value(run_id)}, #{sql_value(attrs.opportunity_id)}, 'initial_research',
                #{sql_value(attrs.agent)}, 'queued', 'queued', #{sql_value(attrs.prompt)},
                #{sql_value(payload_json)}, #{sql_value(now)}, #{sql_value(now)});

             UPDATE opportunities
             SET current_run_id = #{sql_value(run_id)},
                 status = 'queued',
                 stage = #{sql_value(attrs.stage)},
                 updated_at = #{sql_value(now)}
             WHERE id = #{sql_value(attrs.opportunity_id)};

             #{StorageSchema.seed_step_results_sql(attrs.opportunity_id, run_id, attrs.steps, now)}
             """
           ) do
      {:ok,
       %{
         "id" => run_id,
         "opportunity_id" => attrs.opportunity_id,
         "run_type" => "initial_research",
         "agent" => attrs.agent,
         "model" => attrs.model,
         "status" => "queued",
         "stage" => "queued",
         "prompt" => attrs.prompt,
         "created_at" => now,
         "updated_at" => now
       }}
    end
  end

  def insert_build_spec_run(repo, attrs) do
    run_id = Map.fetch!(attrs, :id)
    now = Factory.now() |> DateTime.to_iso8601()
    payload_json = Jason.encode!(%{"model" => attrs.model})

    with :ok <-
           sqlite_exec(
             repo,
             """
             INSERT INTO opportunity_runs
               (id, opportunity_id, run_type, agent, status, stage, prompt, payload_json, created_at, updated_at)
             VALUES
               (#{sql_value(run_id)}, #{sql_value(attrs.opportunity_id)}, 'build_spec',
                #{sql_value(attrs.agent)}, 'queued', 'queued', #{sql_value(attrs.prompt)},
                #{sql_value(payload_json)}, #{sql_value(now)}, #{sql_value(now)});

             UPDATE opportunities
             SET current_run_id = #{sql_value(run_id)},
                 status = 'queued',
                 stage = #{sql_value(attrs.stage)},
                 updated_at = #{sql_value(now)},
                 error = NULL
             WHERE id = #{sql_value(attrs.opportunity_id)};
             """
           ) do
      {:ok,
       %{
         "id" => run_id,
         "opportunity_id" => attrs.opportunity_id,
         "run_type" => "build_spec",
         "agent" => attrs.agent,
         "model" => attrs.model,
         "status" => "queued",
         "stage" => "queued",
         "prompt" => attrs.prompt,
         "created_at" => now,
         "updated_at" => now
       }}
    end
  end

  def upsert_files(repo, opportunity_id, files) do
    files
    |> Enum.map_join("\n", &file_upsert_sql(opportunity_id, &1))
    |> then(&sqlite_exec(repo, &1))
  end

  def mark_run_started(repo, attrs) do
    now = now_iso()

    sqlite_exec(
      repo,
      """
      UPDATE opportunity_runs
      SET status = 'running',
          stage = 'starting',
          started_at = COALESCE(started_at, #{sql_value(now)}),
          updated_at = #{sql_value(now)},
          error = NULL
      WHERE id = #{sql_value(attrs.run_id)};

      UPDATE opportunities
      SET status = 'running',
          stage = #{sql_value(attrs.stage)},
          current_run_id = #{sql_value(attrs.run_id)},
          updated_at = #{sql_value(now)},
          error = NULL
      WHERE id = #{sql_value(attrs.opportunity_id)};
      """
    )
  end

  def mark_thread_started(repo, attrs) do
    now = now_iso()

    sqlite_exec(
      repo,
      """
      UPDATE opportunity_runs
      SET status = 'running',
          stage = 'thread_started',
          codex_session_id = #{sql_value(attrs.session_id)},
          codex_thread_id = #{sql_value(attrs.thread_id)},
          transcript_path = #{sql_value(attrs.transcript_path)},
          updated_at = #{sql_value(now)}
      WHERE id = #{sql_value(attrs.run_id)};

      UPDATE opportunities
      SET status = 'running',
          stage = #{sql_value(attrs.stage)},
          codex_session_id = #{sql_value(attrs.session_id)},
          updated_at = #{sql_value(now)}
      WHERE id = #{sql_value(attrs.opportunity_id)};
      """
    )
  end

  def mark_turn_started(repo, attrs) do
    now = now_iso()

    sqlite_exec(
      repo,
      """
      UPDATE opportunity_runs
      SET status = 'running',
          stage = 'turn_started',
          codex_turn_id = #{sql_value(attrs.turn_id)},
          updated_at = #{sql_value(now)}
      WHERE id = #{sql_value(attrs.run_id)};

      UPDATE opportunities
      SET status = 'running',
          stage = #{sql_value(attrs.stage)},
          updated_at = #{sql_value(now)}
      WHERE id = #{sql_value(attrs.opportunity_id)};
      """
    )
  end

  def mark_run_completed(repo, attrs) do
    now = now_iso()
    opportunity_status = Map.get(attrs, :opportunity_status, "researched")

    sqlite_exec(
      repo,
      """
      UPDATE opportunity_runs
      SET status = 'completed',
          stage = 'completed',
          codex_session_id = #{sql_value(attrs.session_id)},
          codex_thread_id = #{sql_value(attrs.thread_id)},
          codex_turn_id = #{sql_value(attrs.turn_id)},
          transcript_path = #{sql_value(attrs.transcript_path)},
          final_answer = #{sql_value(attrs.final_answer)},
          completed_at = #{sql_value(now)},
          updated_at = #{sql_value(now)},
          payload_json = #{sql_value(attrs.payload_json)},
          error = NULL
      WHERE id = #{sql_value(attrs.run_id)};

      UPDATE opportunities
      SET status = #{sql_value(opportunity_status)},
          stage = #{sql_value(attrs.stage)},
          codex_session_id = #{sql_value(attrs.session_id)},
          latest_summary = #{sql_value(attrs.final_answer)},
          updated_at = #{sql_value(now)},
          error = NULL
      WHERE id = #{sql_value(attrs.opportunity_id)};
      """
    )
  end

  def mark_run_failed(repo, attrs) do
    now = now_iso()
    opportunity_status = Map.get(attrs, :opportunity_status, "failed")

    sqlite_exec(
      repo,
      """
      UPDATE opportunity_runs
      SET status = 'failed',
          stage = 'failed',
          error = #{sql_value(attrs.error_text)},
          completed_at = #{sql_value(now)},
          updated_at = #{sql_value(now)}
      WHERE id = #{sql_value(attrs.run_id)};

      UPDATE opportunities
      SET status = #{sql_value(opportunity_status)},
          stage = #{sql_value(attrs.stage)},
          error = #{sql_value(attrs.error_text)},
          updated_at = #{sql_value(now)}
      WHERE id = #{sql_value(attrs.opportunity_id)};
      """
    )
  end

  defp file_upsert_sql(opportunity_id, file) do
    now = now_iso()

    """
    INSERT INTO opportunity_files
      (id, opportunity_id, relative_path, file_type, size_bytes, mtime, created_at, updated_at)
    VALUES
      (#{sql_value(Ecto.UUID.generate())}, #{sql_value(opportunity_id)},
       #{sql_value(file.relative_path)}, #{sql_value(file.type)}, #{file.size_bytes},
       #{sql_value(file.mtime)}, #{sql_value(now)}, #{sql_value(now)})
    ON CONFLICT(opportunity_id, relative_path) DO UPDATE SET
      file_type = excluded.file_type,
      size_bytes = excluded.size_bytes,
      mtime = excluded.mtime,
      updated_at = excluded.updated_at;
    """
  end

  defp opportunity_select_sql(where_clause \\ "") do
    """
    SELECT id, title, raw_input, source_url, agent, status, stage, route, total_score,
           current_run_id, codex_session_id, latest_summary, error, created_at, updated_at
    FROM opportunities
    #{where_clause}
    ORDER BY datetime(updated_at) DESC
    """
  end

  defp normalize_opportunity_row(row), do: row
  defp normalize_run_row(row), do: row

  defp sqlite_json(repo, sql), do: RepoSqlite.query(db_path(repo), sql)
  defp sqlite_exec(repo, sql), do: RepoSqlite.execute(db_path(repo), sql)

  defp db_path(%{"repo_path" => repo_path}),
    do: Path.join(repo_path, StorageSchema.base_sqlite_path())

  defp sql_value(value), do: RepoSqlite.escape(value)
  defp now_iso, do: Factory.now() |> DateTime.to_iso8601()
end
