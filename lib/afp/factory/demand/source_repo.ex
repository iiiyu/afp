# @input  - Demand source repo paths, manifests, schedules, and health inspection output
# @output - AFP-owned source repo control-plane records
# @pos    - Source repository contract boundary for upstream demand discovery
defmodule Afp.Factory.Demand.SourceRepo do
  use Afp.Factory.Schema

  alias Afp.Factory
  alias Afp.Factory.JsonData

  schema "demand_source_repos" do
    field :repo_path, :string
    field :display_name, :string
    field :kind, :string, default: "product_demand_repo"
    field :description, :string
    field :manifest_path, :string, default: "afp-demand-source.json"
    field :manifest_schema_version, :integer
    field :lanes, {:array, :string}, default: []
    field :agent_entrypoint, :string, default: "AGENTS.md"
    field :agent_required, :boolean, default: true
    field :skill_policy, :string
    field :required_skills, {:array, :string}, default: []
    field :optional_skills, {:array, :string}, default: []
    field :read_order, {:array, :string}, default: []
    field :write_targets, JsonData, default: %{}
    field :sqlite_path, :string
    field :sqlite_mode, :string
    field :sqlite_owner, :string
    field :sqlite_schema_path, :string
    field :sqlite_migrations_path, :string
    field :sqlite_allowed_operations, {:array, :string}, default: []
    field :schedule_enabled, :boolean, default: false
    field :schedule_interval_hours, :integer, default: 12
    field :health_state, :string, default: "unknown"
    field :health_summary, :string
    field :missing_paths, {:array, :string}, default: []
    field :parse_errors, {:array, :string}, default: []
    field :latest_scan_at, :utc_datetime_usec
    field :latest_index_at, :utc_datetime_usec
    field :last_run_at, :utc_datetime_usec
    field :payload, JsonData, default: %{}

    has_many :candidates, Afp.Factory.Demand.Candidate, foreign_key: :demand_source_repo_id
    has_many :research_runs, Afp.Factory.Demand.ResearchRun, foreign_key: :demand_source_repo_id

    timestamps()
  end

  def changeset(source_repo, attrs) do
    attrs = normalize_attrs(attrs)

    source_repo
    |> cast(attrs, [
      :repo_path,
      :display_name,
      :kind,
      :description,
      :manifest_path,
      :manifest_schema_version,
      :lanes,
      :agent_entrypoint,
      :agent_required,
      :skill_policy,
      :required_skills,
      :optional_skills,
      :read_order,
      :write_targets,
      :sqlite_path,
      :sqlite_mode,
      :sqlite_owner,
      :sqlite_schema_path,
      :sqlite_migrations_path,
      :sqlite_allowed_operations,
      :schedule_enabled,
      :schedule_interval_hours,
      :health_state,
      :health_summary,
      :missing_paths,
      :parse_errors,
      :latest_scan_at,
      :latest_index_at,
      :last_run_at,
      :payload
    ])
    |> normalize_text_fields([
      :repo_path,
      :display_name,
      :kind,
      :description,
      :manifest_path,
      :agent_entrypoint,
      :skill_policy,
      :sqlite_path,
      :sqlite_mode,
      :sqlite_owner,
      :sqlite_schema_path,
      :sqlite_migrations_path,
      :health_state,
      :health_summary
    ])
    |> put_default(:kind, "product_demand_repo")
    |> put_default(
      :display_name,
      display_name_from_path(get_field(source_repo_changeset_stub(attrs), :repo_path))
    )
    |> put_default(:manifest_path, "afp-demand-source.json")
    |> put_default(:agent_entrypoint, "AGENTS.md")
    |> put_default(:agent_required, true)
    |> put_default(:schedule_enabled, false)
    |> put_default(:schedule_interval_hours, 12)
    |> put_default(:health_state, "unknown")
    |> put_default(:lanes, ["app", "game"])
    |> validate_required([
      :repo_path,
      :display_name,
      :kind,
      :manifest_path,
      :agent_entrypoint,
      :health_state,
      :schedule_interval_hours
    ])
    |> validate_subset(:lanes, Factory.demand_lanes())
    |> validate_inclusion(:health_state, Factory.demand_source_health_states())
    |> validate_number(:schedule_interval_hours, greater_than: 0)
    |> unique_constraint(:repo_path)
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    attrs
    |> normalize_path(:repo_path)
    |> normalize_lines(:lanes)
    |> normalize_lines(:required_skills)
    |> normalize_lines(:optional_skills)
    |> normalize_lines(:read_order)
    |> normalize_lines(:sqlite_allowed_operations)
    |> normalize_lines(:missing_paths)
    |> normalize_lines(:parse_errors)
  end

  defp normalize_attrs(attrs), do: attrs

  defp normalize_path(attrs, field) do
    value = Map.get(attrs, Atom.to_string(field)) || Map.get(attrs, field)

    if is_binary(value) and Factory.present?(value) do
      put_existing(attrs, field, Factory.expand_path(value))
    else
      attrs
    end
  end

  defp normalize_lines(attrs, field) do
    value = Map.get(attrs, Atom.to_string(field)) || Map.get(attrs, field)

    if is_binary(value) do
      put_existing(attrs, field, Factory.lines_to_list(value))
    else
      attrs
    end
  end

  defp normalize_text_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      value = get_change(acc, field)

      if is_binary(value) do
        put_change(acc, field, Factory.trim_nil(value))
      else
        acc
      end
    end)
  end

  defp put_default(changeset, field, default) do
    if Factory.blank?(get_field(changeset, field)) do
      put_change(changeset, field, default)
    else
      changeset
    end
  end

  defp display_name_from_path(path) when is_binary(path),
    do: path |> Path.basename() |> Factory.labelize()

  defp display_name_from_path(_path), do: "Demand Source"

  defp source_repo_changeset_stub(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:repo_path])
    |> normalize_text_fields([:repo_path])
  end

  defp put_existing(attrs, field, value) do
    string_key = Atom.to_string(field)

    cond do
      Map.has_key?(attrs, string_key) -> Map.put(attrs, string_key, value)
      Map.has_key?(attrs, field) -> Map.put(attrs, field, value)
      true -> attrs
    end
  end
end
