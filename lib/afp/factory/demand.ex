# @input  - Demand item params, launch request params, and app promotion params
# @output - Demand-management queries, persistence, launch handoffs, and promotion
# @pos    - Context boundary for pre-app demand and human-confirmed Codex launch requests
defmodule Afp.Factory.Demand do
  import Ecto.Query

  alias Afp.Factory
  alias Afp.Factory.Demand.CodexLaunchRequest
  alias Afp.Factory.Demand.DemandItem
  alias Afp.Factory.Events
  alias Afp.Factory.Portfolio
  alias Afp.Repo

  @launch_attr_atoms %{
    "source_type" => :source_type,
    "source_id" => :source_id,
    "title" => :title,
    "objective" => :objective,
    "context" => :context,
    "risk_level" => :risk_level,
    "launch_mode" => :launch_mode,
    "status" => :status,
    "confirmation" => :confirmation,
    "handoff_text" => :handoff_text
  }

  @filter_attr_atoms %{
    "status" => :status,
    "confidence" => :confidence,
    "source" => :source,
    "risk_level" => :risk_level
  }

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

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, %{demand_item: promoted_demand_item, app: app}} -> {:ok, promoted_demand_item, app}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_launch_requests(params \\ %{}) do
    CodexLaunchRequest
    |> apply_filter(:status, filter_value(params, "status"))
    |> apply_filter(:risk_level, filter_value(params, "risk_level"))
    |> order_by([request], desc: request.updated_at)
    |> Repo.all()
    |> Repo.preload([:demand_item, :app, :ticket, :release_target])
  end

  def change_launch_request(%CodexLaunchRequest{} = launch_request, attrs \\ %{}) do
    CodexLaunchRequest.changeset(launch_request, attrs)
  end

  def create_launch_request(attrs) do
    attrs = maybe_put_handoff_text(attrs)

    %CodexLaunchRequest{}
    |> CodexLaunchRequest.changeset(attrs)
    |> Repo.insert()
    |> after_launch_write("launch_request_created")
  end

  def create_launch_request_from_demand(%DemandItem{} = demand_item, attrs) do
    attrs =
      attrs
      |> Map.put("demand_item_id", demand_item.id)
      |> Map.put("source_type", "demand_item")
      |> Map.put("source_id", demand_item.id)
      |> put_if_blank("title", "Validate #{demand_item.title}")
      |> put_if_blank("objective", demand_item.validation_action)
      |> put_if_blank("context", launch_context_from_demand(demand_item))

    create_launch_request(attrs)
  end

  def update_launch_request(%CodexLaunchRequest{} = launch_request, attrs) do
    attrs = maybe_put_handoff_text(attrs)

    launch_request
    |> CodexLaunchRequest.changeset(attrs)
    |> Repo.update()
    |> after_launch_write("launch_request_updated")
  end

  def mark_launch_request_launched(%CodexLaunchRequest{} = launch_request) do
    update_launch_request(launch_request, %{
      "status" => "launched",
      "launched_at" => Factory.now()
    })
  end

  def launch_handoff_text(%CodexLaunchRequest{} = launch_request) do
    """
    Codex Launch Request: #{launch_request.title}

    Objective:
    #{launch_request.objective}

    Source:
    #{launch_request.source_type} #{launch_request.source_id || ""}

    Risk:
    #{launch_request.risk_level}

    Context:
    #{launch_request.context || "No additional context."}

    Approval:
    Human confirmation is required before applying risky changes or promoting state.
    """
    |> String.trim()
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

  defp after_launch_write({:ok, %CodexLaunchRequest{} = launch_request}, event_type) do
    Events.record_event("codex_launch_request", launch_request.id, event_type, %{
      title: launch_request.title,
      status: launch_request.status,
      risk_level: launch_request.risk_level,
      source_type: launch_request.source_type,
      source_id: launch_request.source_id
    })

    {:ok, Repo.preload(launch_request, [:demand_item, :app, :ticket, :release_target])}
  end

  defp after_launch_write(result, _event_type), do: result

  defp maybe_put_handoff_text(attrs) do
    if Factory.blank?(Map.get(attrs, "handoff_text") || Map.get(attrs, :handoff_text)) do
      draft = struct(CodexLaunchRequest, atomize_launch_attrs(attrs))
      Map.put(attrs, "handoff_text", launch_handoff_text(draft))
    else
      attrs
    end
  end

  defp atomize_launch_attrs(attrs) do
    %{
      source_type: attr_value(attrs, "source_type"),
      source_id: attr_value(attrs, "source_id"),
      title: attr_value(attrs, "title"),
      objective: attr_value(attrs, "objective"),
      context: attr_value(attrs, "context"),
      risk_level: attr_value(attrs, "risk_level"),
      launch_mode: attr_value(attrs, "launch_mode"),
      status: attr_value(attrs, "status"),
      confirmation: attr_value(attrs, "confirmation"),
      handoff_text: attr_value(attrs, "handoff_text")
    }
  end

  defp attr_value(attrs, key),
    do: Map.get(attrs, key) || Map.get(attrs, Map.fetch!(@launch_attr_atoms, key))

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

  defp launch_context_from_demand(%DemandItem{} = demand_item) do
    [
      "Demand item: #{demand_item.title}",
      "Source: #{demand_item.source || "unknown"}",
      "Target user/job: #{demand_item.target_user || demand_item.job_to_be_done || "unknown"}",
      "Demand signal: #{demand_item.demand_signal || "unknown"}",
      "Incumbent weakness: #{demand_item.incumbent_weakness || "unknown"}",
      "Wedge hypothesis: #{demand_item.wedge_hypothesis || "unknown"}",
      "Evidence: #{demand_item.evidence_summary || "none yet"}"
    ]
    |> Enum.join("\n")
  end

  defp apply_filter(query, _field, value) when value in [nil, ""], do: query

  defp apply_filter(query, field, value),
    do: where(query, [record], field(record, ^field) == ^value)

  defp apply_source_filter(query, value) when value in [nil, ""], do: query

  defp apply_source_filter(query, value) do
    where(query, [demand], ilike(demand.source, ^"%#{value}%"))
  end

  defp put_if_blank(attrs, key, value) do
    if Factory.blank?(Map.get(attrs, key) || Map.get(attrs, Map.get(@launch_attr_atoms, key))) do
      Map.put(attrs, key, value)
    else
      attrs
    end
  end

  defp filter_value(params, key) when is_map(params),
    do: Map.get(params, key) || Map.get(params, Map.fetch!(@filter_attr_atoms, key))

  defp filter_value(_params, _key), do: nil
end
