# @input  - Ticket/app context, constraints, verification, and review route fields
# @output - Harness packet records that define executable work contracts
# @pos    - Work-contract schema used before Codex or human execution starts
defmodule Afp.Factory.Work.HarnessPacket do
  use Afp.Factory.Schema

  alias Afp.Factory
  alias Afp.Factory.JsonData

  schema "harness_packets" do
    field :state, :string, default: "draft"
    field :objective, :string
    field :repository_path, :string
    field :lifecycle_gate, :string
    field :context_inputs, JsonData, default: %{}
    field :constraints, JsonData, default: %{}
    field :non_goals, JsonData, default: []
    field :allowed_tools, JsonData, default: []
    field :risk_level, :string, default: "normal"
    field :expected_output, :string
    field :verification_plan, JsonData, default: %{}
    field :required_evidence, JsonData, default: []
    field :approval_points, JsonData, default: []
    field :launch_mode, :string, default: "manual"
    field :review_route, :string
    field :result_summary, :string
    field :next_route, :string
    field :superseded_at, :utc_datetime_usec

    belongs_to :app, Afp.Factory.Portfolio.App
    belongs_to :ticket, Afp.Factory.Work.Ticket
    belongs_to :release_target, Afp.Factory.Releases.ReleaseTarget

    timestamps()
  end

  def changeset(packet, attrs) do
    attrs = normalize_attrs(attrs)

    packet
    |> cast(attrs, [
      :app_id,
      :ticket_id,
      :release_target_id,
      :state,
      :objective,
      :repository_path,
      :lifecycle_gate,
      :context_inputs,
      :constraints,
      :non_goals,
      :allowed_tools,
      :risk_level,
      :expected_output,
      :verification_plan,
      :required_evidence,
      :approval_points,
      :launch_mode,
      :review_route,
      :result_summary,
      :next_route,
      :superseded_at
    ])
    |> normalize_text_fields([
      :objective,
      :repository_path,
      :lifecycle_gate,
      :expected_output,
      :review_route,
      :result_summary,
      :next_route
    ])
    |> put_default(:state, "draft")
    |> put_default(:risk_level, "normal")
    |> put_default(:launch_mode, "manual")
    |> validate_required([:app_id, :objective, :state, :risk_level, :launch_mode])
    |> validate_inclusion(:state, Factory.packet_states())
    |> validate_inclusion(:risk_level, Factory.risk_levels())
    |> validate_ready_requirements()
    |> foreign_key_constraint(:app_id)
    |> foreign_key_constraint(:ticket_id)
    |> foreign_key_constraint(:release_target_id)
  end

  def ready_changeset(packet, attrs) do
    packet
    |> changeset(Map.put(attrs, "state", "ready"))
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    attrs
    |> normalize_jsonish_field(:context_inputs, :map)
    |> normalize_jsonish_field(:constraints, :map)
    |> normalize_jsonish_field(:verification_plan, :map)
    |> normalize_jsonish_field(:non_goals, :list)
    |> normalize_jsonish_field(:allowed_tools, :list)
    |> normalize_jsonish_field(:required_evidence, :list)
    |> normalize_jsonish_field(:approval_points, :list)
  end

  defp normalize_attrs(attrs), do: attrs

  defp normalize_jsonish_field(attrs, field, kind) do
    string_key = Atom.to_string(field)
    value = Map.get(attrs, string_key) || Map.get(attrs, field)

    normalized =
      case {value, kind} do
        {value, _kind} when is_map(value) or is_list(value) ->
          value

        {value, :list} when is_binary(value) ->
          decode_or_lines(value)

        {value, :map} when is_binary(value) ->
          decode_or_summary(value)

        {_value, :list} ->
          []

        {_value, :map} ->
          %{}
      end

    cond do
      Map.has_key?(attrs, string_key) -> Map.put(attrs, string_key, normalized)
      Map.has_key?(attrs, field) -> Map.put(attrs, field, normalized)
      true -> attrs
    end
  end

  defp decode_or_lines(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _error} -> Factory.lines_to_list(value)
    end
  end

  defp decode_or_summary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _error} -> %{"summary" => value}
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

  defp validate_ready_requirements(changeset) do
    if get_field(changeset, :state) == "ready" do
      validate_required(changeset, [:app_id, :objective, :expected_output, :review_route])
    else
      changeset
    end
  end
end
