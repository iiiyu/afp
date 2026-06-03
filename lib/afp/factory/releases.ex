# @input  - Release target params, checklist updates, and manual transition notes
# @output - Release-center operations with checklist readiness enforcement
# @pos    - Context boundary for release readiness and submission decisions
defmodule Afp.Factory.Releases do
  import Ecto.Query

  alias Afp.Factory
  alias Afp.Factory.Events
  alias Afp.Factory.Releases.ReleaseCheckItem
  alias Afp.Factory.Releases.ReleaseTarget
  alias Afp.Factory.Work
  alias Afp.Repo

  @release_transitions %{
    "draft" => ~w(preparing cancelled),
    "preparing" => ~w(ready_for_review blocked cancelled),
    "ready_for_review" => ~w(submitted blocked preparing),
    "submitted" => ~w(live blocked),
    "blocked" => ~w(preparing ready_for_review cancelled),
    "live" => []
  }

  @default_checklist [
    {"Build", "Build artifact exists"},
    {"Tests", "Automated tests passed"},
    {"Screenshots", "Store screenshots prepared"},
    {"Store metadata", "Store metadata reviewed"},
    {"Privacy", "Privacy answers and policy checked"},
    {"Localization", "Localization reviewed"},
    {"Release notes", "Release notes drafted"},
    {"Submission", "Manual submission path confirmed"},
    {"Post-release follow-up", "Post-release follow-up defined"}
  ]

  def default_checklist, do: @default_checklist

  def list_release_targets(params \\ %{}) do
    ReleaseTarget
    |> preload([:app, :release_check_items])
    |> apply_filter(:app_id, Map.get(params, "app_id") || Map.get(params, :app_id))
    |> apply_filter(:status, Map.get(params, "status") || Map.get(params, :status))
    |> order_by([target], desc: target.updated_at)
    |> Repo.all()
  end

  def get_release_target!(id) do
    ReleaseTarget
    |> Repo.get!(id)
    |> Repo.preload([
      :app,
      release_check_items: from(item in ReleaseCheckItem, order_by: [asc: item.position])
    ])
  end

  def change_release_target(%ReleaseTarget{} = release_target, attrs \\ %{}) do
    ReleaseTarget.changeset(release_target, attrs)
  end

  def create_release_target(attrs) do
    Repo.transaction(fn ->
      case %ReleaseTarget{} |> ReleaseTarget.changeset(attrs) |> Repo.insert() do
        {:ok, release_target} ->
          create_default_checklist!(release_target)

          Events.record_event("release_target", release_target.id, "release_target_created", %{
            app_id: release_target.app_id
          })

          release_target

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def update_release_target(%ReleaseTarget{} = release_target, attrs) do
    release_target
    |> ReleaseTarget.changeset(attrs)
    |> Repo.update()
    |> after_target_write("release_target_updated")
  end

  def transition_release_target(%ReleaseTarget{} = release_target, target_status, attrs \\ %{}) do
    release_target = Repo.preload(release_target, :release_check_items)

    cond do
      target_status not in Factory.release_statuses() ->
        {:error, :invalid_release_status}

      target_status not in Map.get(@release_transitions, release_target.status, []) ->
        {:error, :invalid_release_transition}

      target_status == "ready_for_review" and not release_ready?(release_target) ->
        {:error, :checklist_incomplete}

      target_status == "submitted" and blank_param?(attrs, "decision_note") ->
        {:error, :submission_note_required}

      target_status == "live" and
          (blank_param?(attrs, "decision_note") or blank_param?(attrs, "released_at")) ->
        {:error, :live_note_and_date_required}

      true ->
        attrs =
          attrs
          |> Map.put("status", target_status)
          |> put_transition_timestamps(target_status)

        release_target
        |> ReleaseTarget.changeset(attrs)
        |> Repo.update()
        |> after_target_write("release_target_transitioned", %{to: target_status})
    end
  end

  def release_ready?(%ReleaseTarget{} = release_target) do
    release_target
    |> Repo.preload(:release_check_items)
    |> Map.fetch!(:release_check_items)
    |> Enum.all?(fn item ->
      not item.required or item.status in ["passed", "waived", "not_applicable"]
    end)
  end

  def list_blocking_targets do
    ReleaseTarget
    |> join(:left, [target], item in assoc(target, :release_check_items))
    |> where([target, item], target.status == "blocked" or item.status == "failed")
    |> preload([:app, :release_check_items])
    |> distinct(true)
    |> order_by([target], desc: target.updated_at)
    |> Repo.all()
  end

  def get_check_item!(id) do
    ReleaseCheckItem
    |> Repo.get!(id)
    |> Repo.preload(release_target: :app)
  end

  def update_check_item(%ReleaseCheckItem{} = check_item, attrs) do
    check_item
    |> ReleaseCheckItem.changeset(attrs)
    |> Repo.update()
    |> after_check_write("release_check_updated")
  end

  def create_ticket_for_check_item(%ReleaseCheckItem{} = check_item) do
    check_item = Repo.preload(check_item, release_target: :app)
    release_target = check_item.release_target

    Work.create_ticket(%{
      "app_id" => release_target.app_id,
      "title" => "Fix release check: #{check_item.title}",
      "description" =>
        "Release #{release_target.version || release_target.label} has a failed #{check_item.category} check.",
      "status" => "ready",
      "lifecycle_gate" => "release_ready",
      "risk_level" => "normal"
    })
  end

  defp create_default_checklist!(%ReleaseTarget{} = release_target) do
    @default_checklist
    |> Enum.with_index()
    |> Enum.each(fn {{category, title}, position} ->
      %ReleaseCheckItem{}
      |> ReleaseCheckItem.changeset(%{
        release_target_id: release_target.id,
        category: category,
        title: title,
        position: position
      })
      |> Repo.insert!()
    end)
  end

  defp put_transition_timestamps(attrs, "submitted"),
    do: Map.put_new(attrs, "submitted_at", Factory.now())

  defp put_transition_timestamps(attrs, _status), do: attrs

  defp after_target_write({:ok, %ReleaseTarget{} = release_target}, event_type) do
    after_target_write({:ok, release_target}, event_type, %{})
  end

  defp after_target_write(result, _event_type), do: result

  defp after_target_write({:ok, %ReleaseTarget{} = release_target}, event_type, payload) do
    Events.record_event(
      "release_target",
      release_target.id,
      event_type,
      Map.merge(%{app_id: release_target.app_id}, payload)
    )

    {:ok, release_target}
  end

  defp after_target_write(result, _event_type, _payload), do: result

  defp after_check_write({:ok, %ReleaseCheckItem{} = check_item}, event_type) do
    Events.record_event("release_check_item", check_item.id, event_type, %{
      release_target_id: check_item.release_target_id,
      status: check_item.status
    })

    {:ok, check_item}
  end

  defp after_check_write(result, _event_type), do: result

  defp apply_filter(query, _field, value) when value in [nil, ""], do: query

  defp apply_filter(query, field, value),
    do: where(query, [record], field(record, ^field) == ^value)

  defp blank_param?(attrs, key) do
    value = Map.get(attrs, key) || Map.get(attrs, param_atom(key))
    Factory.blank?(value)
  end

  defp param_atom("decision_note"), do: :decision_note
  defp param_atom("released_at"), do: :released_at
  defp param_atom(_key), do: :unknown
end
