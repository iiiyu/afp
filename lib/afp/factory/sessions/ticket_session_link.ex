# @input  - Ticket IDs, Codex session IDs, and link reasons
# @output - Durable links between sessions and app-owned tickets
# @pos    - Join schema for session-to-ticket review and traceability
defmodule Afp.Factory.Sessions.TicketSessionLink do
  use Afp.Factory.Schema

  schema "ticket_session_links" do
    field :link_reason, :string

    belongs_to :ticket, Afp.Factory.Work.Ticket
    belongs_to :codex_session, Afp.Factory.Sessions.CodexSession

    timestamps(updated_at: false)
  end

  def changeset(ticket_session_link, attrs) do
    ticket_session_link
    |> cast(attrs, [:ticket_id, :codex_session_id, :link_reason])
    |> validate_required([:ticket_id, :codex_session_id])
    |> unique_constraint([:ticket_id, :codex_session_id])
    |> foreign_key_constraint(:ticket_id)
    |> foreign_key_constraint(:codex_session_id)
  end
end
