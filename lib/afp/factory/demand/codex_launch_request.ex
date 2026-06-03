# @input  - Demand, app, ticket, release, and manual Codex launch params
# @output - Human-confirmed Codex launch request records and handoff text
# @pos    - Bounded launch-contract schema before direct Codex integration
defmodule Afp.Factory.Demand.CodexLaunchRequest do
  use Afp.Factory.Schema

  alias Afp.Factory

  schema "codex_launch_requests" do
    field :source_type, :string
    field :source_id, :binary_id
    field :title, :string
    field :objective, :string
    field :context, :string
    field :risk_level, :string, default: "normal"
    field :launch_mode, :string, default: "manual_handoff"
    field :status, :string, default: "draft"
    field :confirmation, :string
    field :handoff_text, :string
    field :launched_at, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec

    belongs_to :demand_item, Afp.Factory.Demand.DemandItem
    belongs_to :app, Afp.Factory.Portfolio.App
    belongs_to :ticket, Afp.Factory.Work.Ticket
    belongs_to :release_target, Afp.Factory.Releases.ReleaseTarget

    timestamps()
  end

  def changeset(launch_request, attrs) do
    launch_request
    |> cast(attrs, [
      :demand_item_id,
      :app_id,
      :ticket_id,
      :release_target_id,
      :source_type,
      :source_id,
      :title,
      :objective,
      :context,
      :risk_level,
      :launch_mode,
      :status,
      :confirmation,
      :handoff_text,
      :launched_at,
      :cancelled_at
    ])
    |> normalize_text_fields([
      :source_type,
      :title,
      :objective,
      :context,
      :confirmation,
      :handoff_text
    ])
    |> put_default(:risk_level, "normal")
    |> put_default(:launch_mode, "manual_handoff")
    |> put_default(:status, "draft")
    |> validate_required([:source_type, :title, :objective, :risk_level, :launch_mode, :status])
    |> validate_inclusion(:risk_level, Factory.risk_levels())
    |> validate_inclusion(:launch_mode, Factory.launch_modes())
    |> validate_inclusion(:status, Factory.launch_request_statuses())
    |> validate_confirmation_for_high_risk()
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

  defp validate_confirmation_for_high_risk(changeset) do
    risk_level = get_field(changeset, :risk_level)
    status = get_field(changeset, :status)

    if risk_level in ["high", "critical"] and status in ["ready", "launched"] do
      validate_required(changeset, [:confirmation])
    else
      changeset
    end
  end
end
