# @input  - Manual evidence summaries, paths, URLs, and reliability metadata
# @output - Evidence packet records anchored to a primary app
# @pos    - Proof store schema for decisions and reviews
defmodule Afp.Factory.Evidence.EvidencePacket do
  use Afp.Factory.Schema

  alias Afp.Factory
  alias Afp.Factory.JsonData

  schema "evidence_packets" do
    field :type, :string, default: "manual"
    field :title, :string
    field :summary, :string
    field :source_path, :string
    field :source_url, :string
    field :reliability, :string, default: "unknown"
    field :payload, JsonData, default: %{}

    belongs_to :app, Afp.Factory.Portfolio.App
    has_many :evidence_links, Afp.Factory.Evidence.EvidenceLink

    timestamps()
  end

  def changeset(evidence_packet, attrs) do
    evidence_packet
    |> cast(attrs, [
      :app_id,
      :type,
      :title,
      :summary,
      :source_path,
      :source_url,
      :reliability,
      :payload
    ])
    |> normalize_text_fields([:title, :summary, :source_path, :source_url])
    |> put_default(:type, "manual")
    |> put_default(:reliability, "unknown")
    |> put_title_from_summary()
    |> validate_required([:app_id, :type, :title, :summary, :reliability])
    |> validate_inclusion(:type, Factory.evidence_types())
    |> validate_inclusion(:reliability, Factory.reliabilities())
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

  defp put_title_from_summary(changeset) do
    title = get_field(changeset, :title)
    summary = get_field(changeset, :summary)

    if Factory.blank?(title) and Factory.present?(summary) do
      summary
      |> String.slice(0, 80)
      |> then(&put_change(changeset, :title, &1))
    else
      changeset
    end
  end
end
