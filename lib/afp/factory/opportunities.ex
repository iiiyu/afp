# @input  - Operator opportunity prompts, configured repo paths, repo-local SQLite, and agent launch progress
# @output - Opportunity repo scaffolding, health inspection, opportunity records, file previews, and Codex/Claude Code launch state
# @pos    - Context boundary for the portable opportunities repository workflow
defmodule Afp.Factory.Opportunities do
  require Logger

  alias Afp.Factory
  alias Afp.Factory.Demand.CodexAppClient
  alias Afp.Factory.Events
  alias Afp.Factory.Opportunities.ClaudeCodeClient
  alias Afp.Factory.Settings

  @setting_key "opportunity_repo"
  @base_sqlite_path "base.sqlite"
  @agents_path "AGENTS.md"
  @skills_path ".skills"
  @opportunities_path "opportunities"
  @steps_path "steps"
  @schema_version 4
  @template_version 4
  @core_tables ~w(repo_metadata opportunities opportunity_runs opportunity_files)
  @required_tables @core_tables ++ ["opportunity_step_results", "opportunity_step_evidence"]
  @agent_tables ~w(opportunities opportunity_runs)
  @agents ~w(codex claude_code)
  @default_agent "codex"

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
  @codex_launch_supervisor Afp.Factory.Demand.CodexLaunchSupervisor
  @image_extensions ~w(.png .jpg .jpeg .gif .webp)
  @markdown_extensions ~w(.md .markdown)

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
      case start_agent_run(repo, opportunity, run, opts) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def create_opportunity(_attrs, _opts), do: {:error, :raw_input_required}

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
    with {:ok, repo} <- healthy_repo(),
         {:ok, root} <- opportunity_root(repo, opportunity_id) do
      files =
        root
        |> supported_files()
        |> Enum.map(&file_info(root, &1))
        |> Enum.sort_by(&file_sort_key/1)

      {:ok, files}
    end
  end

  def read_opportunity_file(opportunity_id, relative_path) do
    with {:ok, repo} <- healthy_repo(),
         {:ok, root} <- opportunity_root(repo, opportunity_id),
         {:ok, full_path} <- safe_child_path(root, relative_path),
         :ok <- ensure_supported_file(full_path),
         {:ok, type} <- file_type(full_path) do
      case type do
        "markdown" ->
          case File.read(full_path) do
            {:ok, content} -> {:ok, %{type: type, relative_path: relative_path, content: content}}
            {:error, reason} -> {:error, {:file_read_failed, reason}}
          end

        "image" ->
          case File.read(full_path) do
            {:ok, content} ->
              {:ok,
               %{
                 type: type,
                 relative_path: relative_path,
                 mime_type: mime_type(full_path),
                 data: Base.encode64(content)
               }}

            {:error, reason} ->
              {:error, {:file_read_failed, reason}}
          end
      end
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
         :ok <- refresh_file_index(repo, opportunity_id) do
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

  defp start_agent_run(repo, opportunity, run, opts) do
    agent = run["agent"] || @default_agent

    case launch_mode(opts) do
      :sync ->
        case complete_agent_run(repo, opportunity, run, opts) do
          {:ok, completion} ->
            {:ok, Map.merge(completion, %{opportunity: fetch_opportunity!(opportunity["id"])})}

          {:error, reason} ->
            {:error, reason}
        end

      :async ->
        with :ok <- ensure_codex_launch_supervisor(),
             {:ok, pid} <-
               safe_start_codex_launch_worker(fn ->
                 complete_agent_run(repo, opportunity, run, opts)
               end) do
          {:ok, %{opportunity: opportunity, run: run, launch_worker_pid: pid}}
        else
          {:error, reason} ->
            mark_agent_run_failed(repo, opportunity["id"], run["id"], agent, reason)
            {:error, reason}
        end
    end
  end

  defp complete_agent_run(repo, opportunity, run, opts) do
    agent = run["agent"] || @default_agent
    persist_agent_run_started(repo, opportunity["id"], run["id"], agent)

    attrs = agent_launch_attrs(repo, opportunity, run)

    opts =
      opts
      |> Keyword.drop([:mode, :supervisor])
      |> Keyword.put(:on_launch_event, fn event, payload ->
        persist_agent_progress(repo, opportunity["id"], run["id"], agent, event, payload)
      end)

    case launch_client(agent).launch_new_turn(attrs, opts) do
      {:ok, launch_result} ->
        persist_agent_success(repo, opportunity["id"], run, agent, launch_result)

      {:error, reason} ->
        mark_agent_run_failed(repo, opportunity["id"], run["id"], agent, reason)
        {:error, reason}
    end
  rescue
    exception ->
      reason = {:agent_launch_unhandled_failure, Exception.message(exception)}
      mark_agent_run_failed(repo, opportunity["id"], run["id"], run["agent"], reason)
      {:error, reason}
  catch
    kind, reason ->
      failure = {:agent_launch_unhandled_failure, {kind, reason}}
      mark_agent_run_failed(repo, opportunity["id"], run["id"], run["agent"], failure)
      {:error, failure}
  end

  defp launch_mode(opts) do
    case Keyword.get(opts, :mode, Application.get_env(:afp, :codex_launch_mode, :async)) do
      :sync -> :sync
      "sync" -> :sync
      _mode -> :async
    end
  end

  defp ensure_codex_launch_supervisor do
    if Process.whereis(@codex_launch_supervisor) do
      :ok
    else
      child_spec =
        Supervisor.child_spec({Task.Supervisor, name: @codex_launch_supervisor},
          id: @codex_launch_supervisor
        )

      safe_supervisor_call(fn -> Supervisor.start_child(Afp.Supervisor, child_spec) end)
      |> case do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, {:already_present, _id}} -> :ok
        {:error, reason} -> {:error, {:codex_launch_supervisor_start_failed, reason}}
      end
    end
  end

  defp safe_start_codex_launch_worker(fun) when is_function(fun, 0) do
    safe_supervisor_call(fn -> Task.Supervisor.start_child(@codex_launch_supervisor, fun) end)
  end

  defp safe_supervisor_call(fun) when is_function(fun, 0) do
    try do
      fun.()
    catch
      :exit, reason -> {:error, {:codex_launch_supervisor_exit, reason}}
    end
  end

  defp persist_agent_run_started(repo, opportunity_id, run_id, agent) do
    now = now_iso()

    :ok =
      sqlite_exec(
        repo,
        """
        UPDATE opportunity_runs
        SET status = 'running',
            stage = 'starting',
            started_at = COALESCE(started_at, #{sql_value(now)}),
            updated_at = #{sql_value(now)},
            error = NULL
        WHERE id = #{sql_value(run_id)};

        UPDATE opportunities
        SET status = 'running',
            stage = '#{agent_label(agent)} starting',
            current_run_id = #{sql_value(run_id)},
            updated_at = #{sql_value(now)},
            error = NULL
        WHERE id = #{sql_value(opportunity_id)};
        """
      )

    Events.record_event("opportunity_run", run_id, "opportunity_run_started", %{
      opportunity_id: opportunity_id
    })

    {:ok, %{run_id: run_id}}
  end

  defp persist_agent_progress(repo, opportunity_id, run_id, agent, :thread_started, payload) do
    now = now_iso()
    thread = get_in(payload, ["result", "thread"]) || %{}
    session_id = thread["sessionId"] || thread["id"]

    :ok =
      sqlite_exec(
        repo,
        """
        UPDATE opportunity_runs
        SET status = 'running',
            stage = 'thread_started',
            codex_session_id = #{sql_value(session_id)},
            codex_thread_id = #{sql_value(thread["id"])},
            transcript_path = #{sql_value(thread["path"])},
            updated_at = #{sql_value(now)}
        WHERE id = #{sql_value(run_id)};

        UPDATE opportunities
        SET status = 'running',
            stage = '#{agent_label(agent)} session started',
            codex_session_id = #{sql_value(session_id)},
            updated_at = #{sql_value(now)}
        WHERE id = #{sql_value(opportunity_id)};
        """
      )

    Events.record_event("opportunity_run", run_id, "opportunity_run_thread_started", %{
      opportunity_id: opportunity_id,
      agent: agent,
      codex_session_id: session_id
    })

    :ok
  end

  defp persist_agent_progress(repo, opportunity_id, run_id, agent, :turn_started, payload) do
    now = now_iso()
    turn = get_in(payload, ["result", "turn"]) || %{}

    :ok =
      sqlite_exec(
        repo,
        """
        UPDATE opportunity_runs
        SET status = 'running',
            stage = 'turn_started',
            codex_turn_id = #{sql_value(turn["id"])},
            updated_at = #{sql_value(now)}
        WHERE id = #{sql_value(run_id)};

        UPDATE opportunities
        SET status = 'running',
            stage = '#{agent_label(agent)} turn started',
            updated_at = #{sql_value(now)}
        WHERE id = #{sql_value(opportunity_id)};
        """
      )

    Events.record_event("opportunity_run", run_id, "opportunity_run_turn_started", %{
      opportunity_id: opportunity_id,
      agent: agent,
      codex_turn_id: turn["id"]
    })

    :ok
  end

  defp persist_agent_progress(_repo, opportunity_id, run_id, agent, :activity, payload)
       when is_map(payload) do
    Events.broadcast_run_activity(opportunity_id, run_id, Map.put(payload, "agent", agent))
    :ok
  end

  defp persist_agent_progress(_repo, _opportunity_id, _run_id, _agent, _event, _payload), do: :ok

  defp persist_agent_success(repo, opportunity_id, run, agent, launch_result) do
    run_id = run["id"]
    now = now_iso()
    thread = get_in(launch_result, [:thread_response, "result", "thread"]) || %{}
    turn = get_in(launch_result, [:turn_response, "result", "turn"]) || %{}
    completed_turn = get_in(launch_result, [:turn_completed, "params", "turn"]) || %{}
    session_id = thread["sessionId"] || thread["id"]
    final_answer = Map.get(launch_result, :final_answer)
    payload_json = Jason.encode!(agent_payload(agent, run["model"], launch_result, now))

    with :ok <- refresh_file_index(repo, opportunity_id),
         :ok <-
           sqlite_exec(
             repo,
             """
             UPDATE opportunity_runs
             SET status = 'completed',
                 stage = 'completed',
                 codex_session_id = #{sql_value(session_id)},
                 codex_thread_id = #{sql_value(thread["id"])},
                 codex_turn_id = #{sql_value(turn["id"] || completed_turn["id"])},
                 transcript_path = #{sql_value(thread["path"])},
                 final_answer = #{sql_value(final_answer)},
                 completed_at = #{sql_value(now)},
                 updated_at = #{sql_value(now)},
                 payload_json = #{sql_value(payload_json)},
                 error = NULL
             WHERE id = #{sql_value(run_id)};

             UPDATE opportunities
             SET status = 'researched',
                 stage = 'Initial #{agent_label(agent)} research completed',
                 codex_session_id = #{sql_value(session_id)},
                 latest_summary = #{sql_value(final_answer)},
                 updated_at = #{sql_value(now)},
                 error = NULL
             WHERE id = #{sql_value(opportunity_id)};
             """
           ) do
      Events.record_event("opportunity_run", run_id, "opportunity_run_completed", %{
        opportunity_id: opportunity_id,
        agent: agent,
        codex_session_id: session_id
      })

      {:ok, %{run: fetch_run!(opportunity_id, run_id), codex_result: launch_result}}
    end
  end

  defp mark_agent_run_failed(repo, opportunity_id, run_id, agent, reason) do
    now = now_iso()
    error_text = inspect(reason)

    sqlite_exec(
      repo,
      """
      UPDATE opportunity_runs
      SET status = 'failed',
          stage = 'failed',
          error = #{sql_value(error_text)},
          completed_at = #{sql_value(now)},
          updated_at = #{sql_value(now)}
      WHERE id = #{sql_value(run_id)};

      UPDATE opportunities
      SET status = 'failed',
          stage = '#{agent_label(agent)} launch failed',
          error = #{sql_value(error_text)},
          updated_at = #{sql_value(now)}
      WHERE id = #{sql_value(opportunity_id)};
      """
    )

    Events.record_event("opportunity_run", run_id, "opportunity_run_failed", %{
      opportunity_id: opportunity_id,
      agent: agent,
      reason: error_text
    })

    Logger.warning("Opportunity agent launch failed",
      opportunity_id: opportunity_id,
      run_id: run_id,
      agent: agent,
      reason: error_text
    )

    :ok
  end

  defp agent_launch_attrs(repo, opportunity, run) do
    repo_path = repo["repo_path"]

    %{
      cwd: repo_path,
      input_text: run["prompt"],
      model: run["model"],
      opportunity_id: opportunity["id"],
      opportunity_run_id: run["id"],
      client_user_message_id: run["id"],
      approval_policy: "on-request",
      sandbox_mode: "workspace-write",
      source_repo_root: repo_path,
      write_targets: %{
        "opportunities" => @opportunities_path,
        "base_sqlite" => @base_sqlite_path,
        "skills" => @skills_path
      },
      sqlite_path: @base_sqlite_path,
      sqlite_allowed_operations: [
        "upsert_opportunity",
        "upsert_run",
        "upsert_step_result",
        "upsert_evidence",
        "link_file",
        "upsert_candidate"
      ],
      network_access: true,
      sandbox_policy: %{
        "type" => "workspaceWrite",
        "writableRoots" => [
          Path.join(repo_path, @opportunities_path),
          Path.join(repo_path, @base_sqlite_path),
          Path.join(repo_path, @skills_path)
        ],
        "networkAccess" => true,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }
    }
  end

  defp agent_payload(agent, model, launch_result, now) do
    thread = get_in(launch_result, [:thread_response, "result", "thread"]) || %{}
    turn = get_in(launch_result, [:turn_response, "result", "turn"]) || %{}
    completed_turn = get_in(launch_result, [:turn_completed, "params", "turn"]) || %{}

    %{
      "agent" => agent,
      "model" => model,
      "launch_status" => "completed",
      "session_id" => thread["sessionId"] || thread["id"],
      "thread_id" => thread["id"],
      "turn_id" => turn["id"] || completed_turn["id"],
      "turn_status" => completed_turn["status"],
      "transcript_path" => thread["path"],
      "final_answer" => Map.get(launch_result, :final_answer),
      "completed_at" => now
    }
  end

  defp refresh_file_index(repo, opportunity_id) do
    with {:ok, files} <- list_opportunity_files_from_repo(repo, opportunity_id) do
      statements =
        Enum.map_join(files, "\n", fn file ->
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
        end)

      sqlite_exec(repo, statements)
    end
  end

  defp list_opportunity_files_from_repo(repo, opportunity_id) do
    with {:ok, root} <- opportunity_root(repo, opportunity_id) do
      files =
        root
        |> supported_files()
        |> Enum.map(&file_info(root, &1))

      {:ok, files}
    end
  end

  defp opportunity_root(%{"repo_path" => repo_path}, opportunity_id) do
    root = Path.join([repo_path, @opportunities_path, opportunity_id])

    if File.dir?(root) do
      {:ok, root}
    else
      {:error, :opportunity_files_missing}
    end
  end

  defp supported_files(root) do
    root
    |> walk_files()
    |> Enum.filter(&supported_file?/1)
  end

  defp walk_files(root) do
    case File.ls(root) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(root, entry)

          cond do
            File.dir?(path) -> walk_files(path)
            File.regular?(path) -> [path]
            true -> []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp supported_file?(path) do
    extension = path |> Path.extname() |> String.downcase()
    extension in @markdown_extensions or extension in @image_extensions
  end

  defp file_info(root, path) do
    stat = File.stat!(path, time: :posix)

    %{
      relative_path: path |> Path.relative_to(root) |> Path.split() |> Path.join(),
      type: elem(file_type(path), 1),
      size_bytes: stat.size,
      mtime: stat.mtime |> DateTime.from_unix!() |> DateTime.to_iso8601()
    }
  end

  defp file_sort_key(%{relative_path: "README.md"}), do: {0, "README.md"}
  defp file_sort_key(%{relative_path: path}), do: {1, path}

  defp safe_child_path(root, relative_path) do
    full_path = Path.expand(relative_path, root)
    expanded_root = Path.expand(root)

    if full_path == expanded_root or String.starts_with?(full_path, expanded_root <> "/") do
      {:ok, full_path}
    else
      {:error, :path_outside_opportunity}
    end
  end

  defp ensure_supported_file(path) do
    cond do
      not File.regular?(path) -> {:error, :file_missing}
      supported_file?(path) -> :ok
      true -> {:error, :unsupported_file_type}
    end
  end

  defp file_type(path) do
    extension = path |> Path.extname() |> String.downcase()

    cond do
      extension in @markdown_extensions -> {:ok, "markdown"}
      extension in @image_extensions -> {:ok, "image"}
      true -> {:error, :unsupported_file_type}
    end
  end

  defp mime_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      _extension -> "image/png"
    end
  end

  defp fetch_opportunity!(id) do
    {:ok, opportunity} = get_opportunity(id)
    opportunity
  end

  defp fetch_run!(opportunity_id, run_id) do
    opportunity_id
    |> list_runs()
    |> Enum.find(&(&1["id"] == run_id))
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
    |> sqlite_json_path(sql)
  end

  defp sqlite_json_path(db_path, sql) do
    case System.cmd("sqlite3", ["-readonly", "-json", db_path, sql], stderr_to_stdout: true) do
      {output, 0} -> decode_sqlite_json(output)
      {output, _status} -> {:error, {:sqlite_error, String.trim(output)}}
    end
  rescue
    error in ErlangError ->
      case error.original do
        :enoent -> {:error, :sqlite3_unavailable}
        _other -> {:error, {:sqlite_error, Exception.message(error)}}
      end
  end

  defp sqlite_exec(_repo, ""), do: :ok

  defp sqlite_exec(repo, sql) do
    repo["repo_path"]
    |> Path.join(@base_sqlite_path)
    |> sqlite_exec_path(sql)
  end

  defp sqlite_exec_path(_db_path, ""), do: :ok

  defp sqlite_exec_path(db_path, sql) do
    case System.cmd("sqlite3", [db_path, sql], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, {:sqlite_error, String.trim(output)}}
    end
  rescue
    error in ErlangError ->
      case error.original do
        :enoent -> {:error, :sqlite3_unavailable}
        _other -> {:error, {:sqlite_error, Exception.message(error)}}
      end
  end

  defp decode_sqlite_json(output) do
    output = String.trim(output)

    if output == "" do
      {:ok, []}
    else
      case Jason.decode(output) do
        {:ok, rows} when is_list(rows) -> {:ok, rows}
        {:ok, _value} -> {:error, :unexpected_sqlite_json}
        {:error, error} -> {:error, {:invalid_sqlite_json, Exception.message(error)}}
      end
    end
  end

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

  defp sql_value(nil), do: "NULL"
  defp sql_value(value) when is_integer(value), do: Integer.to_string(value)

  defp sql_value(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("'", "''")

    "'#{escaped}'"
  end

  defp now_iso, do: Factory.now() |> DateTime.to_iso8601()

  defp launch_client("claude_code") do
    Application.get_env(:afp, :claude_code_client, ClaudeCodeClient)
  end

  defp launch_client(_agent) do
    Application.get_env(:afp, :codex_app_client, CodexAppClient)
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
