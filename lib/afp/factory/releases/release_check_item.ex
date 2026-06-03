# @input  - Release readiness checklist category, status, and waiver data
# @output - Checklist item rows attached to release targets
# @pos    - Release gating schema that blocks premature transitions
defmodule Afp.Factory.Releases.ReleaseCheckItem do
  use Afp.Factory.Schema

  alias Afp.Factory

  schema "release_check_items" do
    field :category, :string
    field :title, :string
    field :status, :string, default: "pending"
    field :required, :boolean, default: true
    field :waiver_reason, :string
    field :decision_note, :string
    field :position, :integer, default: 0
    field :updated_by, :string

    belongs_to :release_target, Afp.Factory.Releases.ReleaseTarget

    timestamps()
  end

  def changeset(check_item, attrs) do
    check_item
    |> cast(attrs, [
      :release_target_id,
      :category,
      :title,
      :status,
      :required,
      :waiver_reason,
      :decision_note,
      :position,
      :updated_by
    ])
    |> validate_required([:release_target_id, :category, :title, :status, :required, :position])
    |> validate_inclusion(:status, Factory.check_statuses())
    |> validate_waiver_reason()
    |> foreign_key_constraint(:release_target_id)
  end

  defp validate_waiver_reason(changeset) do
    if get_field(changeset, :status) == "waived" and
         Factory.blank?(get_field(changeset, :waiver_reason)) do
      add_error(changeset, :waiver_reason, "is required when waiving a checklist item")
    else
      changeset
    end
  end
end
