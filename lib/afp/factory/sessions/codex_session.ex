# @input  - Codex hook/session fields, repository cwd, and manual review state
# @output - Codex session records linked to apps and optional tickets
# @pos    - Session bridge schema for observed Codex work
defmodule Afp.Factory.Sessions.CodexSession do
  use Afp.Factory.Schema

  alias Afp.Factory

  schema "codex_sessions" do
    field :external_session_id, :string
    field :cwd, :string
    field :model, :string
    field :status, :string, default: "detected"
    field :transcript_path, :string
    field :latest_turn_id, :string
    field :summary, :string
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :stopped_at, :utc_datetime_usec
    field :reviewed_at, :utc_datetime_usec
    field :ignored_at, :utc_datetime_usec

    belongs_to :app, Afp.Factory.Portfolio.App
    has_many :ticket_session_links, Afp.Factory.Sessions.TicketSessionLink
    has_many :tickets, through: [:ticket_session_links, :ticket]

    timestamps()
  end

  def changeset(codex_session, attrs) do
    codex_session
    |> cast(attrs, [
      :external_session_id,
      :app_id,
      :cwd,
      :model,
      :status,
      :transcript_path,
      :latest_turn_id,
      :summary,
      :first_seen_at,
      :last_seen_at,
      :stopped_at,
      :reviewed_at,
      :ignored_at
    ])
    |> validate_required([:external_session_id, :status])
    |> validate_inclusion(:status, Factory.session_statuses())
    |> unique_constraint(:external_session_id)
    |> foreign_key_constraint(:app_id)
  end
end
