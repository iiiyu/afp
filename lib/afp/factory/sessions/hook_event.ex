# @input  - Raw Codex hook payloads and extracted event fields
# @output - Durable hook event rows preserved before processing
# @pos    - Intake schema for local HTTP receiver and JSONL spool imports
defmodule Afp.Factory.Sessions.HookEvent do
  use Afp.Factory.Schema

  alias Afp.Factory.JsonData

  schema "hook_events" do
    field :external_session_id, :string
    field :event_name, :string
    field :cwd, :string
    field :model, :string
    field :transcript_path, :string
    field :turn_id, :string
    field :payload, JsonData, default: %{}
    field :received_at, :utc_datetime_usec
    field :processed_at, :utc_datetime_usec
    field :processing_error, :string
  end

  def changeset(hook_event, attrs) do
    hook_event
    |> cast(attrs, [
      :external_session_id,
      :event_name,
      :cwd,
      :model,
      :transcript_path,
      :turn_id,
      :payload,
      :received_at,
      :processed_at,
      :processing_error
    ])
    |> validate_required([:event_name, :received_at])
  end
end
