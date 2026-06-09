# @input  - Operator opportunity prompts, configured repo paths, repo-local SQLite, and Codex app-server progress
# @output - Opportunity repo scaffolding, health inspection, opportunity records, file previews, and Codex launch state
# @pos    - Context boundary for the portable opportunities repository workflow
defmodule Afp.Factory.Opportunities do
  require Logger

  alias Afp.Factory
  alias Afp.Factory.Demand.CodexAppClient
  alias Afp.Factory.Events
  alias Afp.Factory.Settings

  @setting_key "opportunity_repo"
  @base_sqlite_path "base.sqlite"
  @agents_path "AGENTS.md"
  @skills_path ".skills"
  @opportunities_path "opportunities"
  @generated_files_path "generated_other_files"
  @schema_version 1
  @required_tables ~w(repo_metadata opportunities opportunity_runs opportunity_files)
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
             SELECT id, opportunity_id, run_type, status, stage, codex_session_id,
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

  def create_opportunity_with_codex(attrs, opts) when is_map(attrs) do
    with {:ok, repo} <- healthy_repo(),
         {:ok, raw_input} <- raw_input(attrs),
         {:ok, opportunity} <- create_opportunity_record(repo, raw_input),
         {:ok, run} <- create_opportunity_run(repo, opportunity, raw_input) do
      case start_codex_run(repo, opportunity, run, opts) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def create_opportunity_with_codex(_attrs, _opts), do: {:error, :raw_input_required}

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

  def generated_files_path, do: @generated_files_path
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
         :ok <- mkdir(Path.join(repo_path, @opportunities_path)),
         :ok <- mkdir(Path.join(repo_path, @skills_path)),
         :ok <- write_file(repo_path, @agents_path, agents_md(display_name)),
         :ok <- write_file(repo_path, "README.md", readme_md(display_name)),
         :ok <- write_file(repo_path, Path.join(@skills_path, "README.md"), skills_readme_md()),
         :ok <-
           write_file(
             repo_path,
             Path.join([@skills_path, "opportunity-research", "SKILL.md"]),
             opportunity_skill_md()
           ),
         :ok <- write_file(repo_path, ".gitignore", gitignore()) do
      :ok
    end
  end

  defp mkdir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, path, reason}}
    end
  end

  defp write_file(repo_path, relative_path, content) do
    full_path = Path.join(repo_path, relative_path)

    with :ok <- mkdir(Path.dirname(full_path)),
         :ok <- File.write(full_path, content, [:exclusive]) do
      :ok
    else
      {:error, :eexist} -> {:error, {:target_file_exists, relative_path}}
      {:error, reason} -> {:error, {:write_failed, relative_path, reason}}
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

  defp create_opportunity_record(repo, raw_input) do
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
               (id, title, raw_input, source_url, status, stage, created_at, updated_at)
             VALUES
               (#{sql_value(opportunity_id)}, #{sql_value(title)}, #{sql_value(raw_input)},
                #{sql_value(source_url)}, 'captured', 'created', #{sql_value(now)}, #{sql_value(now)});
             """
           ),
         :ok <- refresh_file_index(repo, opportunity_id) do
      opportunity = %{
        "id" => opportunity_id,
        "title" => title,
        "raw_input" => raw_input,
        "source_url" => source_url,
        "status" => "captured",
        "stage" => "created",
        "created_at" => now,
        "updated_at" => now
      }

      Events.record_event("opportunity", opportunity_id, "opportunity_created", %{
        title: title,
        repo_path: repo["repo_path"]
      })

      {:ok, opportunity}
    end
  end

  defp write_opportunity_files(repo, opportunity_id, title, raw_input) do
    root = Path.join([repo["repo_path"], @opportunities_path, opportunity_id])

    with :ok <- mkdir(root),
         :ok <- mkdir(Path.join(root, @generated_files_path)),
         :ok <- File.write(Path.join(root, "README.md"), opportunity_readme(title, raw_input)) do
      :ok
    else
      {:error, reason} ->
        {:error, {:write_failed, opportunity_relative_root(opportunity_id), reason}}
    end
  end

  defp create_opportunity_run(repo, opportunity, raw_input) do
    run_id = Ecto.UUID.generate()
    now = now_iso()
    prompt = codex_prompt(repo, opportunity, raw_input)

    with :ok <-
           sqlite_exec(
             repo,
             """
             INSERT INTO opportunity_runs
               (id, opportunity_id, run_type, status, stage, prompt, created_at, updated_at)
             VALUES
               (#{sql_value(run_id)}, #{sql_value(opportunity["id"])}, 'initial_research',
                'queued', 'queued', #{sql_value(prompt)}, #{sql_value(now)}, #{sql_value(now)});

             UPDATE opportunities
             SET current_run_id = #{sql_value(run_id)},
                 status = 'queued',
                 stage = 'Codex launch queued',
                 updated_at = #{sql_value(now)}
             WHERE id = #{sql_value(opportunity["id"])};
             """
           ) do
      run = %{
        "id" => run_id,
        "opportunity_id" => opportunity["id"],
        "run_type" => "initial_research",
        "status" => "queued",
        "stage" => "queued",
        "prompt" => prompt,
        "created_at" => now,
        "updated_at" => now
      }

      Events.record_event("opportunity_run", run_id, "opportunity_run_queued", %{
        opportunity_id: opportunity["id"]
      })

      {:ok, run}
    end
  end

  defp start_codex_run(repo, opportunity, run, opts) do
    case codex_launch_mode(opts) do
      :sync ->
        case complete_codex_run(repo, opportunity, run, opts) do
          {:ok, completion} ->
            {:ok, Map.merge(completion, %{opportunity: fetch_opportunity!(opportunity["id"])})}

          {:error, reason} ->
            {:error, reason}
        end

      :async ->
        with :ok <- ensure_codex_launch_supervisor(),
             {:ok, pid} <-
               safe_start_codex_launch_worker(fn ->
                 complete_codex_run(repo, opportunity, run, opts)
               end) do
          {:ok, %{opportunity: opportunity, run: run, codex_launch_worker_pid: pid}}
        else
          {:error, reason} ->
            mark_codex_run_failed(repo, opportunity["id"], run["id"], reason)
            {:error, reason}
        end
    end
  end

  defp complete_codex_run(repo, opportunity, run, opts) do
    persist_codex_run_started(repo, opportunity["id"], run["id"])

    attrs = codex_launch_attrs(repo, opportunity, run)

    opts =
      opts
      |> Keyword.drop([:mode, :supervisor])
      |> Keyword.put(:on_launch_event, fn event, payload ->
        persist_codex_progress(repo, opportunity["id"], run["id"], event, payload)
      end)

    case codex_app_client().launch_new_turn(attrs, opts) do
      {:ok, codex_result} ->
        persist_codex_success(repo, opportunity["id"], run["id"], codex_result)

      {:error, reason} ->
        mark_codex_run_failed(repo, opportunity["id"], run["id"], reason)
        {:error, reason}
    end
  rescue
    exception ->
      reason = {:codex_launch_unhandled_failure, Exception.message(exception)}
      mark_codex_run_failed(repo, opportunity["id"], run["id"], reason)
      {:error, reason}
  catch
    kind, reason ->
      failure = {:codex_launch_unhandled_failure, {kind, reason}}
      mark_codex_run_failed(repo, opportunity["id"], run["id"], failure)
      {:error, failure}
  end

  defp codex_launch_mode(opts) do
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

  defp persist_codex_run_started(repo, opportunity_id, run_id) do
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
            stage = 'Codex starting',
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

  defp persist_codex_progress(repo, opportunity_id, run_id, :thread_started, payload) do
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
            stage = 'Codex thread started',
            codex_session_id = #{sql_value(session_id)},
            updated_at = #{sql_value(now)}
        WHERE id = #{sql_value(opportunity_id)};
        """
      )

    Events.record_event("opportunity_run", run_id, "opportunity_run_thread_started", %{
      opportunity_id: opportunity_id,
      codex_session_id: session_id
    })

    :ok
  end

  defp persist_codex_progress(repo, opportunity_id, run_id, :turn_started, payload) do
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
            stage = 'Codex turn started',
            updated_at = #{sql_value(now)}
        WHERE id = #{sql_value(opportunity_id)};
        """
      )

    Events.record_event("opportunity_run", run_id, "opportunity_run_turn_started", %{
      opportunity_id: opportunity_id,
      codex_turn_id: turn["id"]
    })

    :ok
  end

  defp persist_codex_progress(_repo, _opportunity_id, _run_id, _event, _payload), do: :ok

  defp persist_codex_success(repo, opportunity_id, run_id, codex_result) do
    now = now_iso()
    thread = get_in(codex_result, [:thread_response, "result", "thread"]) || %{}
    turn = get_in(codex_result, [:turn_response, "result", "turn"]) || %{}
    completed_turn = get_in(codex_result, [:turn_completed, "params", "turn"]) || %{}
    session_id = thread["sessionId"] || thread["id"]
    final_answer = Map.get(codex_result, :final_answer)
    payload_json = Jason.encode!(codex_payload(codex_result, now))

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
                 stage = 'Initial Codex research completed',
                 codex_session_id = #{sql_value(session_id)},
                 latest_summary = #{sql_value(final_answer)},
                 updated_at = #{sql_value(now)},
                 error = NULL
             WHERE id = #{sql_value(opportunity_id)};
             """
           ) do
      Events.record_event("opportunity_run", run_id, "opportunity_run_completed", %{
        opportunity_id: opportunity_id,
        codex_session_id: session_id
      })

      {:ok, %{run: fetch_run!(opportunity_id, run_id), codex_result: codex_result}}
    end
  end

  defp mark_codex_run_failed(repo, opportunity_id, run_id, reason) do
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
          stage = 'Codex launch failed',
          error = #{sql_value(error_text)},
          updated_at = #{sql_value(now)}
      WHERE id = #{sql_value(opportunity_id)};
      """
    )

    Events.record_event("opportunity_run", run_id, "opportunity_run_failed", %{
      opportunity_id: opportunity_id,
      reason: error_text
    })

    Logger.warning("Opportunity Codex launch failed",
      opportunity_id: opportunity_id,
      run_id: run_id,
      reason: error_text
    )

    :ok
  end

  defp codex_launch_attrs(repo, opportunity, run) do
    repo_path = repo["repo_path"]

    %{
      cwd: repo_path,
      input_text: run["prompt"],
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

  defp codex_payload(codex_result, now) do
    thread = get_in(codex_result, [:thread_response, "result", "thread"]) || %{}
    turn = get_in(codex_result, [:turn_response, "result", "turn"]) || %{}
    completed_turn = get_in(codex_result, [:turn_completed, "params", "turn"]) || %{}

    %{
      "codex_launch_status" => "completed",
      "session_id" => thread["sessionId"] || thread["id"],
      "thread_id" => thread["id"],
      "turn_id" => turn["id"] || completed_turn["id"],
      "turn_status" => completed_turn["status"],
      "transcript_path" => thread["path"],
      "final_answer" => Map.get(codex_result, :final_answer),
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
    SELECT id, title, raw_input, source_url, status, stage, route, total_score,
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
    db_path = Path.join(repo["repo_path"], @base_sqlite_path)

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

  defp codex_app_client do
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
      ('display_name', #{sql_value(display_name)}, #{sql_value(now)})
    ON CONFLICT(key) DO UPDATE SET
      value = excluded.value,
      updated_at = excluded.updated_at;

    CREATE TABLE IF NOT EXISTS opportunities (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      raw_input TEXT NOT NULL,
      source_url TEXT,
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

    CREATE INDEX IF NOT EXISTS idx_opportunities_status ON opportunities(status);
    CREATE INDEX IF NOT EXISTS idx_opportunities_updated_at ON opportunities(updated_at);
    CREATE INDEX IF NOT EXISTS idx_opportunity_runs_opportunity ON opportunity_runs(opportunity_id);
    CREATE INDEX IF NOT EXISTS idx_opportunity_runs_status ON opportunity_runs(status);
    CREATE INDEX IF NOT EXISTS idx_opportunity_files_opportunity ON opportunity_files(opportunity_id);
    """
  end

  defp opportunity_readme(title, raw_input) do
    """
    # #{title}

    ## Raw Input

    #{raw_input}

    ## Current Stage

    Captured by AFP. Codex should update this file as research evidence, scoring,
    route decisions, and next actions become concrete.

    ## Expected Outputs

    - Competitor discovery
    - Five evidence-capped indicator scores
    - Final route decision
    - Concrete next action
    - Supporting files under `#{@generated_files_path}/`
    """
  end

  defp codex_prompt(repo, opportunity, raw_input) do
    relative_root = opportunity_relative_root(opportunity["id"])

    """
    You are working inside an AFP opportunity repo.

    Read `AGENTS.md` and `.skills/opportunity-research/SKILL.md` first. Then use this raw demand input to create or update one opportunity:

    OPPORTUNITY_ID: #{opportunity["id"]}
    OPPORTUNITY_DIR: #{relative_root}
    BASE_SQLITE: #{@base_sqlite_path}

    RAW_DEMAND_INPUT:
    #{raw_input}

    Required work:
    1. Keep all files for this opportunity under `#{relative_root}/`.
    2. Update `#{relative_root}/README.md` with the normalized opportunity, evidence, five indicator scores, final route, uncertainty, and next action.
    3. Put any extra Markdown notes or image artifacts under `#{relative_root}/#{@generated_files_path}/`.
    4. Keep `#{@base_sqlite_path}` aligned with the final title, status, stage, score, route, run state, and file index when practical.
    5. Do not invent evidence. Follow the evidence caps from `.skills/opportunity-research/SKILL.md`.

    Repo root: #{repo["repo_path"]}
    """
    |> String.trim()
  end

  defp agents_md(display_name) do
    """
    # #{display_name} Agent Instructions

    This repository is an AFP opportunities repo. AFP owns the control-plane UI
    and launches Codex turns. This repo owns portable opportunity evidence,
    Markdown summaries, generated files, and the repo-local `#{@base_sqlite_path}`
    index.

    ## Required Structure

    - `#{@base_sqlite_path}` - repo-local SQLite index for opportunities, runs, and files
    - `#{@opportunities_path}/[uuid]/README.md` - one opportunity summary
    - `#{@opportunities_path}/[uuid]/#{@generated_files_path}/` - extra generated Markdown or image files
    - `#{@skills_path}/opportunity-research/SKILL.md` - reusable research harness

    ## Read Order

    1. `AGENTS.md`
    2. `.skills/opportunity-research/SKILL.md`
    3. `README.md`
    4. The target `opportunities/[uuid]/README.md`
    5. Existing files under the target opportunity directory
    6. `base.sqlite` when structured state is needed

    ## Core Rules

    - Work only inside the target opportunity directory unless AFP explicitly asks for repo-wide edits.
    - Keep `validation-ready`, `validation-sprint`, `build-ready`, backup, and reject decisions distinct.
    - No evidence means a maximum score of 5/20 for that indicator. Weak evidence means max 10/20. Medium evidence means max 15/20. Strong evidence can reach 20/20.
    - If evidence is missing, mark it unknown instead of guessing.
    - Do not turn a demand signal into a broad clone. Narrow to one credible wedge, packet, artifact, workflow, or first version.
    - When updating `base.sqlite`, use the existing schema and keep paths relative to the repo root.
    """
  end

  defp readme_md(display_name) do
    """
    # #{display_name}

    Portable opportunity research repo for AFP.

    ## Structure

    - `#{@base_sqlite_path}` stores the opportunity index, Codex runs, and file index.
    - `#{@opportunities_path}/[uuid]/README.md` stores the main Markdown summary for one opportunity.
    - `#{@opportunities_path}/[uuid]/#{@generated_files_path}/` stores additional Markdown notes and images.
    - `#{@skills_path}/` stores repo-local skills Codex should read before research.

    ## base.sqlite Schema

    - `repo_metadata` keeps schema and display metadata.
    - `opportunities` stores raw input, title, status, stage, route, score, session, and summary fields.
    - `opportunity_runs` stores Codex launch/run status, prompt, transcript/session metadata, final answer, and error state.
    - `opportunity_files` stores Markdown/image files displayed by AFP.
    """
  end

  defp skills_readme_md do
    """
    # Opportunity Repo Skills

    Codex should read `opportunity-research/SKILL.md` before working on a new
    opportunity. The skill captures the evidence-capped competitor discovery and
    five-indicator scoring workflow used by AFP.
    """
  end

  defp opportunity_skill_md do
    """
    # Opportunity Research Skill

    Use this skill when AFP gives a simple demand input, idea, need, or URL and
    asks Codex to create or update one opportunity folder.

    ## Workflow

    Simple Input
    -> Competitor Discovery Harness
    -> 5 Indicator Harnesses
    -> Score Aggregator / Route Decision

    Unified scoring caps:

    - No evidence = max 5/20
    - Weak evidence = max 10/20
    - Medium evidence = max 15/20
    - Strong evidence = max 20/20

    If evidence is missing, do not guess. Mark unknown.

    ## 0. Competitor Discovery Harness

    You are a Competitor Discovery Harness.

    Task:
    Given a rough demand input, identify exactly 3 competitors or substitutes that users already use to solve this problem.

    Input:
    {{RAW_DEMAND_INPUT}}

    Rules:
    - Include direct competitors when possible.
    - Include substitutes or manual workarounds if direct competitors are weak.
    - Do not score the opportunity yet.
    - Separate facts from assumptions.
    - Mark uncertainty.

    Output:
    1. Normalized opportunity
    2. Three competitors/substitutes:
       - name
       - type: direct competitor / indirect substitute / manual workaround
       - source
       - why it is relevant
    3. Missing information
    4. Confidence: high / medium / low

    Verification:
    - Are there exactly 3 competitors/substitutes?
    - Is each one connected to the user job?
    - Is each source traceable?

    ## 1. Demand Proof Harness

    You are a Demand Proof Scoring Harness.

    Task:
    Score whether real users are already seeking or using solutions for this demand.

    Inputs:
    - Raw demand: {{RAW_DEMAND_INPUT}}
    - Normalized opportunity: {{NORMALIZED_OPPORTUNITY}}
    - Competitors/substitutes: {{THREE_COMPETITORS}}

    Evidence to find:
    - active competitors
    - review counts
    - recent reviews
    - search/keyword signals
    - community discussions
    - paid products
    - users asking for alternatives

    Output:
    - score: 0-20
    - evidence_strength: missing / weak / medium / strong
    - evidence_items:
      - source
      - summary
      - what it proves
    - reasoning
    - uncertainty
    - next_route

    Verification:
    - Score is capped by evidence strength.
    - Demand is proven by behavior, not model intuition.
    - Recent or active usage is preferred.

    ## 2. Pain Strength Harness

    You are a Pain Strength Scoring Harness.

    Task:
    Score how frequent, intense, and specific the user pain appears to be.

    Inputs:
    - Normalized opportunity: {{NORMALIZED_OPPORTUNITY}}
    - Competitors/substitutes: {{THREE_COMPETITORS}}
    - Demand proof evidence: {{DEMAND_PROOF_EVIDENCE}}

    Evidence to find:
    - repeated complaints in reviews
    - explicit user frustration
    - time loss
    - money loss
    - repeated manual work
    - privacy anxiety
    - workflow errors
    - high-frequency usage pattern

    Output:
    - score: 0-20
    - evidence_strength
    - pain_types: time / money / privacy / error / anxiety / friction
    - frequency_hypothesis
    - intensity_hypothesis
    - evidence_items
    - reasoning
    - uncertainty
    - next_route

    Verification:
    - Pain is tied to user evidence.
    - Frequency and intensity are not invented.
    - Repeated complaints score higher than isolated complaints.

    ## 3. Incumbent Weakness Harness

    You are an Incumbent Weakness Scoring Harness.

    Task:
    Score whether existing solutions have clear weaknesses that create an opening.

    Inputs:
    - Competitors/substitutes: {{THREE_COMPETITORS}}
    - Review or source evidence: {{AVAILABLE_EVIDENCE}}

    Evidence to find:
    - pricing complaints
    - subscription complaints
    - bloated workflow
    - poor UX
    - missing export
    - cloud dependency
    - privacy concerns
    - unreliable performance
    - low rating with high usage
    - underserved user segment

    Output:
    - score: 0-20
    - evidence_strength
    - weaknesses_by_competitor:
      - competitor
      - weakness
      - source
      - evidence summary
    - cross_competitor_pattern
    - reasoning
    - uncertainty
    - next_route

    Verification:
    - Weaknesses are evidence-backed.
    - At least one weakness is tied to multiple users or competitors.
    - Do not score high just because a competitor exists.

    ## 4. Wedge Clarity Harness

    You are a Wedge Clarity Scoring Harness.

    Task:
    Score whether there is a narrow, credible entry point for a smaller app.

    Inputs:
    - Demand model: {{DEMAND_MODEL}}
    - Competitor weakness evidence: {{INCUMBENT_WEAKNESS_OUTPUT}}
    - Pain evidence: {{PAIN_STRENGTH_OUTPUT}}

    Evidence to use:
    - underserved segment
    - repeated unmet need
    - manual workaround
    - missing narrow workflow
    - privacy/local-first complaint
    - export or workflow gap
    - pricing gap

    Output:
    - score: 0-20
    - evidence_strength
    - wedge_segment
    - wedge_job
    - incumbent_failure
    - proposed_angle
    - smallest_complete_solution
    - non_goals
    - reasoning
    - uncertainty
    - next_route

    Verification:
    - Wedge is not "make a better clone."
    - Wedge is narrow enough for MVP.
    - Wedge is connected to evidence, not preference.

    ## 5. Build And Distribution Feasibility Harness

    You are a Build And Distribution Feasibility Scoring Harness.

    Task:
    Score whether this opportunity can be built and distributed as a small first app.

    Inputs:
    - Normalized opportunity: {{NORMALIZED_OPPORTUNITY}}
    - Wedge hypothesis: {{WEDGE_OUTPUT}}
    - Competitors/substitutes: {{THREE_COMPETITORS}}
    - Known constraints: {{CONSTRAINTS}}

    Evidence to assess:
    - MVP complexity
    - platform/API difficulty
    - regulatory risk
    - trust burden
    - dependency on network effects
    - distribution channels
    - App Store keyword/search entry
    - community/SEO/GEO entry
    - whether first version can complete one job

    Output:
    - score: 0-20
    - evidence_strength
    - build_feasibility
    - distribution_feasibility
    - hard_blockers
    - first_version_boundary
    - reasoning
    - uncertainty
    - next_route

    Verification:
    - Build score does not ignore distribution.
    - High trust/legal/platform risk is flagged.
    - A narrow first version is described.

    ## Final Score Aggregator Harness

    You are a Demand Item Score Aggregator.

    Task:
    Aggregate five evidence-backed indicator scores and route the Demand Item.

    Inputs:
    - Demand Proof: {{DEMAND_PROOF_OUTPUT}}
    - Pain Strength: {{PAIN_STRENGTH_OUTPUT}}
    - Incumbent Weakness: {{INCUMBENT_WEAKNESS_OUTPUT}}
    - Wedge Clarity: {{WEDGE_CLARITY_OUTPUT}}
    - Build And Distribution Feasibility: {{BUILD_DISTRIBUTION_OUTPUT}}

    Routing rules:
    - PRD Kit Ready: total >= 80, no indicator below 12, Demand Proof and Pain Strength are not weak/missing, no hard blocker.
    - Backup Pool Strong: 65-79, promising but incomplete evidence.
    - Backup Pool Weak: 50-64, too many unknowns.
    - Reject: < 50, no demand proof, no wedge, or hard blocker.

    Output:
    - total_score: 0-100
    - indicator_scores
    - evidence_quality_summary
    - hard_blockers
    - route: PRD Kit Ready / Backup Pool Strong / Backup Pool Weak / Reject
    - reason
    - next_action
    - required_human_decision

    Verification:
    - No score violates evidence cap.
    - Route follows rules.
    - Next action is concrete.
    """
  end

  defp gitignore do
    """
    .DS_Store
    *.sqlite-shm
    *.sqlite-wal
    """
  end
end
