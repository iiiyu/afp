# @input  - Operator opportunity prompts, configured repo paths, repo-local SQLite, and agent launch progress
# @output - Opportunity repo scaffolding, health inspection, opportunity records, file previews, and Codex/Claude Code launch state
# @pos    - Context boundary for the portable opportunities repository workflow
defmodule Afp.Factory.Opportunities do
  require Logger

  alias Afp.Factory
  alias Afp.Factory.Events
  alias Afp.Factory.Opportunities.AgentRun
  alias Afp.Factory.Opportunities.Files
  alias Afp.Factory.RepoSqlite
  alias Afp.Factory.Settings

  @setting_key "opportunity_repo"
  @base_sqlite_path "base.sqlite"
  @agents_path "AGENTS.md"
  @skills_path ".skills"
  @opportunities_path "opportunities"
  @steps_path "steps"
  @schema_version 4
  @template_version 5
  @core_tables ~w(repo_metadata opportunities opportunity_runs opportunity_files)
  @required_tables @core_tables ++ ["opportunity_step_results", "opportunity_step_evidence"]
  @agent_tables ~w(opportunities opportunity_runs)
  @agents ~w(claude_code codex)
  @default_agent "claude_code"

  # Curated per-agent model pickers for the launch form (verified 2026-06);
  # free-text custom values and the CLI-default empty value stay supported.
  @codex_models ~w(gpt-5.5 gpt-5.4 gpt-5.4-mini gpt-5.3-codex gpt-5.2-codex)
  @claude_code_models ~w(claude-fable-5 claude-opus-4-8 claude-sonnet-4-6 claude-haiku-4-5)

  @research_steps [
    %{
      key: "competitor_discovery",
      index: 0,
      title: "Competitor Discovery",
      artifact: "steps/00-competitor-discovery.md",
      max_score: nil
    },
    %{
      key: "demand_proof",
      index: 1,
      title: "Demand Proof",
      artifact: "steps/01-demand-proof.md",
      max_score: 20
    },
    %{
      key: "pain_strength",
      index: 2,
      title: "Pain Strength",
      artifact: "steps/02-pain-strength.md",
      max_score: 20
    },
    %{
      key: "incumbent_weakness",
      index: 3,
      title: "Incumbent Weakness",
      artifact: "steps/03-incumbent-weakness.md",
      max_score: 20
    },
    %{
      key: "wedge_clarity",
      index: 4,
      title: "Wedge Clarity",
      artifact: "steps/04-wedge-clarity.md",
      max_score: 20
    },
    %{
      key: "build_distribution_feasibility",
      index: 5,
      title: "Build & Distribution Feasibility",
      artifact: "steps/05-build-distribution-feasibility.md",
      max_score: 20
    },
    %{
      key: "score_aggregator",
      index: 6,
      title: "Score Aggregator",
      artifact: "steps/06-score-aggregator.md",
      max_score: 100
    }
  ]

  # {priv template path, repo-relative destination}; all AFP-owned and
  # overwritten in place when the repo template version is outdated.
  @template_files [
    {"AGENTS.md", "AGENTS.md"},
    {"CLAUDE.md", "CLAUDE.md"},
    {"README.md", "README.md"},
    {"gitignore", ".gitignore"},
    {".skills/README.md", ".skills/README.md"},
    {".skills/opportunity-research/SKILL.md", ".skills/opportunity-research/SKILL.md"},
    {".skills/competitor-discovery/SKILL.md", ".skills/competitor-discovery/SKILL.md"},
    {".skills/demand-proof/SKILL.md", ".skills/demand-proof/SKILL.md"},
    {".skills/pain-strength/SKILL.md", ".skills/pain-strength/SKILL.md"},
    {".skills/incumbent-weakness/SKILL.md", ".skills/incumbent-weakness/SKILL.md"},
    {".skills/wedge-clarity/SKILL.md", ".skills/wedge-clarity/SKILL.md"},
    {".skills/build-distribution-feasibility/SKILL.md",
     ".skills/build-distribution-feasibility/SKILL.md"},
    {".skills/score-aggregator/SKILL.md", ".skills/score-aggregator/SKILL.md"}
  ]

  def configured_repo do
    @setting_key
    |> Settings.get_setting(%{})
    |> configured_repo_from_setting()
  end

  def configure_repo(attrs) when is_map(attrs) do
    repo_path = attrs |> attr_value("repo_path") |> normalize_repo_path()
    display_name = Factory.trim_nil(attr_value(attrs, "display_name")) || display_name(repo_path)

    config =
      %{
        "repo_path" => repo_path,
        "display_name" => display_name
      }
      |> Map.merge(repo_health(repo_path))

    with {:ok, _setting} <- Settings.put_setting(@setting_key, config) do
      Events.record_event("opportunity_repo", nil, "opportunity_repo_configured", %{
        repo_path: repo_path,
        health_state: config["health_state"]
      })

      {:ok, config}
    end
  end

  def configure_repo(_attrs), do: {:error, :repo_path_required}

  def create_repo_from_template(attrs) when is_map(attrs) do
    with {:ok, repo_path} <- target_repo_path(attrs),
         :ok <- ensure_target_available(repo_path),
         :ok <- ensure_executable("sqlite3", :sqlite3_unavailable),
         :ok <- ensure_executable("git", :git_unavailable),
         display_name <-
           Factory.trim_nil(attr_value(attrs, "display_name")) || display_name(repo_path),
         :ok <- write_repo_files(repo_path, display_name),
         :ok <- create_base_sqlite(repo_path, display_name),
         :ok <- init_git(repo_path) do
      configure_repo(%{"repo_path" => repo_path, "display_name" => display_name})
    end
  end

  def create_repo_from_template(_attrs), do: {:error, :repo_path_required}

  def refresh_configured_repo do
    case configured_repo() do
      nil -> {:error, :repo_path_required}
      repo -> configure_repo(repo)
    end
  end

  def healthy_repo? do
    case configured_repo() do
      %{"health_state" => "healthy"} -> true
      _repo -> false
    end
  end

  def list_opportunities do
    with {:ok, repo} <- healthy_repo(),
         {:ok, rows} <- sqlite_json(repo, opportunity_select_sql()) do
      Enum.map(rows, &normalize_opportunity_row/1)
    end
  end

  def get_opportunity(id) do
    with {:ok, repo} <- healthy_repo(),
         {:ok, rows} <- sqlite_json(repo, opportunity_select_sql("WHERE id = #{sql_value(id)}")) do
      case rows do
        [row | _rest] -> {:ok, normalize_opportunity_row(row)}
        [] -> {:error, :opportunity_not_found}
      end
    end
  end

  def list_runs(opportunity_id) do
    with {:ok, repo} <- healthy_repo(),
         {:ok, rows} <-
           sqlite_json(
             repo,
             """
             SELECT id, opportunity_id, run_type, agent, status, stage, codex_session_id,
                    codex_thread_id, codex_turn_id, transcript_path, final_answer,
                    error, started_at, completed_at, created_at, updated_at, payload_json
             FROM opportunity_runs
             WHERE opportunity_id = #{sql_value(opportunity_id)}
             ORDER BY datetime(updated_at) DESC
             """
           ) do
      Enum.map(rows, &normalize_run_row/1)
    end
  end

  def create_opportunity_with_codex(attrs, opts \\ [])

  def create_opportunity_with_codex(attrs, opts) when is_map(attrs),
    do: create_opportunity(Map.put(attrs, "agent", "codex"), opts)

  def create_opportunity_with_codex(_attrs, _opts), do: {:error, :raw_input_required}

  def create_opportunity(attrs, opts \\ [])

  def create_opportunity(attrs, opts) when is_map(attrs) do
    with {:ok, repo} <- healthy_repo(),
         {:ok, raw_input} <- raw_input(attrs),
         {:ok, agent} <- launch_agent(attrs),
         model <- launch_model(attrs),
         {:ok, opportunity} <- create_opportunity_record(repo, raw_input, agent),
         {:ok, run} <- create_opportunity_run(repo, opportunity, raw_input, agent, model) do
      case AgentRun.start_agent_run(repo, opportunity, run, opts) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def create_opportunity(_attrs, _opts), do: {:error, :raw_input_required}

  @doc """
  Re-run an existing opportunity's research after a failed (or completed) run.

  Reuses the stored `raw_input` and `agent`, carrying forward the most recent
  run's model override. Creates a fresh run rather than mutating the old one,
  so prior attempts stay in the run history.
  """
  def relaunch_opportunity(opportunity_id, opts \\ []) do
    with {:ok, repo} <- healthy_repo(),
         {:ok, opportunity} <- get_opportunity(opportunity_id),
         {:ok, raw_input} <- raw_input(opportunity) do
      agent = opportunity["agent"] || @default_agent
      model = latest_run_model(opportunity_id)

      with {:ok, run} <- create_opportunity_run(repo, opportunity, raw_input, agent, model) do
        case AgentRun.start_agent_run(repo, opportunity, run, opts) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  # Most recent run's model override, so a re-run keeps the operator's choice.
  defp latest_run_model(opportunity_id) do
    opportunity_id
    |> list_runs()
    |> case do
      [latest | _] -> run_model(latest)
      _ -> nil
    end
  end

  defp run_model(%{"payload_json" => json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"model" => model}} when is_binary(model) and model != "" -> model
      _ -> nil
    end
  end

  defp run_model(_run), do: nil

  def supported_agents, do: @agents

  def agent_label("claude_code"), do: "Claude Code"
  def agent_label(_agent), do: "Codex"

  def known_models("claude_code"), do: @claude_code_models
  def known_models(_agent), do: @codex_models

  def research_steps, do: @research_steps

  def step_title(step_key) do
    case Enum.find(@research_steps, &(&1.key == step_key)) do
      %{title: title} -> title
      nil -> Factory.labelize(step_key)
    end
  end

  def list_step_results(opportunity_id) do
    with {:ok, repo} <- healthy_repo(),
         {:ok, rows} <-
           sqlite_json(
             repo,
             """
             SELECT id, opportunity_id, run_id, step_key, step_index, status, score,
                    evidence_strength, summary, artifact_path, created_at, updated_at
             FROM opportunity_step_results
             WHERE opportunity_id = #{sql_value(opportunity_id)}
             ORDER BY step_index ASC
             """
           ) do
      rows
    end
  end

  def list_step_evidence(opportunity_id) do
    with {:ok, repo} <- healthy_repo(),
         {:ok, rows} <-
           sqlite_json(
             repo,
             """
             SELECT id, opportunity_id, run_id, step_key, title, kind, file_path,
                    why_it_matters, source_url, created_at, updated_at
             FROM opportunity_step_evidence
             WHERE opportunity_id = #{sql_value(opportunity_id)}
             ORDER BY datetime(created_at) ASC, file_path ASC
             """
           ) do
      rows
    end
  end

  def list_opportunity_files(opportunity_id) do
    with {:ok, repo} <- healthy_repo() do
      Files.list(repo, opportunity_id)
    end
  end

  def read_opportunity_file(opportunity_id, relative_path) do
    with {:ok, repo} <- healthy_repo() do
      Files.read(repo, opportunity_id, relative_path)
    end
  end

  def repo_root(%{"repo_path" => repo_path}), do: repo_path
  def repo_root(_repo), do: nil

  def opportunity_relative_root(opportunity_id) do
    Path.join([@opportunities_path, opportunity_id])
  end

  def steps_path, do: @steps_path
  def base_sqlite_path, do: @base_sqlite_path

  defp configured_repo_from_setting(%{"repo_path" => repo_path} = setting)
       when is_binary(repo_path) and repo_path != "" do
    setting
    |> Map.merge(repo_health(repo_path))
    |> Map.put_new("display_name", display_name(repo_path))
  end

  defp configured_repo_from_setting(_setting), do: nil

  defp healthy_repo do
    case configured_repo() do
      %{"health_state" => "healthy"} = repo -> {:ok, repo}
      nil -> {:error, :repo_path_required}
      repo -> {:error, {:repo_unhealthy, repo["health_state"]}}
    end
  end

  defp repo_health(nil) do
    %{
      "health_state" => "missing",
      "health_summary" => "Opportunity repo path is required.",
      "missing_paths" => [],
      "parse_errors" => [],
      "latest_scan_at" => now_iso()
    }
  end

  defp repo_health(repo_path) do
    cond do
      Factory.blank?(repo_path) ->
        repo_health(nil)

      not File.dir?(repo_path) ->
        %{
          "health_state" => "missing",
          "health_summary" => "Opportunity repo path does not exist.",
          "missing_paths" => [repo_path],
          "parse_errors" => [],
          "latest_scan_at" => now_iso()
        }

      true ->
        inspect_existing_repo(repo_path)
    end
  end

  defp inspect_existing_repo(repo_path) do
    :ok = maybe_upgrade_repo(repo_path)

    required_paths = [
      @base_sqlite_path,
      @opportunities_path,
      @agents_path,
      @skills_path
    ]

    missing_paths =
      required_paths
      |> Enum.reject(&required_path_present?(repo_path, &1))
      |> Enum.map(&Path.join(repo_path, &1))

    parse_errors =
      []
      |> maybe_add_agents_typo(repo_path)
      |> maybe_add_git_warning(repo_path)

    sqlite_health =
      if Enum.any?(missing_paths, &String.ends_with?(&1, @base_sqlite_path)) do
        {:error, :sqlite_missing}
      else
        inspect_sqlite_schema(Path.join(repo_path, @base_sqlite_path))
      end

    cond do
      Enum.any?(missing_paths, &String.ends_with?(&1, @agents_path)) ->
        health(
          "agents_missing",
          "Opportunity repo is missing AGENTS.md.",
          missing_paths,
          parse_errors
        )

      sqlite_health == {:error, :sqlite_missing} ->
        health(
          "sqlite_missing",
          "Opportunity repo is missing base.sqlite.",
          missing_paths,
          parse_errors
        )

      missing_paths != [] ->
        health(
          "invalid_structure",
          "Opportunity repo does not match the required base.sqlite/opportunities/AGENTS.md/.skills structure.",
          missing_paths,
          parse_errors
        )

      match?({:error, _reason}, sqlite_health) ->
        {_tag, reason} = sqlite_health

        health(
          "sqlite_invalid",
          "base.sqlite exists but does not expose the required opportunity tables.",
          missing_paths,
          [inspect(reason) | parse_errors]
        )

      true ->
        {:ok, sqlite_info} = sqlite_health

        health(
          "healthy",
          "Opportunity repo is ready. base.sqlite schema v#{sqlite_info["schema_version"] || @schema_version} is available.",
          [],
          parse_errors,
          sqlite_info
        )
    end
  end

  defp health(state, summary, missing_paths, parse_errors, extra \\ %{}) do
    %{
      "health_state" => state,
      "health_summary" => summary,
      "missing_paths" => missing_paths,
      "parse_errors" => Enum.reverse(parse_errors),
      "latest_scan_at" => now_iso()
    }
    |> Map.merge(extra)
  end

  defp required_path_present?(repo_path, @base_sqlite_path),
    do: File.regular?(Path.join(repo_path, @base_sqlite_path))

  defp required_path_present?(repo_path, @agents_path),
    do: File.regular?(Path.join(repo_path, @agents_path))

  defp required_path_present?(repo_path, relative_path),
    do: File.dir?(Path.join(repo_path, relative_path))

  defp maybe_add_agents_typo(errors, repo_path) do
    if File.regular?(Path.join(repo_path, "AGENETS.md")) and
         not File.regular?(Path.join(repo_path, @agents_path)) do
      ["Found AGENETS.md; Codex expects AGENTS.md." | errors]
    else
      errors
    end
  end

  defp maybe_add_git_warning(errors, repo_path) do
    if File.dir?(Path.join(repo_path, ".git")) do
      errors
    else
      [
        "Git metadata not found. The structure can still be used, but new scaffolds are initialized as git repos."
        | errors
      ]
    end
  end

  defp inspect_sqlite_schema(db_path) do
    with {:ok, rows} <-
           sqlite_json_path(
             db_path,
             "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
           ),
         table_names <- Enum.map(rows, &Map.get(&1, "name")),
         missing <- Enum.reject(@required_tables, &(&1 in table_names)),
         :ok <- ensure_no_missing_tables(missing),
         {:ok, version_rows} <-
           sqlite_json_path(
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

  defp ensure_no_missing_tables([]), do: :ok
  defp ensure_no_missing_tables(missing), do: {:error, {:missing_tables, missing}}

  # Non-destructive, fully automatic in-place upgrade for repos whose
  # base.sqlite already holds the core tables: adds the v2 `agent` columns,
  # creates the v3 `opportunity_step_results` table, and overwrites all
  # AFP-owned template files when the recorded template version is outdated.
  defp maybe_upgrade_repo(repo_path) do
    db_path = Path.join(repo_path, @base_sqlite_path)

    with true <- File.regular?(db_path),
         {:ok, rows} <-
           sqlite_json_path(db_path, "SELECT name FROM sqlite_master WHERE type = 'table'"),
         table_names <- Enum.map(rows, &Map.get(&1, "name")),
         true <- Enum.all?(@core_tables, &(&1 in table_names)) do
      upgrade_repo(repo_path, db_path)
    else
      _precondition_failed -> :ok
    end
  end

  defp upgrade_repo(repo_path, db_path) do
    with :ok <- ensure_agent_columns(db_path),
         :ok <- sqlite_exec_path(db_path, step_results_table_sql()),
         :ok <- sqlite_exec_path(db_path, step_evidence_table_sql()),
         :ok <- ensure_template_files(repo_path, db_path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Opportunity repo upgrade failed",
          repo_path: repo_path,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp ensure_agent_columns(db_path) do
    column_sql =
      Enum.map_join(@agent_tables, "\nUNION ALL\n", fn table ->
        "SELECT '#{table}' AS table_name, name FROM pragma_table_info('#{table}')"
      end)

    with {:ok, rows} <- sqlite_json_path(db_path, column_sql) do
      @agent_tables
      |> Enum.reject(fn table ->
        Enum.any?(rows, &(&1["table_name"] == table and &1["name"] == "agent"))
      end)
      |> Enum.map_join("\n", &"ALTER TABLE #{&1} ADD COLUMN agent TEXT NOT NULL DEFAULT 'codex';")
      |> then(&sqlite_exec_path(db_path, &1))
    end
  end

  defp ensure_template_files(repo_path, db_path) do
    case stored_template_version(db_path) do
      {:ok, version} when version >= @template_version ->
        :ok

      {:ok, _outdated} ->
        display_name = stored_display_name(db_path) || display_name(repo_path)

        with :ok <- write_template_files(repo_path, display_name) do
          sqlite_exec_path(db_path, metadata_versions_sql())
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stored_template_version(db_path) do
    with {:ok, rows} <-
           sqlite_json_path(
             db_path,
             "SELECT value FROM repo_metadata WHERE key = 'template_version' LIMIT 1"
           ) do
      case rows do
        [%{"value" => value} | _rest] -> {:ok, parse_version(value)}
        [] -> {:ok, 0}
      end
    end
  end

  defp parse_version(value) do
    case Integer.parse(to_string(value)) do
      {version, _rest} -> version
      :error -> 0
    end
  end

  defp stored_display_name(db_path) do
    case sqlite_json_path(
           db_path,
           "SELECT value FROM repo_metadata WHERE key = 'display_name' LIMIT 1"
         ) do
      {:ok, [%{"value" => value} | _rest]} -> Factory.trim_nil(value)
      _missing -> nil
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

  defp target_repo_path(attrs) do
    case attrs |> attr_value("repo_path") |> Factory.trim_nil() do
      nil -> {:error, :repo_path_required}
      path -> {:ok, Factory.expand_path(path)}
    end
  end

  defp normalize_repo_path(nil), do: nil
  defp normalize_repo_path(path) when is_binary(path), do: Factory.expand_path(path)
  defp normalize_repo_path(path), do: path

  defp ensure_target_available(repo_path) do
    cond do
      File.exists?(repo_path) and not File.dir?(repo_path) ->
        {:error, :target_path_not_directory}

      File.dir?(repo_path) ->
        case File.ls(repo_path) do
          {:ok, []} -> :ok
          {:ok, _entries} -> {:error, :target_not_empty}
          {:error, reason} -> {:error, {:target_unreadable, reason}}
        end

      true ->
        :ok
    end
  end

  defp ensure_executable(command, error) do
    if System.find_executable(command), do: :ok, else: {:error, error}
  end

  defp write_repo_files(repo_path, display_name) do
    with :ok <- mkdir(repo_path),
         :ok <- mkdir(Path.join(repo_path, @opportunities_path)) do
      write_template_files(repo_path, display_name)
    end
  end

  defp write_template_files(repo_path, display_name) do
    Enum.reduce_while(@template_files, :ok, fn {source, destination}, :ok ->
      content =
        template_root()
        |> Path.join(source)
        |> File.read!()
        |> String.replace("{{DISPLAY_NAME}}", display_name)

      full_path = Path.join(repo_path, destination)

      with :ok <- mkdir(Path.dirname(full_path)),
           :ok <- File.write(full_path, content) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:write_failed, destination, reason}}}
      end
    end)
  end

  defp template_root do
    Path.join(Application.app_dir(:afp, "priv"), "opportunity_repo_template")
  end

  defp mkdir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, path, reason}}
    end
  end

  defp create_base_sqlite(repo_path, display_name) do
    db_path = Path.join(repo_path, @base_sqlite_path)
    sql = base_sqlite_schema(display_name)

    case System.cmd("sqlite3", [db_path, sql], stderr_to_stdout: true) do
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

  defp init_git(repo_path) do
    case System.cmd("git", ["init"], cd: repo_path, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, {:git_init_failed, String.trim(output)}}
    end
  rescue
    error in ErlangError ->
      case error.original do
        :enoent -> {:error, :git_unavailable}
        _other -> {:error, {:git_init_failed, Exception.message(error)}}
      end
  end

  defp create_opportunity_record(repo, raw_input, agent) do
    opportunity_id = Ecto.UUID.generate()
    title = title_from_input(raw_input)
    source_url = first_url(raw_input)
    now = now_iso()

    with :ok <- write_opportunity_files(repo, opportunity_id, title, raw_input),
         :ok <-
           sqlite_exec(
             repo,
             """
             INSERT INTO opportunities
               (id, title, raw_input, source_url, agent, status, stage, created_at, updated_at)
             VALUES
               (#{sql_value(opportunity_id)}, #{sql_value(title)}, #{sql_value(raw_input)},
                #{sql_value(source_url)}, #{sql_value(agent)}, 'captured', 'created',
                #{sql_value(now)}, #{sql_value(now)});
             """
           ),
         :ok <- Files.refresh_index(repo, opportunity_id) do
      opportunity = %{
        "id" => opportunity_id,
        "title" => title,
        "raw_input" => raw_input,
        "source_url" => source_url,
        "agent" => agent,
        "status" => "captured",
        "stage" => "created",
        "created_at" => now,
        "updated_at" => now
      }

      Events.record_event("opportunity", opportunity_id, "opportunity_created", %{
        title: title,
        agent: agent,
        repo_path: repo["repo_path"]
      })

      {:ok, opportunity}
    end
  end

  defp write_opportunity_files(repo, opportunity_id, title, raw_input) do
    root = Path.join([repo["repo_path"], @opportunities_path, opportunity_id])

    with :ok <- mkdir(root),
         :ok <- mkdir(Path.join(root, @steps_path)),
         :ok <- File.write(Path.join(root, "README.md"), opportunity_readme(title, raw_input)) do
      :ok
    else
      {:error, reason} ->
        {:error, {:write_failed, opportunity_relative_root(opportunity_id), reason}}
    end
  end

  defp create_opportunity_run(repo, opportunity, raw_input, agent, model) do
    run_id = Ecto.UUID.generate()
    now = now_iso()
    prompt = agent_prompt(repo, opportunity, run_id, raw_input)
    payload_json = Jason.encode!(%{"model" => model})

    with :ok <-
           sqlite_exec(
             repo,
             """
             INSERT INTO opportunity_runs
               (id, opportunity_id, run_type, agent, status, stage, prompt, payload_json, created_at, updated_at)
             VALUES
               (#{sql_value(run_id)}, #{sql_value(opportunity["id"])}, 'initial_research',
                #{sql_value(agent)}, 'queued', 'queued', #{sql_value(prompt)},
                #{sql_value(payload_json)}, #{sql_value(now)}, #{sql_value(now)});

             UPDATE opportunities
             SET current_run_id = #{sql_value(run_id)},
                 status = 'queued',
                 stage = '#{agent_label(agent)} launch queued',
                 updated_at = #{sql_value(now)}
             WHERE id = #{sql_value(opportunity["id"])};

             #{seed_step_results_sql(opportunity["id"], run_id, now)}
             """
           ) do
      run = %{
        "id" => run_id,
        "opportunity_id" => opportunity["id"],
        "run_type" => "initial_research",
        "agent" => agent,
        "model" => model,
        "status" => "queued",
        "stage" => "queued",
        "prompt" => prompt,
        "created_at" => now,
        "updated_at" => now
      }

      Events.record_event("opportunity_run", run_id, "opportunity_run_queued", %{
        opportunity_id: opportunity["id"],
        agent: agent,
        model: model
      })

      {:ok, run}
    end
  end

  # Pre-seeds one pending row per pipeline step so the UI shows the full
  # checklist immediately; the agent upserts each row as steps complete.
  defp seed_step_results_sql(opportunity_id, run_id, now) do
    Enum.map_join(@research_steps, "\n", fn step ->
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

  defp sqlite_json(repo, sql) do
    repo["repo_path"]
    |> Path.join(@base_sqlite_path)
    |> RepoSqlite.query(sql)
  end

  defp sqlite_json_path(db_path, sql), do: RepoSqlite.query(db_path, sql)

  defp sqlite_exec(repo, sql) do
    repo["repo_path"]
    |> Path.join(@base_sqlite_path)
    |> RepoSqlite.execute(sql)
  end

  defp sqlite_exec_path(db_path, sql), do: RepoSqlite.execute(db_path, sql)

  defp raw_input(attrs) do
    case attrs |> attr_value("raw_input") |> Factory.trim_nil() do
      nil -> {:error, :raw_input_required}
      raw_input -> {:ok, raw_input}
    end
  end

  defp launch_agent(attrs) do
    case attrs |> attr_value("agent") |> Factory.trim_nil() do
      nil -> {:ok, @default_agent}
      agent when agent in @agents -> {:ok, agent}
      agent -> {:error, {:unsupported_agent, agent}}
    end
  end

  # Optional model override; nil means the agent CLI's configured default.
  defp launch_model(attrs) do
    attrs |> attr_value("model") |> Factory.trim_nil()
  end

  defp title_from_input(raw_input) do
    raw_input
    |> String.split("\n", trim: true)
    |> List.first()
    |> Kernel.||("Untitled opportunity")
    |> String.replace(~r/https?:\/\/\S+/, "")
    |> String.trim()
    |> case do
      "" -> first_url(raw_input) || "Untitled opportunity"
      title -> title
    end
    |> String.slice(0, 96)
  end

  defp first_url(raw_input) do
    Regex.run(~r/https?:\/\/[^\s]+/, raw_input)
    |> case do
      [url | _rest] -> String.trim_trailing(url, ".,)")
      _match -> nil
    end
  end

  defp display_name(path) when is_binary(path) do
    path
    |> Path.basename()
    |> Factory.labelize()
  end

  defp display_name(_path), do: "Opportunities"

  defp attr_value(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, attr_atom(key))
  end

  defp attr_value(_attrs, _key), do: nil

  defp attr_atom("repo_path"), do: :repo_path
  defp attr_atom("display_name"), do: :display_name
  defp attr_atom("raw_input"), do: :raw_input
  defp attr_atom("agent"), do: :agent
  defp attr_atom("model"), do: :model
  defp attr_atom(_key), do: nil

  defp sql_value(value), do: RepoSqlite.escape(value)

  defp now_iso, do: Factory.now() |> DateTime.to_iso8601()

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

  defp opportunity_readme(title, raw_input) do
    step_lines =
      Enum.map_join(@research_steps, "\n", fn step ->
        "- `#{step.artifact}` - #{step.title}"
      end)

    """
    # #{title}

    ## Raw Input

    #{raw_input}

    ## Current Stage

    Captured by AFP. The research agent executes the seven-step pipeline from
    `AGENTS.md` and rewrites this file as the final summary in the last step.

    ## Expected Step Artifacts

    #{step_lines}
    """
  end

  defp agent_prompt(repo, opportunity, run_id, raw_input) do
    relative_root = opportunity_relative_root(opportunity["id"])

    """
    You are working inside an AFP opportunity repo.

    Read `AGENTS.md` first, then execute the seven-step research pipeline it declares for this opportunity, in order, using the step skills under `#{@skills_path}/`.

    OPPORTUNITY_ID: #{opportunity["id"]}
    OPPORTUNITY_RUN_ID: #{run_id}
    OPPORTUNITY_DIR: #{relative_root}
    BASE_SQLITE: #{@base_sqlite_path}

    RAW_DEMAND_INPUT:
    #{raw_input}

    Required work:
    1. Execute all seven pipeline steps in order. Never skip, merge, or reorder steps.
    2. Write each step's artifact to its fixed path under `#{relative_root}/#{@steps_path}/`.
    3. After each step, upsert its row in `opportunity_step_results` (see AGENTS.md -> Step Recording) using OPPORTUNITY_ID and OPPORTUNITY_RUN_ID. The rows are pre-seeded as 'pending'.
    4. Keep only the most decision-relevant supporting materials (the 20-80 rule: max 3 files per step) under each step's own directory and register every kept file in `opportunity_step_evidence` (see AGENTS.md -> Evidence Materials).
    5. Finish with the score aggregator: rewrite `#{relative_root}/README.md` as the final summary and update the opportunities row with total_score, route, and latest_summary.
    6. Keep all files for this opportunity under `#{relative_root}/`.
    7. Do not invent evidence. Follow the evidence caps from the skills.

    Repo root: #{repo["repo_path"]}
    """
    |> String.trim()
  end
end
