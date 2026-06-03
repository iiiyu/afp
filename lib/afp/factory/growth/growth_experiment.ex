# @input  - Growth experiment params, review cadence, and outcome notes
# @output - Persisted growth experiment records per app
# @pos    - Schema for manual post-launch business experiments
defmodule Afp.Factory.Growth.GrowthExperiment do
  use Afp.Factory.Schema

  alias Afp.Factory
  alias Afp.Factory.JsonData

  schema "growth_experiments" do
    field :title, :string
    field :hypothesis, :string
    field :metric, :string
    field :status, :string, default: "idea"
    field :priority, :string, default: "normal"
    field :started_at, :utc_datetime_usec
    field :review_due_on, :date
    field :ended_at, :utc_datetime_usec
    field :outcome_note, :string
    field :payload, JsonData, default: %{}

    belongs_to :app, Afp.Factory.Portfolio.App

    timestamps()
  end

  def changeset(experiment, attrs) do
    experiment
    |> cast(attrs, [
      :app_id,
      :title,
      :hypothesis,
      :metric,
      :status,
      :priority,
      :started_at,
      :review_due_on,
      :ended_at,
      :outcome_note,
      :payload
    ])
    |> normalize_text_fields([:title, :hypothesis, :metric, :status, :priority, :outcome_note])
    |> put_default(:status, "idea")
    |> put_default(:priority, "normal")
    |> validate_required([:app_id, :title, :status, :priority])
    |> validate_inclusion(:status, Factory.experiment_statuses())
    |> validate_inclusion(:priority, Factory.priorities())
    |> validate_terminal_note()
    |> foreign_key_constraint(:app_id)
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

  defp validate_terminal_note(changeset) do
    status = get_field(changeset, :status)
    outcome_note = get_field(changeset, :outcome_note)

    if status in ["won", "lost", "dropped"] and Factory.blank?(outcome_note) do
      add_error(changeset, :outcome_note, "is required when closing an experiment")
    else
      changeset
    end
  end
end
