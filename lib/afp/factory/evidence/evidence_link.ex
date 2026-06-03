# @input  - Evidence packet IDs and app-factory subject identifiers
# @output - Non-destructive links between evidence and decisions/work objects
# @pos    - Join schema for multi-object evidence attachment
defmodule Afp.Factory.Evidence.EvidenceLink do
  use Afp.Factory.Schema

  @subject_types ~w(app ticket harness_packet codex_session release_target release_check_item metrics_snapshot)

  schema "evidence_links" do
    field :subject_type, :string
    field :subject_id, :binary_id
    field :link_reason, :string

    belongs_to :evidence_packet, Afp.Factory.Evidence.EvidencePacket

    timestamps(updated_at: false)
  end

  def subject_types, do: @subject_types

  def changeset(evidence_link, attrs) do
    evidence_link
    |> cast(attrs, [:evidence_packet_id, :subject_type, :subject_id, :link_reason])
    |> validate_required([:evidence_packet_id, :subject_type, :subject_id])
    |> validate_inclusion(:subject_type, @subject_types)
    |> foreign_key_constraint(:evidence_packet_id)
  end
end
