# @input  - Demand item attrs, status transitions, and app promotion attrs
# @output - Demand item CRUD, transitions, promotion records, and audit events
# @pos    - Demand-item implementation behind the public Demand context facade
defmodule Afp.Factory.Demand.Items do
  import Ecto.Query

  alias Afp.Factory
  alias Afp.Factory.Demand.DemandItem
  alias Afp.Factory.Events
  alias Afp.Factory.Portfolio
  alias Afp.Repo

  def list_demand_items(params \\ %{}) do
    DemandItem
    |> apply_filter(:status, filter_value(params, "status"))
    |> apply_filter(:confidence, filter_value(params, "confidence"))
    |> apply_source_filter(filter_value(params, "source"))
    |> order_by([demand], desc: demand.updated_at)
    |> Repo.all()
    |> Repo.preload([:promoted_app, :launch_requests])
  end

  def list_active_demand_items do
    DemandItem
    |> where([demand], demand.status in ["captured", "researching", "validating", "validated"])
    |> order_by([demand], desc: demand.updated_at)
    |> Repo.all()
    |> Repo.preload([:promoted_app, :launch_requests])
  end

  def get_demand_item!(id) do
    DemandItem
    |> Repo.get!(id)
    |> Repo.preload([:promoted_app, :launch_requests])
  end

  def change_demand_item(%DemandItem{} = demand_item, attrs \\ %{}) do
    DemandItem.changeset(demand_item, attrs)
  end

  def create_demand_item(attrs) do
    %DemandItem{}
    |> DemandItem.changeset(attrs)
    |> Repo.insert()
    |> after_demand_write("demand_created")
  end

  def update_demand_item(%DemandItem{} = demand_item, attrs) do
    demand_item
    |> DemandItem.changeset(attrs)
    |> Repo.update()
    |> after_demand_write("demand_updated")
  end

  def transition_demand(%DemandItem{} = demand_item, status, attrs \\ %{}) do
    attrs
    |> Map.put("status", status)
    |> then(&update_demand_item(demand_item, &1))
  end

  def promote_to_app(%DemandItem{status: status}, _app_attrs) when status != "validated" do
    {:error, :demand_not_validated}
  end

  def promote_to_app(%DemandItem{} = demand_item, app_attrs) do
    app_attrs =
      app_attrs
      |> Map.put_new("next_action", demand_item.validation_action)
      |> Map.put_new("product_thesis", product_thesis_from_demand(demand_item))

    Repo.transaction(fn ->
      case Portfolio.create_app(app_attrs) do
        {:ok, app} ->
          promote_demand_item!(demand_item, app)

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, %{demand_item: promoted_demand_item, app: app}} -> {:ok, promoted_demand_item, app}
      {:error, reason} -> {:error, reason}
    end
  end

  defp promote_demand_item!(%DemandItem{} = demand_item, app) do
    promote_attrs = %{
      "status" => "promoted",
      "promoted_app_id" => app.id,
      "promoted_at" => Factory.now()
    }

    case demand_item |> DemandItem.changeset(promote_attrs) |> Repo.update() do
      {:ok, promoted_demand_item} ->
        Events.record_event("demand_item", demand_item.id, "demand_promoted", %{
          app_id: app.id,
          app_name: app.name
        })

        %{demand_item: Repo.preload(promoted_demand_item, :promoted_app), app: app}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp product_thesis_from_demand(%DemandItem{} = demand_item) do
    %{
      "source_demand_item_id" => demand_item.id,
      "target_user" => demand_item.target_user,
      "job_to_be_done" => demand_item.job_to_be_done,
      "demand_signal" => demand_item.demand_signal,
      "incumbent_weakness" => demand_item.incumbent_weakness,
      "wedge_hypothesis" => demand_item.wedge_hypothesis
    }
  end

  defp after_demand_write({:ok, %DemandItem{} = demand_item}, event_type) do
    Events.record_event("demand_item", demand_item.id, event_type, %{
      title: demand_item.title,
      status: demand_item.status,
      confidence: demand_item.confidence
    })

    {:ok, Repo.preload(demand_item, [:promoted_app, :launch_requests])}
  end

  defp after_demand_write(result, _event_type), do: result

  defp apply_filter(query, _field, value) when value in [nil, ""], do: query

  defp apply_filter(query, field, value),
    do: where(query, [record], field(record, ^field) == ^value)

  defp apply_source_filter(query, value) when value in [nil, ""], do: query

  defp apply_source_filter(query, value) do
    where(query, [demand], ilike(demand.source, ^"%#{value}%"))
  end

  defp filter_value(params, key) when is_map(params), do: Map.get(params, key)
  defp filter_value(_params, _key), do: nil
end
