# @input  - Factory subject identifiers and event payloads
# @output - Append-only event rows
# @pos    - Audit-log schema for state changes and integration intake
defmodule Afp.Factory.Events.Event do
  use Afp.Factory.Schema

  alias Afp.Factory.JsonData

  schema "events" do
    field :subject_type, :string
    field :subject_id, :binary_id
    field :event_type, :string
    field :payload, JsonData, default: %{}

    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:subject_type, :subject_id, :event_type, :payload])
    |> validate_required([:subject_type, :event_type])
  end
end
