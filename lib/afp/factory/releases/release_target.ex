# @input  - App release planning fields, platform, version/build, and state decisions
# @output - Release target records with manual transition metadata
# @pos    - Release-center schema for planned app shipments
defmodule Afp.Factory.Releases.ReleaseTarget do
  use Afp.Factory.Schema

  alias Afp.Factory

  schema "release_targets" do
    field :platform, :string
    field :label, :string
    field :version, :string
    field :build, :string
    field :status, :string, default: "draft"
    field :submitted_at, :utc_datetime_usec
    field :released_at, :utc_datetime_usec
    field :decision_note, :string

    belongs_to :app, Afp.Factory.Portfolio.App
    has_many :release_check_items, Afp.Factory.Releases.ReleaseCheckItem
    has_many :harness_packets, Afp.Factory.Work.HarnessPacket

    timestamps()
  end

  def changeset(release_target, attrs) do
    release_target
    |> cast(attrs, [
      :app_id,
      :platform,
      :label,
      :version,
      :build,
      :status,
      :submitted_at,
      :released_at,
      :decision_note
    ])
    |> normalize_text_fields([:platform, :label, :version, :build, :decision_note])
    |> put_default(:status, "draft")
    |> validate_required([:app_id, :platform, :status])
    |> validate_version_or_label()
    |> validate_inclusion(:status, Factory.release_statuses())
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

  defp validate_version_or_label(changeset) do
    version = get_field(changeset, :version)
    label = get_field(changeset, :label)

    if Factory.blank?(version) and Factory.blank?(label) do
      add_error(changeset, :version, "or label is required")
    else
      changeset
    end
  end
end
