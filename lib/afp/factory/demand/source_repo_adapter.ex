# @input  - Manifest-declared demand source repo paths and repo-local SQLite data
# @output - Normalized candidate attrs read from source-owned SQLite databases
# @pos    - Adapter boundary between AFP orchestration and demand repo structured data
defmodule Afp.Factory.Demand.SourceRepoAdapter do
  alias Afp.Factory
  alias Afp.Factory.Demand.SourceRepo
  alias Afp.Factory.RepoSqlite

  @read_operations ~w(read_index read_candidates)

  @candidate_aliases %{
    external_id: ~w(external_id candidate_id id slug key),
    lane: ~w(lane kind product_lane),
    title: ~w(title name),
    source_status: ~w(source_status status state),
    score: ~w(score total_score weighted_score),
    confidence: ~w(confidence confidence_level),
    target_user: ~w(target_user target_user_job user_segment audience),
    demand_signal: ~w(demand_signal signal demand_evidence),
    incumbent_weakness: ~w(incumbent_weakness weakness),
    wedge_hypothesis: ~w(wedge_hypothesis wedge hypothesis),
    validation_action: ~w(validation_action next_validation_action next_action),
    primary_path: ~w(primary_path path markdown_path candidate_path),
    report_path: ~w(report_path current_report_path),
    package_path: ~w(package_path current_package_path),
    evidence_paths: ~w(evidence_paths evidence_path),
    observed_at: ~w(observed_at last_observed_at updated_on inserted_on),
    limitations: ~w(limitations limitation notes)
  }

  def read_candidates(%SourceRepo{} = source_repo) do
    with :ok <- ensure_read_operation_allowed(source_repo),
         {:ok, columns} <- candidate_columns(source_repo),
         :ok <- ensure_candidate_columns(columns),
         {:ok, rows} <- sqlite_json(source_repo, candidate_select_sql(columns)) do
      {:ok, Enum.map(rows, &candidate_attrs/1)}
    end
  end

  defp ensure_read_operation_allowed(%SourceRepo{} = source_repo) do
    if Enum.any?(@read_operations, &(&1 in source_repo.sqlite_allowed_operations)) do
      :ok
    else
      {:error, :read_operation_not_allowed}
    end
  end

  defp candidate_columns(%SourceRepo{} = source_repo) do
    case sqlite_json(source_repo, "PRAGMA table_info(candidates)") do
      {:ok, rows} -> {:ok, Enum.map(rows, &Map.get(&1, "name"))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_candidate_columns(columns) do
    cond do
      columns == [] ->
        {:error, :candidates_table_missing}

      find_column(columns, @candidate_aliases.external_id) == nil ->
        {:error, {:missing_columns, ["external_id"]}}

      find_column(columns, @candidate_aliases.title) == nil ->
        {:error, {:missing_columns, ["title"]}}

      true ->
        :ok
    end
  end

  defp candidate_select_sql(columns) do
    selects = [
      select_expr(columns, @candidate_aliases.external_id, "external_id"),
      select_expr(columns, @candidate_aliases.lane, "lane", "'app'"),
      select_expr(columns, @candidate_aliases.title, "title"),
      select_expr(columns, @candidate_aliases.source_status, "source_status", "'new'"),
      select_expr(columns, @candidate_aliases.score, "score"),
      select_expr(columns, @candidate_aliases.confidence, "confidence", "'unknown'"),
      select_expr(columns, @candidate_aliases.target_user, "target_user"),
      select_expr(columns, @candidate_aliases.demand_signal, "demand_signal"),
      select_expr(columns, @candidate_aliases.incumbent_weakness, "incumbent_weakness"),
      select_expr(columns, @candidate_aliases.wedge_hypothesis, "wedge_hypothesis"),
      select_expr(columns, @candidate_aliases.validation_action, "validation_action"),
      select_expr(columns, @candidate_aliases.primary_path, "primary_path"),
      select_expr(columns, @candidate_aliases.report_path, "report_path"),
      select_expr(columns, @candidate_aliases.package_path, "package_path"),
      select_expr(columns, @candidate_aliases.evidence_paths, "evidence_paths"),
      select_expr(columns, @candidate_aliases.observed_at, "observed_at"),
      select_expr(columns, @candidate_aliases.limitations, "limitations")
    ]

    "SELECT #{Enum.join(selects, ", ")} FROM candidates"
  end

  defp select_expr(columns, aliases, output_name, default \\ "NULL") do
    case find_column(columns, aliases) do
      nil -> "#{default} AS #{quote_identifier(output_name)}"
      column -> "#{quote_identifier(column)} AS #{quote_identifier(output_name)}"
    end
  end

  defp find_column(columns, aliases) do
    Enum.find(aliases, &(&1 in columns))
  end

  defp candidate_attrs(row) do
    source_status = normalize_source_status(Map.get(row, "source_status"))
    confidence = normalize_confidence(Map.get(row, "confidence"))
    raw_row = row

    row
    |> Map.take([
      "external_id",
      "lane",
      "title",
      "score",
      "target_user",
      "demand_signal",
      "incumbent_weakness",
      "wedge_hypothesis",
      "validation_action",
      "primary_path",
      "report_path",
      "package_path",
      "evidence_paths",
      "observed_at",
      "limitations"
    ])
    |> Map.put("source_status", source_status)
    |> Map.put("confidence", confidence)
    |> Map.put("payload", %{"sqlite_row" => raw_row})
    |> drop_blank_values()
  end

  defp normalize_source_status(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.downcase()
      |> String.replace("_", "-")

    if normalized in Factory.demand_candidate_source_statuses(), do: normalized, else: "new"
  end

  defp normalize_source_status(_value), do: "new"

  defp normalize_confidence(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    cond do
      normalized in Factory.demand_confidences() -> normalized
      String.starts_with?(normalized, "high") -> "high"
      String.starts_with?(normalized, "medium") -> "medium"
      String.starts_with?(normalized, "low") -> "low"
      true -> "unknown"
    end
  end

  defp normalize_confidence(_value), do: "unknown"

  defp drop_blank_values(attrs) do
    attrs
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp sqlite_json(%SourceRepo{} = source_repo, sql) do
    source_repo.repo_path
    |> Path.join(source_repo.sqlite_path || "demand.sqlite3")
    |> RepoSqlite.query(sql)
  end

  defp quote_identifier(identifier) do
    escaped = String.replace(identifier, "\"", "\"\"")
    "\"#{escaped}\""
  end
end
