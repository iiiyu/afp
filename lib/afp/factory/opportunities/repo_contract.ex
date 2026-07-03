# @input  - Operator-selected Opportunity repo paths and existing repo contents
# @output - Repo scaffold, health inspection, template upgrade, and normalized repo metadata
# @pos    - Portable Opportunity repo contract module behind the Opportunities context
defmodule Afp.Factory.Opportunities.RepoContract do
  require Logger

  alias Afp.Factory
  alias Afp.Factory.Opportunities.StorageSchema

  @base_sqlite_path "base.sqlite"
  @agents_path "AGENTS.md"
  @skills_path ".skills"
  @opportunities_path "opportunities"

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
    {".skills/score-aggregator/SKILL.md", ".skills/score-aggregator/SKILL.md"},
    {".skills/opportunity-to-buildspec/SKILL.md", ".skills/opportunity-to-buildspec/SKILL.md"},
    {".skills/opportunity-to-buildspec/references/spec-package-template.md",
     ".skills/opportunity-to-buildspec/references/spec-package-template.md"},
    {".skills/opportunity-to-buildspec/evals/evals.json",
     ".skills/opportunity-to-buildspec/evals/evals.json"}
  ]

  def normalize_repo_path(nil), do: nil
  def normalize_repo_path(path) when is_binary(path), do: Factory.expand_path(path)
  def normalize_repo_path(path), do: path

  def display_name(path) when is_binary(path) do
    path
    |> Path.basename()
    |> Factory.labelize()
  end

  def display_name(_path), do: "Opportunities"

  def create_from_template(attrs) when is_map(attrs) do
    with {:ok, repo_path} <- target_repo_path(attrs),
         :ok <- ensure_target_available(repo_path),
         :ok <- ensure_executable("sqlite3", :sqlite3_unavailable),
         :ok <- ensure_executable("git", :git_unavailable),
         display_name <-
           Factory.trim_nil(attr_value(attrs, "display_name")) || display_name(repo_path),
         :ok <- write_repo_files(repo_path, display_name),
         :ok <- StorageSchema.create_base(repo_path, display_name),
         :ok <- init_git(repo_path) do
      {:ok, %{"repo_path" => repo_path, "display_name" => display_name}}
    end
  end

  def create_from_template(_attrs), do: {:error, :repo_path_required}

  def health(nil) do
    %{
      "health_state" => "missing",
      "health_summary" => "Opportunity repo path is required.",
      "missing_paths" => [],
      "parse_errors" => [],
      "latest_scan_at" => now_iso()
    }
  end

  def health(repo_path) do
    cond do
      Factory.blank?(repo_path) ->
        health(nil)

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
        StorageSchema.inspect_schema(Path.join(repo_path, @base_sqlite_path))
      end

    health_from(repo_path, missing_paths, parse_errors, sqlite_health)
  end

  defp health_from(_repo_path, missing_paths, parse_errors, sqlite_health) do
    cond do
      Enum.any?(missing_paths, &String.ends_with?(&1, @agents_path)) ->
        health_attrs(
          "agents_missing",
          "Opportunity repo is missing AGENTS.md.",
          missing_paths,
          parse_errors
        )

      sqlite_health == {:error, :sqlite_missing} ->
        health_attrs(
          "sqlite_missing",
          "Opportunity repo is missing base.sqlite.",
          missing_paths,
          parse_errors
        )

      missing_paths != [] ->
        health_attrs(
          "invalid_structure",
          "Opportunity repo does not match the required base.sqlite/opportunities/AGENTS.md/.skills structure.",
          missing_paths,
          parse_errors
        )

      match?({:error, _reason}, sqlite_health) ->
        {_tag, reason} = sqlite_health

        health_attrs(
          "sqlite_invalid",
          "base.sqlite exists but does not expose the required opportunity tables.",
          missing_paths,
          [inspect(reason) | parse_errors]
        )

      true ->
        {:ok, sqlite_info} = sqlite_health

        health_attrs(
          "healthy",
          "Opportunity repo is ready. base.sqlite schema v#{sqlite_info["schema_version"] || StorageSchema.schema_version()} is available.",
          [],
          parse_errors,
          sqlite_info
        )
    end
  end

  defp health_attrs(state, summary, missing_paths, parse_errors, extra \\ %{}) do
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

  defp maybe_upgrade_repo(repo_path) do
    db_path = Path.join(repo_path, @base_sqlite_path)

    with true <- File.regular?(db_path),
         {:ok, true} <- StorageSchema.core_schema_present?(db_path) do
      upgrade_repo(repo_path, db_path)
    else
      _precondition_failed -> :ok
    end
  end

  defp upgrade_repo(repo_path, db_path) do
    with :ok <- StorageSchema.upgrade_schema(db_path),
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

  defp ensure_template_files(repo_path, db_path) do
    case StorageSchema.stored_template_version(db_path) do
      {:ok, version} ->
        if version >= StorageSchema.template_version() do
          :ok
        else
          display_name = StorageSchema.stored_display_name(db_path) || display_name(repo_path)

          with :ok <- write_template_files(repo_path, display_name) do
            StorageSchema.record_versions(db_path)
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp target_repo_path(attrs) do
    case attrs |> attr_value("repo_path") |> Factory.trim_nil() do
      nil -> {:error, :repo_path_required}
      path -> {:ok, Factory.expand_path(path)}
    end
  end

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

  defp attr_value(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, attr_atom(key))

  defp attr_value(_attrs, _key), do: nil

  defp attr_atom("repo_path"), do: :repo_path
  defp attr_atom("display_name"), do: :display_name
  defp attr_atom(_key), do: nil

  defp now_iso, do: Factory.now() |> DateTime.to_iso8601()
end
