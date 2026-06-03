# @input  - Manual business snapshot params and portfolio freshness thresholds
# @output - Metrics snapshot persistence plus stale-live-app queries
# @pos    - Context boundary for business-loop visibility
defmodule Afp.Factory.Metrics do
  import Ecto.Query

  alias Afp.Factory.Events
  alias Afp.Factory.Metrics.MetricsSnapshot
  alias Afp.Factory.Portfolio
  alias Afp.Repo

  def list_metrics_snapshots(params \\ %{}) do
    MetricsSnapshot
    |> preload(:app)
    |> apply_filter(:app_id, Map.get(params, "app_id") || Map.get(params, :app_id))
    |> order_by([snapshot], desc: snapshot.snapshot_date, desc: snapshot.inserted_at)
    |> Repo.all()
  end

  def latest_snapshot_for_app(app_id) do
    MetricsSnapshot
    |> where([snapshot], snapshot.app_id == ^app_id)
    |> order_by([snapshot], desc: snapshot.snapshot_date, desc: snapshot.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  def change_metrics_snapshot(%MetricsSnapshot{} = metrics_snapshot, attrs \\ %{}) do
    MetricsSnapshot.changeset(metrics_snapshot, attrs)
  end

  def create_metrics_snapshot(attrs) do
    %MetricsSnapshot{}
    |> MetricsSnapshot.changeset(attrs)
    |> Repo.insert()
    |> after_snapshot_write("metrics_snapshot_created")
  end

  def apps_with_stale_metrics(days \\ 30) do
    cutoff = Date.utc_today() |> Date.add(-days)

    Portfolio.list_active_apps()
    |> Enum.filter(&(&1.lifecycle_stage in ["live", "iterating", "maintained"]))
    |> Enum.filter(fn app ->
      case latest_snapshot_for_app(app.id) do
        nil -> true
        snapshot -> Date.compare(snapshot.snapshot_date, cutoff) == :lt
      end
    end)
  end

  defp after_snapshot_write({:ok, %MetricsSnapshot{} = snapshot}, event_type) do
    Events.record_event("metrics_snapshot", snapshot.id, event_type, %{
      app_id: snapshot.app_id,
      snapshot_date: Date.to_iso8601(snapshot.snapshot_date)
    })

    Events.record_event("app", snapshot.app_id, "metrics_snapshot_created", %{
      metrics_snapshot_id: snapshot.id,
      snapshot_date: Date.to_iso8601(snapshot.snapshot_date)
    })

    {:ok, snapshot}
  end

  defp after_snapshot_write(result, _event_type), do: result

  defp apply_filter(query, _field, value) when value in [nil, ""], do: query

  defp apply_filter(query, field, value),
    do: where(query, [record], field(record, ^field) == ^value)
end
