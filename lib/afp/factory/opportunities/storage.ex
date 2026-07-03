# @input  - Configured opportunity repo maps, opportunity rows, run rows, and file metadata
# @output - Repo-local base.sqlite row DML returning typed read-model structs
# @pos    - The Storage seam: SQL and column names live here, structs cross it
defmodule Afp.Factory.Opportunities.Storage do
  alias Afp.Factory
  alias Afp.Factory.Opportunities.Opportunity
  alias Afp.Factory.Opportunities.Run
  alias Afp.Factory.Opportunities.StepEvidence
  alias Afp.Factory.Opportunities.StepResult
  alias Afp.Factory.Opportunities.StorageSchema
  alias Afp.Factory.RepoSqlite

  def list_opportunities(repo) do
    with {:ok, rows} <- sqlite_json(repo, opportunity_select_sql()) do
      {:ok, Enum.map(rows, &Opportunity.from_row/1)}
    end
  end

  def get_opportunity(repo, id) do
    with {:ok, rows} <- sqlite_json(repo, opportunity_select_sql("WHERE id = #{sql_value(id)}")) do
      case rows do
        [row | _rest] -> {:ok, Opportunity.from_row(row)}
        [] -> {:error, :opportunity_not_found}
      end
    end
  end

  def list_runs(repo, opportunity_id) do
    sqlite_json(
      repo,
      """
      SELECT #{Run.select_columns()}
      FROM opportunity_runs
      WHERE opportunity_id = #{sql_value(opportunity_id)}
      ORDER BY datetime(updated_at) DESC, rowid DESC
      """
    )
    |> case do
      {:ok, rows} -> {:ok, Enum.map(rows, &Run.from_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_step_results(repo, opportunity_id) do
    sqlite_json(
      repo,
      """
      SELECT #{StepResult.select_columns()}
      FROM opportunity_step_results
      WHERE opportunity_id = #{sql_value(opportunity_id)}
      ORDER BY step_index ASC
      """
    )
    |> case do
      {:ok, rows} -> {:ok, Enum.map(rows, &StepResult.from_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_step_evidence(repo, opportunity_id) do
    sqlite_json(
      repo,
      """
      SELECT #{StepEvidence.select_columns()}
      FROM opportunity_step_evidence
      WHERE opportunity_id = #{sql_value(opportunity_id)}
      ORDER BY datetime(created_at) ASC, file_path ASC
      """
    )
    |> case do
      {:ok, rows} -> {:ok, Enum.map(rows, &StepEvidence.from_row/1)}
      {:error, reason} -> {:error, reason}
    end
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
       %Opportunity{
         id: opportunity_id,
         title: attrs.title,
         raw_input: attrs.raw_input,
         source_url: attrs.source_url,
         agent: attrs.agent,
         status: "captured",
         stage: "created",
         created_at: now,
         updated_at: now
       }}
    end
  end

  def insert_initial_run(repo, attrs) do
    run_id = Map.fetch!(attrs, :id)
    now = Factory.now() |> DateTime.to_iso8601()
    payload = %{"model" => attrs.model}

    with :ok <-
           sqlite_exec(
             repo,
             """
             INSERT INTO opportunity_runs
               (id, opportunity_id, run_type, agent, status, stage, prompt, payload_json, created_at, updated_at)
             VALUES
               (#{sql_value(run_id)}, #{sql_value(attrs.opportunity_id)}, 'initial_research',
                #{sql_value(attrs.agent)}, 'queued', 'queued', #{sql_value(attrs.prompt)},
                #{sql_value(Jason.encode!(payload))}, #{sql_value(now)}, #{sql_value(now)});

             UPDATE opportunities
             SET current_run_id = #{sql_value(run_id)},
                 status = 'queued',
                 stage = #{sql_value(attrs.stage)},
                 updated_at = #{sql_value(now)}
             WHERE id = #{sql_value(attrs.opportunity_id)};

             #{StorageSchema.seed_step_results_sql(attrs.opportunity_id, run_id, attrs.steps, now)}
             """
           ) do
      {:ok, queued_run(run_id, attrs, "initial_research", payload, now)}
    end
  end

  def insert_build_spec_run(repo, attrs) do
    run_id = Map.fetch!(attrs, :id)
    now = Factory.now() |> DateTime.to_iso8601()
    payload = %{"model" => attrs.model}

    with :ok <-
           sqlite_exec(
             repo,
             """
             INSERT INTO opportunity_runs
               (id, opportunity_id, run_type, agent, status, stage, prompt, payload_json, created_at, updated_at)
             VALUES
               (#{sql_value(run_id)}, #{sql_value(attrs.opportunity_id)}, 'build_spec',
                #{sql_value(attrs.agent)}, 'queued', 'queued', #{sql_value(attrs.prompt)},
                #{sql_value(Jason.encode!(payload))}, #{sql_value(now)}, #{sql_value(now)});

             UPDATE opportunities
             SET current_run_id = #{sql_value(run_id)},
                 status = 'queued',
                 stage = #{sql_value(attrs.stage)},
                 updated_at = #{sql_value(now)},
                 error = NULL
             WHERE id = #{sql_value(attrs.opportunity_id)};
             """
           ) do
      {:ok, queued_run(run_id, attrs, "build_spec", payload, now)}
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

  defp queued_run(run_id, attrs, run_type, payload, now) do
    %Run{
      id: run_id,
      opportunity_id: attrs.opportunity_id,
      run_type: run_type,
      agent: attrs.agent,
      model: attrs.model,
      status: "queued",
      stage: "queued",
      prompt: attrs.prompt,
      payload: payload,
      created_at: now,
      updated_at: now
    }
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
    SELECT #{Opportunity.select_columns()}
    FROM opportunities
    #{where_clause}
    ORDER BY datetime(updated_at) DESC
    """
  end

  defp sqlite_json(repo, sql), do: RepoSqlite.query(db_path(repo), sql)
  defp sqlite_exec(repo, sql), do: RepoSqlite.execute(db_path(repo), sql)

  defp db_path(%{"repo_path" => repo_path}),
    do: Path.join(repo_path, StorageSchema.base_sqlite_path())

  defp sql_value(value), do: RepoSqlite.escape(value)
  defp now_iso, do: Factory.now() |> DateTime.to_iso8601()
end
