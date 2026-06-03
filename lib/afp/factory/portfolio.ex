# @input  - App inventory params and manual lifecycle/business decisions
# @output - Portfolio queries, app persistence, and repository matching
# @pos    - Context boundary for app lifecycle, next action, and operating posture
defmodule Afp.Factory.Portfolio do
  import Ecto.Query

  alias Afp.Factory
  alias Afp.Factory.Events
  alias Afp.Factory.Evidence
  alias Afp.Factory.Portfolio.App
  alias Afp.Repo

  def list_apps(params \\ %{}) do
    App
    |> maybe_exclude_archived(params)
    |> apply_filter(:lifecycle_stage, filter_value(params, "lifecycle_stage"))
    |> apply_filter(:business_posture, filter_value(params, "business_posture"))
    |> apply_filter(:health_state, filter_value(params, "health_state"))
    |> apply_platform_filter(filter_value(params, "platform"))
    |> apply_stale_filter(filter_value(params, "stale"))
    |> apply_sort(filter_value(params, "sort") || "last_activity")
    |> Repo.all()
  end

  def list_active_apps do
    App
    |> where([app], app.lifecycle_stage not in ["paused", "archived"])
    |> order_by([app], asc: app.name)
    |> Repo.all()
  end

  def list_app_options do
    list_active_apps()
    |> Enum.map(&{&1.name, &1.id})
  end

  def get_app!(id) do
    App
    |> Repo.get!(id)
    |> preload_app()
  end

  def get_app(id) when is_binary(id) do
    App
    |> Repo.get(id)
    |> case do
      nil -> nil
      app -> preload_app(app)
    end
  end

  def get_app(_id), do: nil

  def change_app(%App{} = app, attrs \\ %{}) do
    App.changeset(app, attrs)
  end

  def create_app(attrs) do
    attrs = Map.put_new(attrs, "last_activity_at", Factory.now())

    %App{}
    |> App.changeset(attrs)
    |> Repo.insert()
    |> after_write("app_created")
  end

  def update_app(%App{} = app, attrs) do
    attrs = Map.put(attrs, "last_activity_at", Factory.now())

    app
    |> App.changeset(attrs)
    |> Repo.update()
    |> after_write("app_updated")
  end

  def update_next_action(%App{} = app, next_action) do
    with {:ok, app} <- update_app(app, %{"next_action" => next_action}) do
      Events.record_event("app", app.id, "next_action_changed", %{next_action: app.next_action})
      {:ok, app}
    end
  end

  def transition_lifecycle(%App{} = app, lifecycle_stage, note) do
    transition_lifecycle(app, lifecycle_stage, note, %{})
  end

  def transition_lifecycle(%App{} = app, lifecycle_stage, note, attrs) do
    cond do
      lifecycle_stage not in Factory.lifecycle_stages() ->
        {:error, :invalid_lifecycle_stage}

      Factory.blank?(note) ->
        {:error, :note_required}

      true ->
        update_attrs =
          %{"lifecycle_stage" => lifecycle_stage, "last_activity_at" => Factory.now()}
          |> maybe_pause_or_archive(lifecycle_stage, note)

        with {:ok, app} <- update_app(app, update_attrs) do
          maybe_create_decision_evidence(app, "lifecycle", note, attrs)

          Events.record_event("app", app.id, "lifecycle_transitioned", %{
            to: lifecycle_stage,
            note: note
          })

          {:ok, app}
        end
    end
  end

  def transition_business_posture(%App{} = app, business_posture, note) do
    transition_business_posture(app, business_posture, note, %{})
  end

  def transition_business_posture(%App{} = app, business_posture, note, attrs) do
    cond do
      business_posture not in Factory.business_postures() ->
        {:error, :invalid_business_posture}

      Factory.blank?(note) ->
        {:error, :note_required}

      true ->
        with {:ok, app} <- update_app(app, %{"business_posture" => business_posture}) do
          maybe_create_decision_evidence(app, "business_posture", note, attrs)

          Events.record_event("app", app.id, "business_posture_changed", %{
            to: business_posture,
            note: note
          })

          {:ok, app}
        end
    end
  end

  def set_health_state(%App{} = app, health_state, note \\ nil) do
    cond do
      health_state not in Factory.health_states() ->
        {:error, :invalid_health_state}

      true ->
        app
        |> Ecto.Changeset.change(%{health_state: health_state, last_activity_at: Factory.now()})
        |> Repo.update()
        |> case do
          {:ok, app} ->
            Events.record_event("app", app.id, "health_state_changed", %{
              to: health_state,
              note: note
            })

            {:ok, app}

          result ->
            result
        end
    end
  end

  def apps_without_next_action do
    App
    |> where([app], app.lifecycle_stage not in ["idea", "paused", "archived"])
    |> where([app], is_nil(app.next_action) or app.next_action == "")
    |> order_by([app], desc: app.last_activity_at)
    |> Repo.all()
  end

  def apps_with_invalid_repo do
    App
    |> where([app], app.health_state == "repo_missing")
    |> order_by([app], asc: app.name)
    |> Repo.all()
  end

  def match_app_by_cwd(cwd) do
    App
    |> where([app], not is_nil(app.repo_path) and app.repo_path != "")
    |> Repo.all()
    |> Enum.sort_by(fn app -> String.length(app.repo_path || "") end, :desc)
    |> Enum.find(&Factory.repo_path_matches?(&1.repo_path, cwd))
  end

  def preload_app(%App{} = app) do
    Repo.preload(app,
      tickets: from(ticket in Afp.Factory.Work.Ticket, order_by: [desc: ticket.updated_at]),
      harness_packets:
        from(packet in Afp.Factory.Work.HarnessPacket, order_by: [desc: packet.updated_at]),
      codex_sessions:
        from(session in Afp.Factory.Sessions.CodexSession, order_by: [desc: session.last_seen_at]),
      evidence_packets:
        from(evidence in Afp.Factory.Evidence.EvidencePacket,
          order_by: [desc: evidence.inserted_at]
        ),
      release_targets:
        from(release in Afp.Factory.Releases.ReleaseTarget, order_by: [desc: release.updated_at]),
      metrics_snapshots:
        from(snapshot in Afp.Factory.Metrics.MetricsSnapshot,
          order_by: [desc: snapshot.snapshot_date]
        ),
      repo_scans:
        from(scan in Afp.Factory.Repositories.RepoScan, order_by: [desc: scan.scanned_at]),
      growth_experiments:
        from(experiment in Afp.Factory.Growth.GrowthExperiment,
          order_by: [asc_nulls_last: experiment.review_due_on, desc: experiment.updated_at]
        ),
      maintenance_obligations:
        from(obligation in Afp.Factory.Maintenance.MaintenanceObligation,
          order_by: [asc_nulls_last: obligation.due_on, desc: obligation.updated_at]
        )
    )
  end

  defp after_write({:ok, %App{} = app}, event_type) do
    Events.record_event("app", app.id, event_type, %{
      name: app.name,
      lifecycle_stage: app.lifecycle_stage,
      business_posture: app.business_posture
    })

    {:ok, app}
  end

  defp after_write(result, _event_type), do: result

  defp maybe_pause_or_archive(attrs, "paused", note), do: Map.put(attrs, "paused_reason", note)

  defp maybe_pause_or_archive(attrs, "archived", _note),
    do: Map.put(attrs, "archived_at", Factory.now())

  defp maybe_pause_or_archive(attrs, _stage, _note), do: attrs

  defp maybe_create_decision_evidence(app, decision_type, note, attrs) do
    summary = Map.get(attrs, "evidence_summary") || Map.get(attrs, :evidence_summary)

    if Factory.present?(summary) do
      {:ok, packet, _links} =
        Evidence.create_evidence_packet(
          %{
            "app_id" => app.id,
            "type" => "review_note",
            "title" => "#{Factory.labelize(decision_type)} decision evidence",
            "summary" => summary,
            "reliability" => "medium",
            "payload" => %{"decision_note" => note}
          },
          [
            %{
              "subject_type" => "app",
              "subject_id" => app.id,
              "link_reason" => "#{Factory.labelize(decision_type)} transition evidence"
            }
          ]
        )

      packet
    else
      nil
    end
  end

  defp maybe_exclude_archived(query, params) do
    if truthy?(filter_value(params, "include_archived")) do
      query
    else
      where(query, [app], is_nil(app.archived_at) and app.lifecycle_stage != "archived")
    end
  end

  defp apply_filter(query, _field, value) when value in [nil, ""], do: query

  defp apply_filter(query, field, value) do
    where(query, [app], field(app, ^field) == ^value)
  end

  defp apply_platform_filter(query, value) when value in [nil, ""], do: query

  defp apply_platform_filter(query, value) do
    where(query, [app], ^value in app.platforms)
  end

  defp apply_stale_filter(query, value) when value in [nil, "", "all"], do: query

  defp apply_stale_filter(query, "missing_next_action"),
    do: where(query, [app], is_nil(app.next_action) or app.next_action == "")

  defp apply_stale_filter(query, "invalid_repo"),
    do: where(query, [app], app.health_state == "repo_missing")

  defp apply_stale_filter(query, _value), do: query

  defp apply_sort(query, "name"), do: order_by(query, [app], asc: app.name)

  defp apply_sort(query, "lifecycle"),
    do: order_by(query, [app], asc: app.lifecycle_stage, asc: app.name)

  defp apply_sort(query, "posture"),
    do: order_by(query, [app], asc: app.business_posture, asc: app.name)

  defp apply_sort(query, "health"),
    do: order_by(query, [app], asc: app.health_state, asc: app.name)

  defp apply_sort(query, _sort),
    do: order_by(query, [app], desc_nulls_last: app.last_activity_at, asc: app.name)

  defp filter_value(params, key) do
    Map.get(params, key) || Map.get(params, param_atom(key))
  end

  defp param_atom("lifecycle_stage"), do: :lifecycle_stage
  defp param_atom("business_posture"), do: :business_posture
  defp param_atom("health_state"), do: :health_state
  defp param_atom("platform"), do: :platform
  defp param_atom("stale"), do: :stale
  defp param_atom("sort"), do: :sort
  defp param_atom("include_archived"), do: :include_archived
  defp param_atom(_key), do: :unknown

  defp truthy?(value), do: value in [true, "true", "1", 1]
end
