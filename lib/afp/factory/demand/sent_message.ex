# @input  - Rendered and operator-edited Codex launch/follow-up messages
# @output - Auditable sent-message records tied to research runs and launch requests
# @pos    - Message history boundary for manual handoff and future Codex transport adapters
defmodule Afp.Factory.Demand.SentMessage do
  use Afp.Factory.Schema

  alias Afp.Factory
  alias Afp.Factory.JsonData

  schema "demand_sent_messages" do
    field :target, :string, default: "manual_handoff"
    field :status, :string, default: "draft"
    field :rendered_body, :string
    field :edited_body, :string
    field :confirmed_at, :utc_datetime_usec
    field :sent_at, :utc_datetime_usec
    field :failed_at, :utc_datetime_usec
    field :payload, JsonData, default: %{}

    belongs_to :research_run, Afp.Factory.Demand.ResearchRun, foreign_key: :demand_research_run_id
    belongs_to :message_template, Afp.Factory.Demand.MessageTemplate

    belongs_to :launch_request, Afp.Factory.Demand.CodexLaunchRequest,
      foreign_key: :codex_launch_request_id

    belongs_to :codex_session, Afp.Factory.Sessions.CodexSession

    timestamps()
  end

  def changeset(sent_message, attrs) do
    sent_message
    |> cast(attrs, [
      :demand_research_run_id,
      :message_template_id,
      :codex_launch_request_id,
      :codex_session_id,
      :target,
      :status,
      :rendered_body,
      :edited_body,
      :confirmed_at,
      :sent_at,
      :failed_at,
      :payload
    ])
    |> normalize_text_fields([:target, :status, :rendered_body, :edited_body])
    |> put_default(:target, "manual_handoff")
    |> put_default(:status, "draft")
    |> validate_required([:demand_research_run_id, :target, :status, :rendered_body])
    |> validate_inclusion(:target, Factory.demand_message_targets())
    |> validate_inclusion(:status, Factory.demand_sent_message_statuses())
    |> foreign_key_constraint(:demand_research_run_id)
    |> foreign_key_constraint(:message_template_id)
    |> foreign_key_constraint(:codex_launch_request_id)
    |> foreign_key_constraint(:codex_session_id)
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
