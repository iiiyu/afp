# @input  - A demand source repo path and its manifest file path
# @output - Inspection attrs: parsed manifest fields, health state, missing paths
# @pos    - Reads and interprets the afp-demand-source.json contract for Demand
defmodule Afp.Factory.Demand.SourceManifest do
  @moduledoc """
  Reads a demand source repo's manifest and derives its health.

  One entry point — `inspect_repo/3` — takes the base attrs assembled by the
  caller plus the repo and manifest paths, and merges in the manifest fields and
  health verdict. Manifest decoding, the health state machine, legacy-layout
  detection, and the JSON value coercions are all hidden here.
  """

  alias Afp.Factory

  @doc """
  Merge manifest-derived and health attrs into `base` for an existing repo path.

  `base` already carries `repo_path`, `display_name`, `manifest_path`, etc. The
  caller guarantees `repo_path` is an existing directory.
  """
  def inspect_repo(base, repo_path, manifest_path) do
    git_repo? = File.dir?(Path.join(repo_path, ".git"))

    case read_source_manifest(repo_path, manifest_path) do
      {:missing, manifest_full_path} ->
        health_state = if(git_repo?, do: "manifest_missing", else: "not_git")
        legacy_attrs = legacy_layout_attrs(repo_path)

        Map.merge(base, %{
          "health_state" => health_state,
          "health_summary" => source_health_summary(health_state, legacy_attrs),
          "missing_paths" => [manifest_full_path],
          "parse_errors" => []
        })
        |> Map.merge(legacy_attrs)

      {:error, reason} ->
        Map.merge(base, %{
          "health_state" => "invalid_manifest",
          "health_summary" => "Manifest could not be parsed.",
          "parse_errors" => [reason],
          "missing_paths" => []
        })

      {:ok, manifest} ->
        manifest_attrs = source_manifest_attrs(manifest)
        health_attrs = source_health_attrs(repo_path, git_repo?, manifest_attrs)

        base
        |> Map.merge(manifest_attrs)
        |> Map.merge(health_attrs)
    end
  end

  defp read_source_manifest(repo_path, manifest_path) do
    manifest_full_path = Path.join(repo_path, manifest_path)

    if File.regular?(manifest_full_path) do
      manifest_full_path
      |> File.read()
      |> case do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, manifest} when is_map(manifest) -> {:ok, manifest}
            {:ok, _value} -> {:error, "Manifest root must be a JSON object."}
            {:error, error} -> {:error, Exception.message(error)}
          end

        {:error, reason} ->
          {:error, "Could not read manifest: #{reason}"}
      end
    else
      {:missing, manifest_full_path}
    end
  end

  defp source_manifest_attrs(manifest) do
    agent_contract = map_value(manifest, "agent_contract")
    sqlite = map_value(manifest, "sqlite")

    %{
      "kind" => string_value(manifest, "kind") || "product_demand_repo",
      "display_name" => string_value(manifest, "display_name"),
      "description" => string_value(manifest, "description"),
      "manifest_schema_version" => integer_value(manifest, "schema_version"),
      "lanes" => list_value(manifest, "lanes"),
      "agent_entrypoint" => string_value(agent_contract, "entrypoint") || "AGENTS.md",
      "agent_required" => boolean_value(agent_contract, "required", true),
      "skill_policy" => string_value(agent_contract, "skill_policy"),
      "required_skills" => list_value(agent_contract, "required_skills"),
      "optional_skills" => list_value(agent_contract, "optional_skills"),
      "read_order" => list_value(manifest, "read_order"),
      "write_targets" => map_value(manifest, "write_targets"),
      "sqlite_path" => string_value(sqlite, "path"),
      "sqlite_mode" => string_value(sqlite, "mode"),
      "sqlite_owner" => string_value(sqlite, "owner"),
      "sqlite_schema_path" => string_value(sqlite, "schema_path"),
      "sqlite_migrations_path" => string_value(sqlite, "migrations_path"),
      "sqlite_allowed_operations" => list_value(sqlite, "allowed_operations"),
      "payload" => %{"manifest" => manifest}
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, []] end)
    |> Map.new()
  end

  defp source_health_attrs(repo_path, git_repo?, manifest_attrs) do
    agent_entrypoint = Map.get(manifest_attrs, "agent_entrypoint") || "AGENTS.md"
    agent_required = Map.get(manifest_attrs, "agent_required", true)
    sqlite_mode = Map.get(manifest_attrs, "sqlite_mode")
    sqlite_path = Map.get(manifest_attrs, "sqlite_path")
    write_targets = Map.get(manifest_attrs, "write_targets", %{})

    missing_agent_paths =
      if agent_required and not File.regular?(Path.join(repo_path, agent_entrypoint)) do
        [Path.join(repo_path, agent_entrypoint)]
      else
        []
      end

    missing_sqlite_paths = missing_sqlite_paths(repo_path, sqlite_mode, sqlite_path)
    invalid_sqlite_paths = invalid_sqlite_paths(repo_path, sqlite_mode, sqlite_path)
    missing_write_target_paths = missing_write_target_paths(repo_path, write_targets)

    health_state =
      cond do
        not git_repo? -> "not_git"
        missing_agent_paths != [] -> "agents_missing"
        missing_sqlite_paths != [] -> "sqlite_missing"
        invalid_sqlite_paths != [] -> "sqlite_invalid"
        missing_write_target_paths != [] -> "invalid_structure"
        true -> "healthy"
      end

    %{
      "health_state" => health_state,
      "health_summary" => source_health_summary(health_state),
      "missing_paths" =>
        missing_agent_paths ++ missing_sqlite_paths ++ missing_write_target_paths,
      "parse_errors" => []
    }
  end

  defp missing_sqlite_paths(repo_path, "required", nil),
    do: [Path.join(repo_path, "demand.sqlite3")]

  defp missing_sqlite_paths(repo_path, "required", sqlite_path) do
    full_path = Path.join(repo_path, sqlite_path)
    if File.exists?(full_path), do: [], else: [full_path]
  end

  defp missing_sqlite_paths(_repo_path, _mode, _sqlite_path), do: []

  defp invalid_sqlite_paths(repo_path, "required", sqlite_path) when is_binary(sqlite_path) do
    full_path = Path.join(repo_path, sqlite_path)

    if File.exists?(full_path) and not File.regular?(full_path) do
      [full_path]
    else
      []
    end
  end

  defp invalid_sqlite_paths(_repo_path, _mode, _sqlite_path), do: []

  defp missing_write_target_paths(repo_path, write_targets) when is_map(write_targets) do
    write_targets
    |> Map.values()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.join(repo_path, &1))
    |> Enum.reject(&File.dir?/1)
  end

  defp missing_write_target_paths(_repo_path, _write_targets), do: []

  defp source_health_summary("healthy"), do: "Source repo contract is readable."
  defp source_health_summary("missing"), do: "Source path is missing."
  defp source_health_summary("not_git"), do: "Path exists but is not a git repository."
  defp source_health_summary("manifest_missing"), do: "Manifest is missing."
  defp source_health_summary("invalid_manifest"), do: "Manifest is invalid."
  defp source_health_summary("invalid_structure"), do: "Configured source paths are missing."
  defp source_health_summary("agents_missing"), do: "Required AGENTS.md entrypoint is missing."

  defp source_health_summary("sqlite_missing"),
    do: "Required repo-local SQLite database is missing."

  defp source_health_summary("sqlite_invalid"),
    do: "Configured SQLite path is not a database file."

  defp source_health_summary("skills_unavailable"), do: "Required skills are unavailable."
  defp source_health_summary(_health_state), do: "Source health is unknown."

  defp source_health_summary("manifest_missing", %{"payload" => %{"legacy_adapter" => legacy}}) do
    "Manifest is missing; detected #{legacy["label"]} with #{legacy["confidence"]} confidence."
  end

  defp source_health_summary(health_state, _legacy_attrs), do: source_health_summary(health_state)

  defp legacy_layout_attrs(repo_path) do
    repo_path
    |> detect_legacy_layouts()
    |> case do
      nil -> %{}
      legacy -> %{"payload" => %{"legacy_adapter" => legacy}}
    end
  end

  defp detect_legacy_layouts(repo_path) do
    [
      legacy_layout(
        repo_path,
        "legacy_app_ideas",
        "Legacy AppIdeas",
        ~w(README.md config daily evidence reports memory templates)
      ),
      legacy_layout(
        repo_path,
        "legacy_game_ideas",
        "Legacy GameIdeas",
        ~w(README.md AGENTS.md market ideas templates)
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1["matched_count"], :desc)
    |> List.first()
  end

  defp legacy_layout(repo_path, kind, label, paths) do
    matched_paths = Enum.filter(paths, &File.exists?(Path.join(repo_path, &1)))
    matched_count = length(matched_paths)

    if matched_count >= 3 do
      %{
        "kind" => kind,
        "label" => label,
        "confidence" => legacy_confidence(matched_count, length(paths)),
        "matched_paths" => matched_paths,
        "matched_count" => matched_count
      }
    end
  end

  defp legacy_confidence(matched_count, total_count) do
    ratio = matched_count / total_count

    cond do
      ratio >= 0.75 -> "high"
      ratio >= 0.5 -> "medium"
      true -> "low"
    end
  end

  defp map_value(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_map(value) -> value
      _value -> %{}
    end
  end

  defp map_value(_map, _key), do: %{}

  defp string_value(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) -> Factory.trim_nil(value)
      _value -> nil
    end
  end

  defp string_value(_map, _key), do: nil

  defp integer_value(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _value -> nil
    end
  end

  defp integer_value(_map, _key), do: nil

  defp boolean_value(map, key, default) when is_map(map) do
    case Map.get(map, key) do
      value when is_boolean(value) -> value
      _value -> default
    end
  end

  defp boolean_value(_map, _key, default), do: default

  defp list_value(map, key) when is_map(map) do
    case Map.get(map, key) do
      values when is_list(values) ->
        values
        |> Enum.map(&to_string/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&Factory.blank?/1)

      value when is_binary(value) ->
        Factory.lines_to_list(value)

      _value ->
        []
    end
  end

  defp list_value(_map, _key), do: []
end
