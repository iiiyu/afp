# @input  - State changes from factory contexts and hook processing
# @output - Persisted events plus PubSub notifications for LiveViews
# @pos    - Append-only event context and real-time broadcast boundary
defmodule Afp.Factory.Events do
  import Ecto.Query

  alias Afp.Factory.Events.Event
  alias Afp.Repo

  @topic "factory:events"

  def topic, do: @topic

  def subject_topic(subject_type, subject_id), do: "factory:#{subject_type}:#{subject_id}"

  def subscribe do
    Phoenix.PubSub.subscribe(Afp.PubSub, @topic)
  end

  def subscribe(subject_type, subject_id) do
    Phoenix.PubSub.subscribe(Afp.PubSub, subject_topic(subject_type, subject_id))
  end

  def list_events(limit \\ 100) do
    Event
    |> order_by([event], desc: event.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def record_event(subject_type, subject_id, event_type, payload \\ %{}) do
    attrs = %{
      subject_type: subject_type,
      subject_id: subject_id,
      event_type: event_type,
      payload: payload || %{}
    }

    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
    |> broadcast_insert()
  end

  def record_event!(subject_type, subject_id, event_type, payload \\ %{}) do
    case record_event(subject_type, subject_id, event_type, payload) do
      {:ok, event} ->
        event

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  defp broadcast_insert({:ok, event} = result) do
    Phoenix.PubSub.broadcast(Afp.PubSub, @topic, {:factory_event, event})

    if event.subject_id do
      Phoenix.PubSub.broadcast(
        Afp.PubSub,
        subject_topic(event.subject_type, event.subject_id),
        {:factory_event, event}
      )
    end

    result
  end

  defp broadcast_insert(result), do: result
end
