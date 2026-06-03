# @input  - Growth experiment forms, review decisions, and app business posture
# @output - Growth experiment workflow and review queues
# @pos    - Context boundary for post-launch growth loops
defmodule Afp.Factory.Growth do
  import Ecto.Query

  alias Afp.Factory
  alias Afp.Factory.Events
  alias Afp.Factory.Growth.GrowthExperiment
  alias Afp.Factory.Portfolio
  alias Afp.Repo

  def list_experiments(params \\ %{}) do
    GrowthExperiment
    |> preload(:app)
    |> apply_filter(:app_id, Map.get(params, "app_id") || Map.get(params, :app_id))
    |> apply_filter(:status, Map.get(params, "status") || Map.get(params, :status))
    |> order_by([experiment],
      asc_nulls_last: experiment.review_due_on,
      desc: experiment.updated_at
    )
    |> Repo.all()
  end

  def list_review_due_experiments(date \\ Date.utc_today()) do
    GrowthExperiment
    |> where([experiment], experiment.status in ["running", "review"])
    |> where([experiment], not is_nil(experiment.review_due_on))
    |> where([experiment], experiment.review_due_on <= ^date)
    |> preload(:app)
    |> order_by([experiment], asc: experiment.review_due_on, asc: experiment.priority)
    |> Repo.all()
  end

  def get_experiment!(id) do
    GrowthExperiment
    |> Repo.get!(id)
    |> Repo.preload(:app)
  end

  def change_experiment(%GrowthExperiment{} = experiment, attrs \\ %{}) do
    GrowthExperiment.changeset(experiment, attrs)
  end

  def create_experiment(attrs) do
    %GrowthExperiment{}
    |> GrowthExperiment.changeset(attrs)
    |> Repo.insert()
    |> after_write("growth_experiment_created")
  end

  def update_experiment(%GrowthExperiment{} = experiment, attrs) do
    attrs = maybe_put_terminal_timestamp(experiment, attrs)

    experiment
    |> GrowthExperiment.changeset(attrs)
    |> Repo.update()
    |> after_write("growth_experiment_updated")
  end

  def transition_experiment(%GrowthExperiment{} = experiment, status, attrs \\ %{}) do
    attrs
    |> Map.put("status", status)
    |> then(&update_experiment(experiment, &1))
  end

  def refresh_app_health_for_review_due do
    list_review_due_experiments()
    |> Enum.each(fn experiment ->
      Portfolio.set_health_state(
        experiment.app,
        "growth_review",
        "Growth experiment review is due: #{experiment.title}"
      )
    end)
  end

  defp maybe_put_terminal_timestamp(experiment, attrs) do
    status = Map.get(attrs, "status") || Map.get(attrs, :status) || experiment.status

    cond do
      status in ["running", "review"] and experiment.started_at == nil ->
        Map.put(attrs, "started_at", Factory.now())

      status in ["won", "lost", "dropped"] ->
        Map.put(attrs, "ended_at", Factory.now())

      true ->
        attrs
    end
  end

  defp after_write({:ok, %GrowthExperiment{} = experiment}, event_type) do
    Events.record_event("growth_experiment", experiment.id, event_type, %{
      app_id: experiment.app_id,
      title: experiment.title,
      status: experiment.status
    })

    {:ok, experiment}
  end

  defp after_write(result, _event_type), do: result

  defp apply_filter(query, _field, value) when value in [nil, ""], do: query

  defp apply_filter(query, field, value),
    do: where(query, [record], field(record, ^field) == ^value)
end
