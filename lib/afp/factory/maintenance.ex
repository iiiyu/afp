# @input  - Maintenance obligation forms, due dates, and completion decisions
# @output - Maintenance workflow and due queues
# @pos    - Context boundary for app maintenance obligations
defmodule Afp.Factory.Maintenance do
  import Ecto.Query

  alias Afp.Factory
  alias Afp.Factory.Events
  alias Afp.Factory.Maintenance.MaintenanceObligation
  alias Afp.Factory.Portfolio
  alias Afp.Repo

  def list_obligations(params \\ %{}) do
    MaintenanceObligation
    |> preload(:app)
    |> apply_filter(:app_id, Map.get(params, "app_id") || Map.get(params, :app_id))
    |> apply_filter(:status, Map.get(params, "status") || Map.get(params, :status))
    |> order_by([obligation], asc_nulls_last: obligation.due_on, desc: obligation.updated_at)
    |> Repo.all()
  end

  def list_due_obligations(date \\ Date.utc_today()) do
    MaintenanceObligation
    |> where([obligation], obligation.status in ["open", "due", "blocked"])
    |> where([obligation], not is_nil(obligation.due_on))
    |> where([obligation], obligation.due_on <= ^date)
    |> preload(:app)
    |> order_by([obligation], asc: obligation.due_on, asc: obligation.priority)
    |> Repo.all()
  end

  def get_obligation!(id) do
    MaintenanceObligation
    |> Repo.get!(id)
    |> Repo.preload(:app)
  end

  def change_obligation(%MaintenanceObligation{} = obligation, attrs \\ %{}) do
    MaintenanceObligation.changeset(obligation, attrs)
  end

  def create_obligation(attrs) do
    %MaintenanceObligation{}
    |> MaintenanceObligation.changeset(attrs)
    |> Repo.insert()
    |> after_write("maintenance_obligation_created")
  end

  def update_obligation(%MaintenanceObligation{} = obligation, attrs) do
    attrs = maybe_put_completed_at(obligation, attrs)

    obligation
    |> MaintenanceObligation.changeset(attrs)
    |> Repo.update()
    |> after_write("maintenance_obligation_updated")
  end

  def transition_obligation(%MaintenanceObligation{} = obligation, status, attrs \\ %{}) do
    attrs
    |> Map.put("status", status)
    |> then(&update_obligation(obligation, &1))
  end

  def refresh_app_health_for_due_obligations do
    list_due_obligations()
    |> Enum.each(fn obligation ->
      Portfolio.set_health_state(
        obligation.app,
        "maintenance_due",
        "Maintenance obligation is due: #{obligation.title}"
      )
    end)
  end

  defp maybe_put_completed_at(obligation, attrs) do
    status = Map.get(attrs, "status") || Map.get(attrs, :status) || obligation.status

    if status == "done" and obligation.completed_at == nil do
      Map.put(attrs, "completed_at", Factory.now())
    else
      attrs
    end
  end

  defp after_write({:ok, %MaintenanceObligation{} = obligation}, event_type) do
    Events.record_event("maintenance_obligation", obligation.id, event_type, %{
      app_id: obligation.app_id,
      title: obligation.title,
      status: obligation.status,
      due_on: obligation.due_on
    })

    {:ok, obligation}
  end

  defp after_write(result, _event_type), do: result

  defp apply_filter(query, _field, value) when value in [nil, ""], do: query

  defp apply_filter(query, field, value),
    do: where(query, [record], field(record, ^field) == ^value)
end
