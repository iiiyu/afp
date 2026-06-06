# @input  - Reusable launch and follow-up prompt templates
# @output - Validated message templates with explicit variables and safety notes
# @pos    - Human-editable Codex message template catalog for demand work
defmodule Afp.Factory.Demand.MessageTemplate do
  use Afp.Factory.Schema

  alias Afp.Factory
  alias Afp.Factory.JsonData

  schema "demand_message_templates" do
    field :name, :string
    field :purpose, :string
    field :default_run_type, :string, default: "manual_idea"
    field :default_lane, :string, default: "app"
    field :default_target, :string, default: "manual_handoff"
    field :required_variables, {:array, :string}, default: []
    field :body, :string
    field :safety_notes, :string
    field :expected_output_paths, {:array, :string}, default: []
    field :requires_confirmation, :boolean, default: true
    field :active, :boolean, default: true
    field :payload, JsonData, default: %{}

    has_many :research_runs, Afp.Factory.Demand.ResearchRun
    has_many :sent_messages, Afp.Factory.Demand.SentMessage

    timestamps()
  end

  def changeset(template, attrs) do
    attrs = normalize_attrs(attrs)

    template
    |> cast(attrs, [
      :name,
      :purpose,
      :default_run_type,
      :default_lane,
      :default_target,
      :required_variables,
      :body,
      :safety_notes,
      :expected_output_paths,
      :requires_confirmation,
      :active,
      :payload
    ])
    |> normalize_text_fields([
      :name,
      :purpose,
      :default_run_type,
      :default_lane,
      :default_target,
      :body,
      :safety_notes
    ])
    |> put_default(:default_run_type, "manual_idea")
    |> put_default(:default_lane, "app")
    |> put_default(:default_target, "manual_handoff")
    |> put_default(:requires_confirmation, true)
    |> put_default(:active, true)
    |> validate_required([
      :name,
      :default_run_type,
      :default_lane,
      :default_target,
      :body,
      :requires_confirmation,
      :active
    ])
    |> validate_inclusion(:default_run_type, Factory.demand_research_run_types())
    |> validate_inclusion(:default_lane, Factory.demand_lanes())
    |> validate_inclusion(:default_target, Factory.demand_message_targets())
    |> unique_constraint(:name)
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    attrs
    |> normalize_lines(:required_variables)
    |> normalize_lines(:expected_output_paths)
  end

  defp normalize_attrs(attrs), do: attrs

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

  defp put_existing(attrs, field, value) do
    string_key = Atom.to_string(field)

    cond do
      Map.has_key?(attrs, string_key) -> Map.put(attrs, string_key, value)
      Map.has_key?(attrs, field) -> Map.put(attrs, field, value)
      true -> attrs
    end
  end
end
