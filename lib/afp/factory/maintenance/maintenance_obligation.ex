# @input  - Maintenance obligation params, due dates, and completion notes
# @output - Persisted app maintenance obligations
# @pos    - Schema for post-launch maintenance and compliance queues
defmodule Afp.Factory.Maintenance.MaintenanceObligation do
  use Afp.Factory.Schema

  alias Afp.Factory
  alias Afp.Factory.JsonData

  schema "maintenance_obligations" do
    field :title, :string
    field :category, :string, default: "maintenance"
    field :status, :string, default: "open"
    field :priority, :string, default: "normal"
    field :due_on, :date
    field :recurrence, :string
    field :notes, :string
    field :completed_at, :utc_datetime_usec
    field :payload, JsonData, default: %{}

    belongs_to :app, Afp.Factory.Portfolio.App

    timestamps()
  end

  def changeset(obligation, attrs) do
    obligation
    |> cast(attrs, [
      :app_id,
      :title,
      :category,
      :status,
      :priority,
      :due_on,
      :recurrence,
      :notes,
      :completed_at,
      :payload
    ])
    |> normalize_text_fields([:title, :category, :status, :priority, :recurrence, :notes])
    |> put_default(:category, "maintenance")
    |> put_default(:status, "open")
    |> put_default(:priority, "normal")
    |> validate_required([:app_id, :title, :category, :status, :priority])
    |> validate_inclusion(:category, Factory.maintenance_categories())
    |> validate_inclusion(:status, Factory.maintenance_statuses())
    |> validate_inclusion(:priority, Factory.priorities())
    |> validate_completion_note()
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

  defp validate_completion_note(changeset) do
    if get_field(changeset, :status) == "done" and Factory.blank?(get_field(changeset, :notes)) do
      add_error(changeset, :notes, "is required when completing maintenance")
    else
      changeset
    end
  end
end
