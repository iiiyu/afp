# @input  - App id, transition/build-launch params, and build run activity
# @output - App repo detail LiveView: identity, build runs, transitions, history
# @pos    - The per-app repo detail surface (BuildRunner v2 lives here)
defmodule AfpWeb.AppLive.Show do
  use AfpWeb, :live_view

  import AfpWeb.AppLive.BuildComponents

  alias Afp.Factory
  alias Afp.Factory.Builds
  alias Afp.Factory.Events
  alias Afp.Factory.Opportunities.ActivityFeed
  alias Afp.Factory.Portfolio

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Events.subscribe()
      Events.subscribe_build_activity()
    end

    {:ok,
     socket
     |> assign(:app_id, id)
     |> assign(:run_activity, [])
     |> assign(:selected_report_name, nil)
     |> assign(:selected_report, nil)
     |> load_app()}
  end

  @impl true
  def handle_event("transition_lifecycle", %{"lifecycle" => params}, socket) do
    result =
      Portfolio.transition_lifecycle(
        socket.assigns.app,
        params["lifecycle_stage"],
        params["note"]
      )

    respond_transition(result, socket, "Lifecycle updated.")
  end

  def handle_event("transition_posture", %{"posture" => params}, socket) do
    result =
      Portfolio.transition_business_posture(
        socket.assigns.app,
        params["business_posture"],
        params["note"]
      )

    respond_transition(result, socket, "Business posture updated.")
  end

  def handle_event("update_next_action", %{"app" => params}, socket) do
    result = Portfolio.update_next_action(socket.assigns.app, params["next_action"])
    respond_transition(result, socket, "Next action updated.")
  end

  def handle_event("launch_milestone", %{"key" => milestone_key}, socket) do
    socket.assigns.app
    |> Builds.launch_milestone(milestone_key)
    |> respond_launch(socket, "Agent launched against #{milestone_key}.")
  end

  def handle_event("launch_task", %{"task" => %{"task_text" => task_text}}, socket) do
    socket.assigns.app
    |> Builds.launch_task(task_text)
    |> respond_launch(socket, "Agent launched on the ad-hoc task.")
  end

  def handle_event("mark_run_reviewed", %{"run-id" => run_id}, socket) do
    socket.assigns.app
    |> Builds.mark_run_reviewed(run_id)
    |> respond_launch(socket, "Run marked reviewed — the gate is open.")
  end

  def handle_event("force_fail_run", %{"run-id" => run_id}, socket) do
    socket.assigns.app
    |> Builds.force_fail_run(run_id)
    |> respond_launch(socket, "Run force-failed.")
  end

  def handle_event("select_report", %{"name" => name}, socket) do
    case Builds.read_report_file(socket.assigns.app, name) do
      {:ok, content} ->
        {:noreply,
         socket
         |> assign(:selected_report_name, name)
         |> assign(:selected_report, content)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not read report #{name}.")}
    end
  end

  @impl true
  def handle_info({:factory_event, _event}, socket) do
    {:noreply, load_app(socket)}
  end

  def handle_info({:build_run_activity, %{app_id: app_id} = message}, socket) do
    if app_id == socket.assigns.app.id do
      {:noreply,
       socket
       |> assign(
         :run_activity,
         ActivityFeed.append(socket.assigns.run_activity, message.activity)
       )
       |> maybe_refresh_app()}
    else
      {:noreply, socket}
    end
  end

  defp maybe_refresh_app(socket) do
    now = System.monotonic_time(:millisecond)

    if ActivityFeed.refresh_due?(socket.assigns[:last_refresh_at], now) do
      socket
      |> assign(:last_refresh_at, now)
      |> load_app()
    else
      socket
    end
  end

  defp respond_launch(result, socket, success_message) do
    case result do
      {:ok, _run} ->
        {:noreply,
         socket
         |> put_flash(:info, success_message)
         |> load_app()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, launch_error(reason))
         |> load_app()}
    end
  end

  defp launch_error({:repo_unhealthy, state, _notes}), do: "App repo is not healthy: #{state}."
  defp launch_error({:active_run, _id}), do: "A run is already in flight for this app."

  defp launch_error({:unreviewed_run, _id}),
    do: "Review gate: mark the completed run reviewed first."

  defp launch_error({:milestone_not_launchable, status}),
    do: "Milestone is #{status}; only pending/failed/blocked milestones launch."

  defp launch_error(:milestone_not_found), do: "Milestone not found in the repo state db."
  defp launch_error(:task_text_required), do: "Task text is required."
  defp launch_error({:build_run_failed, _id}), do: "Run failed — see the run entry for details."
  defp launch_error(reason), do: "Launch failed: #{inspect(reason)}"

  defp respond_transition(result, socket, success_message) do
    case result do
      {:ok, _app} ->
        {:noreply,
         socket
         |> put_flash(:info, success_message)
         |> load_app()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Update failed: #{inspect(reason)}")}
    end
  end

  defp load_app(socket) do
    app = Portfolio.get_app!(socket.assigns.app_id)
    repo_health = if app.repo_path, do: Builds.inspect_app_repo(app.repo_path)
    healthy? = match?(%{health_state: "healthy"}, repo_health)

    if healthy?, do: Builds.reconcile_stale_runs(app)

    socket
    |> assign(:app, app)
    |> assign(:page_title, app.name)
    |> assign(:repo_health, repo_health)
    |> assign(:milestones, if(healthy?, do: Builds.list_milestones(app), else: []))
    |> assign(:runs, if(healthy?, do: Builds.list_runs(app), else: []))
    |> assign(:launch_blocked, if(healthy?, do: Builds.launch_blocked(app)))
    |> assign(:report_files, if(healthy?, do: Builds.list_report_files(app), else: []))
    |> assign(:events, Events.list_subject_events("app", app.id))
    |> assign(:next_action_form, to_form(%{"next_action" => app.next_action}, as: :app))
    |> assign(:lifecycle_form, to_form(%{}, as: :lifecycle))
    |> assign(:posture_form, to_form(%{}, as: :posture))
    |> assign(:task_form, to_form(%{}, as: :task))
  end

  defp thesis_entries(thesis) when is_map(thesis) do
    Enum.sort_by(thesis, fn {key, _value} -> key end)
  end

  defp thesis_entries(_thesis), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-4">
        <.page_header
          eyebrow="Portfolio"
          title={@app.name}
          subtitle={@app.repo_path || "No repository path"}
        >
          <:meta>
            <.summary_item
              title="Lifecycle"
              value={Factory.labelize(@app.lifecycle_stage)}
              hint="stage"
            />
            <.summary_item
              title="Posture"
              value={Factory.labelize(@app.business_posture)}
              hint="business"
            />
            <.summary_item title="Health" value={Factory.labelize(@app.health_state)} hint="computed" />
          </:meta>
        </.page_header>

        <div class="grid gap-4 2xl:grid-cols-[minmax(0,1.4fr)_380px]">
          <main class="space-y-4">
            <.panel title="Overview">
              <div class="space-y-3 text-sm">
                <div class="flex flex-wrap gap-2">
                  <.status_badge status={@app.lifecycle_stage} />
                  <.status_badge status={@app.business_posture} />
                  <.status_badge status={@app.health_state} />
                </div>
                <dl class="grid gap-2 md:grid-cols-2">
                  <div>
                    <dt class="text-xs uppercase tracking-wide text-slate-500">Repository</dt>
                    <dd class="text-slate-700 dark:text-slate-200">
                      {@app.repo_path || "not set"}
                    </dd>
                  </div>
                  <div>
                    <dt class="text-xs uppercase tracking-wide text-slate-500">Platforms</dt>
                    <dd class="text-slate-700 dark:text-slate-200">
                      {Enum.join(@app.platforms || [], ", ")}
                    </dd>
                  </div>
                  <div>
                    <dt class="text-xs uppercase tracking-wide text-slate-500">Version</dt>
                    <dd class="text-slate-700 dark:text-slate-200">
                      {@app.current_version || "–"} ({@app.current_build || "–"})
                    </dd>
                  </div>
                  <div>
                    <dt class="text-xs uppercase tracking-wide text-slate-500">Last activity</dt>
                    <dd class="text-slate-700 dark:text-slate-200">
                      {format_datetime(@app.last_activity_at)}
                    </dd>
                  </div>
                </dl>
                <div :if={thesis_entries(@app.product_thesis) != []}>
                  <dt class="text-xs uppercase tracking-wide text-slate-500">Product thesis</dt>
                  <dl class="mt-1 space-y-1">
                    <div :for={{key, value} <- thesis_entries(@app.product_thesis)}>
                      <span class="font-medium">{Factory.labelize(key)}:</span>
                      <span class="text-slate-600 dark:text-slate-300">{value}</span>
                    </div>
                  </dl>
                </div>
              </div>
            </.panel>

            <.build_panel
              repo_health={@repo_health}
              milestones={@milestones}
              launch_blocked={@launch_blocked}
              task_form={@task_form}
            />

            <.runs_panel runs={@runs} run_activity={@run_activity} />

            <.reports_panel
              report_files={@report_files}
              selected_report_name={@selected_report_name}
              selected_report={@selected_report}
            />

            <.panel title="Event history">
              <:subtitle>Append-only audit log for this app.</:subtitle>
              <ul class="divide-y divide-slate-100 text-sm dark:divide-slate-800">
                <li :for={event <- @events} class="flex items-start justify-between gap-3 py-2">
                  <div class="min-w-0">
                    <div class="font-medium">{Factory.labelize(event.event_type)}</div>
                    <div class="truncate text-xs text-slate-500">
                      {inspect(event.payload, limit: 8)}
                    </div>
                  </div>
                  <span class="shrink-0 text-xs text-slate-500">
                    {format_datetime(event.inserted_at)}
                  </span>
                </li>
                <li :if={@events == []} class="py-2 text-sm text-slate-500">No events yet.</li>
              </ul>
            </.panel>
          </main>

          <aside class="space-y-4">
            <.panel title="Next action">
              <.form
                for={@next_action_form}
                id="next-action-form"
                phx-submit="update_next_action"
                class="space-y-2"
              >
                <.input field={@next_action_form[:next_action]} type="textarea" rows="3" />
                <.button type="submit" variant="primary">Save</.button>
              </.form>
            </.panel>

            <.panel title="Transitions">
              <.disclosure title="Lifecycle" subtitle="Operator-confirmed stage transition." open>
                <.form
                  for={@lifecycle_form}
                  id="lifecycle-form"
                  phx-submit="transition_lifecycle"
                  class="space-y-2"
                >
                  <.input
                    field={@lifecycle_form[:lifecycle_stage]}
                    type="select"
                    label="Stage"
                    options={Factory.options(Factory.lifecycle_stages())}
                    value={@app.lifecycle_stage}
                  />
                  <.input field={@lifecycle_form[:note]} label="Note" required />
                  <.button type="submit" variant="primary">Transition</.button>
                </.form>
              </.disclosure>

              <.disclosure title="Business posture" subtitle="Grow, maintain, fix, harvest, kill.">
                <.form
                  for={@posture_form}
                  id="posture-form"
                  phx-submit="transition_posture"
                  class="space-y-2"
                >
                  <.input
                    field={@posture_form[:business_posture]}
                    type="select"
                    label="Posture"
                    options={Factory.options(Factory.business_postures())}
                    value={@app.business_posture}
                  />
                  <.input field={@posture_form[:note]} label="Note" required />
                  <.button type="submit" variant="primary">Transition</.button>
                </.form>
              </.disclosure>
            </.panel>
          </aside>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
