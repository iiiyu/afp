# @input  - App-owned work item fields and manual review decisions
# @output - Lightweight ticket records for app-factory workflow
# @pos    - Work schema separating ticket state from app lifecycle and session state
defmodule Afp.Factory.Work.Ticket do
  use Afp.Factory.Schema

  alias Afp.Factory

  schema "tickets" do
    field :title, :string
    field :description, :string
    field :status, :string, default: "backlog"
    field :lifecycle_gate, :string
    field :priority, :string, default: "normal"
    field :risk_level, :string, default: "normal"
    field :blocked_reason, :string
    field :review_note, :string
    field :done_at, :utc_datetime_usec
    field :dropped_at, :utc_datetime_usec

    belongs_to :app, Afp.Factory.Portfolio.App
    has_many :harness_packets, Afp.Factory.Work.HarnessPacket
    has_many :ticket_session_links, Afp.Factory.Sessions.TicketSessionLink
    has_many :codex_sessions, through: [:ticket_session_links, :codex_session]

    timestamps()
  end

  def changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [
      :app_id,
      :title,
      :description,
      :status,
      :lifecycle_gate,
      :priority,
      :risk_level,
      :blocked_reason,
      :review_note,
      :done_at,
      :dropped_at
    ])
    |> normalize_text_fields([
      :title,
      :description,
      :lifecycle_gate,
      :blocked_reason,
      :review_note
    ])
    |> put_default(:status, "backlog")
    |> put_default(:priority, "normal")
    |> put_default(:risk_level, "normal")
    |> validate_required([:app_id, :title, :status, :priority, :risk_level])
    |> validate_inclusion(:status, Factory.ticket_statuses())
    |> validate_inclusion(:priority, Factory.priorities())
    |> validate_inclusion(:risk_level, Factory.risk_levels())
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
end
