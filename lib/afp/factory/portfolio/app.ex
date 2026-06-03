# @input  - App inventory params, repository paths, lifecycle and business states
# @output - Portfolio app records with validated lifecycle metadata
# @pos    - Core product schema for app-factory lifecycle state
defmodule Afp.Factory.Portfolio.App do
  use Afp.Factory.Schema

  alias Afp.Factory
  alias Afp.Factory.JsonData

  schema "apps" do
    field :name, :string
    field :slug, :string
    field :repo_path, :string
    field :platforms, {:array, :string}, default: []
    field :lifecycle_stage, :string, default: "idea"
    field :business_posture, :string, default: "unknown"
    field :health_state, :string, default: "unknown"
    field :product_thesis, JsonData, default: %{}
    field :next_action, :string
    field :current_version, :string
    field :current_build, :string
    field :last_activity_at, :utc_datetime_usec
    field :paused_reason, :string
    field :archived_at, :utc_datetime_usec

    has_many :tickets, Afp.Factory.Work.Ticket
    has_many :harness_packets, Afp.Factory.Work.HarnessPacket
    has_many :codex_sessions, Afp.Factory.Sessions.CodexSession
    has_many :evidence_packets, Afp.Factory.Evidence.EvidencePacket
    has_many :release_targets, Afp.Factory.Releases.ReleaseTarget
    has_many :metrics_snapshots, Afp.Factory.Metrics.MetricsSnapshot

    timestamps()
  end

  def changeset(app, attrs) do
    attrs = normalize_attrs(attrs)

    app
    |> cast(attrs, [
      :name,
      :slug,
      :repo_path,
      :platforms,
      :lifecycle_stage,
      :business_posture,
      :health_state,
      :product_thesis,
      :next_action,
      :current_version,
      :current_build,
      :last_activity_at,
      :paused_reason,
      :archived_at
    ])
    |> normalize_text_fields([
      :name,
      :slug,
      :repo_path,
      :next_action,
      :current_version,
      :current_build
    ])
    |> put_default(:lifecycle_stage, "idea")
    |> put_default(:business_posture, "unknown")
    |> put_slug()
    |> put_health_state()
    |> validate_required([:name, :slug, :lifecycle_stage, :business_posture, :health_state])
    |> validate_inclusion(:lifecycle_stage, Factory.lifecycle_stages())
    |> validate_inclusion(:business_posture, Factory.business_postures())
    |> validate_inclusion(:health_state, Factory.health_states())
    |> unique_constraint(:slug)
    |> unique_constraint(:repo_path)
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    attrs
    |> normalize_platform_attrs()
    |> normalize_thesis_attrs()
  end

  defp normalize_attrs(attrs), do: attrs

  defp normalize_platform_attrs(%{} = attrs) do
    case Map.fetch(attrs, "platforms") do
      {:ok, platforms} -> Map.put(attrs, "platforms", Factory.normalize_platforms(platforms))
      :error -> normalize_atom_platform_attrs(attrs)
    end
  end

  defp normalize_atom_platform_attrs(attrs) do
    case Map.fetch(attrs, :platforms) do
      {:ok, platforms} -> Map.put(attrs, :platforms, Factory.normalize_platforms(platforms))
      :error -> attrs
    end
  end

  defp normalize_thesis_attrs(%{} = attrs) do
    value = Map.get(attrs, "product_thesis") || Map.get(attrs, :product_thesis)

    case value do
      value when is_binary(value) ->
        put_attr(attrs, :product_thesis, thesis_from_text(value))

      _value ->
        attrs
    end
  end

  defp thesis_from_text(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _error} -> %{"summary" => value}
    end
  end

  defp put_attr(attrs, atom_key, value) do
    if Map.has_key?(attrs, Atom.to_string(atom_key)) do
      Map.put(attrs, Atom.to_string(atom_key), value)
    else
      Map.put(attrs, atom_key, value)
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

  defp put_slug(changeset) do
    slug = get_field(changeset, :slug)
    name = get_field(changeset, :name)

    if Factory.blank?(slug) and Factory.present?(name) do
      put_change(changeset, :slug, Factory.slugify(name))
    else
      changeset
    end
  end

  defp put_health_state(changeset) do
    put_change(changeset, :health_state, computed_health_state(changeset))
  end

  defp computed_health_state(changeset) do
    lifecycle_stage = get_field(changeset, :lifecycle_stage)
    repo_path = get_field(changeset, :repo_path)
    next_action = get_field(changeset, :next_action)
    archived_at = get_field(changeset, :archived_at)

    cond do
      archived_at != nil or lifecycle_stage == "archived" ->
        "archived"

      Factory.present?(repo_path) and not File.dir?(Factory.expand_path(repo_path)) ->
        "repo_missing"

      lifecycle_stage not in ["idea", "paused", "archived"] and Factory.blank?(next_action) ->
        "needs_next_action"

      true ->
        "healthy"
    end
  end
end
