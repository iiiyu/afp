# @input  - Evidence packet params and subject-link requests
# @output - Evidence CRUD, attachment, and subject counts
# @pos    - Context boundary for durable proof and review attachments
defmodule Afp.Factory.Evidence do
  import Ecto.Query

  alias Afp.Factory.Events
  alias Afp.Factory.Evidence.EvidenceLink
  alias Afp.Factory.Evidence.EvidencePacket
  alias Afp.Repo

  def list_evidence(params \\ %{}) do
    EvidencePacket
    |> preload([:app, :evidence_links])
    |> apply_filter(:app_id, Map.get(params, "app_id") || Map.get(params, :app_id))
    |> apply_filter(:type, Map.get(params, "type") || Map.get(params, :type))
    |> order_by([packet], desc: packet.inserted_at)
    |> Repo.all()
  end

  def get_evidence_packet!(id) do
    EvidencePacket
    |> Repo.get!(id)
    |> Repo.preload([:app, :evidence_links])
  end

  def change_evidence_packet(%EvidencePacket{} = evidence_packet, attrs \\ %{}) do
    EvidencePacket.changeset(evidence_packet, attrs)
  end

  def create_evidence_packet(attrs) do
    %EvidencePacket{}
    |> EvidencePacket.changeset(attrs)
    |> Repo.insert()
    |> after_packet_write("evidence_created")
  end

  def create_evidence_packet(attrs, links) when is_list(links) do
    Repo.transaction(fn ->
      case create_evidence_packet(attrs) do
        {:ok, packet} ->
          linked =
            Enum.map(links, fn link ->
              {:ok, evidence_link} =
                attach_evidence(
                  packet,
                  link["subject_type"] || link[:subject_type],
                  link["subject_id"] || link[:subject_id],
                  link["link_reason"] || link[:link_reason]
                )

              evidence_link
            end)

          {packet, linked}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, {packet, links}} -> {:ok, packet, links}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def attach_evidence(%EvidencePacket{} = packet, subject_type, subject_id, link_reason \\ nil) do
    attrs = %{
      evidence_packet_id: packet.id,
      subject_type: subject_type,
      subject_id: subject_id,
      link_reason: link_reason
    }

    %EvidenceLink{}
    |> EvidenceLink.changeset(attrs)
    |> Repo.insert()
    |> after_link_write(packet)
  end

  def list_links_for_subject(subject_type, subject_id) do
    EvidenceLink
    |> where([link], link.subject_type == ^subject_type and link.subject_id == ^subject_id)
    |> preload(:evidence_packet)
    |> order_by([link], desc: link.inserted_at)
    |> Repo.all()
  end

  def count_links(subject_type, subject_id) when is_binary(subject_id) do
    EvidenceLink
    |> where([link], link.subject_type == ^subject_type and link.subject_id == ^subject_id)
    |> Repo.aggregate(:count)
  end

  def count_links(_subject_type, _subject_id), do: 0

  defp after_packet_write({:ok, %EvidencePacket{} = packet}, event_type) do
    Events.record_event("evidence_packet", packet.id, event_type, %{
      app_id: packet.app_id,
      type: packet.type
    })

    Events.record_event("app", packet.app_id, "evidence_attached", %{
      evidence_packet_id: packet.id,
      type: packet.type
    })

    {:ok, packet}
  end

  defp after_packet_write(result, _event_type), do: result

  defp after_link_write({:ok, %EvidenceLink{} = link}, %EvidencePacket{} = packet) do
    Events.record_event("evidence_link", link.id, "evidence_linked", %{
      evidence_packet_id: packet.id,
      subject_type: link.subject_type,
      subject_id: link.subject_id,
      app_id: packet.app_id
    })

    {:ok, link}
  end

  defp after_link_write(result, _packet), do: result

  defp apply_filter(query, _field, value) when value in [nil, ""], do: query

  defp apply_filter(query, field, value),
    do: where(query, [record], field(record, ^field) == ^value)
end
