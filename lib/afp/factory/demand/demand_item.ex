# @input  - Pre-app opportunity fields, validation notes, and promotion links
# @output - Demand item records that can exist before an app or repository
# @pos    - Demand-management schema before app lifecycle ownership begins
defmodule Afp.Factory.Demand.DemandItem do
  use Afp.Factory.Schema

  alias Afp.Factory

  schema "demand_items" do
    field :title, :string
    field :status, :string, default: "captured"
    field :source, :string
    field :source_url, :string
    field :target_user, :string
    field :job_to_be_done, :string
    field :demand_signal, :string
    field :incumbent_weakness, :string
    field :wedge_hypothesis, :string
    field :validation_action, :string
    field :evidence_summary, :string
    field :confidence, :string, default: "unknown"
    field :promoted_at, :utc_datetime_usec
    field :rejected_reason, :string
    field :parked_reason, :string

    belongs_to :promoted_app, Afp.Factory.Portfolio.App
    has_many :launch_requests, Afp.Factory.Demand.CodexLaunchRequest

    timestamps()
  end

  def changeset(demand_item, attrs) do
    demand_item
    |> cast(attrs, [
      :title,
      :status,
      :source,
      :source_url,
      :target_user,
      :job_to_be_done,
      :demand_signal,
      :incumbent_weakness,
      :wedge_hypothesis,
      :validation_action,
      :evidence_summary,
      :confidence,
      :promoted_app_id,
      :promoted_at,
      :rejected_reason,
      :parked_reason
    ])
    |> normalize_text_fields([
      :title,
      :source,
      :source_url,
      :target_user,
      :job_to_be_done,
      :demand_signal,
      :incumbent_weakness,
      :wedge_hypothesis,
      :validation_action,
      :evidence_summary,
      :rejected_reason,
      :parked_reason
    ])
    |> put_default(:status, "captured")
    |> put_default(:confidence, "unknown")
    |> validate_required([:title, :status, :validation_action, :confidence])
    |> validate_inclusion(:status, Factory.demand_statuses())
    |> validate_inclusion(:confidence, Factory.demand_confidences())
    |> validate_reason_for_terminal_status()
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

  defp validate_reason_for_terminal_status(changeset) do
    case get_field(changeset, :status) do
      "rejected" -> validate_required(changeset, [:rejected_reason])
      "parked" -> validate_required(changeset, [:parked_reason])
      _status -> changeset
    end
  end
end
