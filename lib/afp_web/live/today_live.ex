# @input  - Factory dashboard read model and quick ticket form params
# @output - Today command center LiveView
# @pos    - Primary operating surface for deciding what needs attention now
defmodule AfpWeb.TodayLive do
  use AfpWeb, :live_view

  alias Afp.Factory.Dashboard
  alias Afp.Factory.Events
  alias Afp.Factory.Portfolio
  alias Afp.Factory.Work

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Today")
     |> assign(:ticket_form, to_form(%{}, as: :ticket))
     |> load_dashboard()}
  end

  @impl true
  def handle_event("create_ticket", %{"ticket" => ticket_params}, socket) do
    case Work.create_ticket(ticket_params) do
      {:ok, _ticket} ->
        {:noreply,
         socket
         |> put_flash(:info, "Ticket created.")
         |> assign(:ticket_form, to_form(%{}, as: :ticket))
         |> load_dashboard()}

      {:error, changeset} ->
        {:noreply, assign(socket, :ticket_form, to_form(changeset))}
    end
  end

  def handle_event("create_focus_ticket", %{"app-id" => app_id, "title" => title}, socket) do
    app = Portfolio.get_app(app_id)

    attrs = %{
      "app_id" => app_id,
      "title" => title,
      "status" => "ready",
      "lifecycle_gate" => app && app.lifecycle_stage
    }

    case Work.create_ticket(attrs) do
      {:ok, _ticket} ->
        {:noreply, socket |> put_flash(:info, "Focus ticket created.") |> load_dashboard()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create focus ticket.")}
    end
  end

  @impl true
  def handle_info({:factory_event, _event}, socket) do
    {:noreply, load_dashboard(socket)}
  end

  defp load_dashboard(socket) do
    snapshot = Dashboard.today()

    socket
    |> assign(:dashboard, snapshot)
    |> assign(:app_options, Portfolio.list_app_options())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-4">
        <.page_header
          eyebrow="Command center"
          title="Today"
          subtitle="Highest-priority work, active app continuity, and supporting operational queues."
        >
          <:meta>
            <.summary_item
              title="Focus"
              value={length(@dashboard.focus_queue)}
              hint="ranked now"
            />
            <.summary_item
              title="Review"
              value={length(@dashboard.review_sessions)}
              hint="stopped sessions"
            />
            <.summary_item
              title="Portfolio"
              value={length(@dashboard.active_apps)}
              hint="active apps"
            />
          </:meta>
        </.page_header>

        <div class="grid gap-4 2xl:grid-cols-[minmax(0,1.55fr)_minmax(360px,0.85fr)]">
          <main class="space-y-4">
            <.panel title="Focus Queue">
              <:subtitle>
                Ranked work with reason, route, and ticket capture.
              </:subtitle>
              <div :if={@dashboard.focus_queue == []}>
                <.empty_state message="No urgent focus items. Active apps and next actions are still listed below." />
              </div>
              <div class="divide-y divide-slate-100 dark:divide-slate-800">
                <div
                  :for={item <- @dashboard.focus_queue}
                  class="flex flex-col gap-3 py-3 sm:flex-row sm:items-start sm:justify-between"
                >
                  <div class="min-w-0">
                    <div class="grid max-w-full gap-2 sm:flex sm:flex-wrap sm:items-center">
                      <span class="text-sm font-semibold">{item.title}</span>
                      <.status_badge status={item.reason} class="justify-self-start" />
                      <.status_badge
                        :if={item[:app]}
                        status={item.app.lifecycle_stage}
                        class="justify-self-start"
                      />
                    </div>
                    <p class="mt-1 truncate text-sm text-slate-600 dark:text-slate-300">
                      {item.detail}
                    </p>
                  </div>
                  <div class="flex shrink-0 items-center gap-2 self-start sm:self-auto">
                    <.link
                      navigate={item.link}
                      class="rounded border border-slate-300 px-2 py-1 text-xs font-medium hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800"
                    >
                      Open
                    </.link>
                    <button
                      :if={item[:app]}
                      type="button"
                      phx-click="create_focus_ticket"
                      phx-value-app-id={item.app.id}
                      phx-value-title={item.title}
                      class="rounded border border-slate-950 bg-slate-950 px-2 py-1 text-xs font-medium text-white hover:bg-slate-800 dark:border-white dark:bg-white dark:text-slate-950"
                    >
                      Ticket
                    </button>
                  </div>
                </div>
              </div>
            </.panel>

            <.panel title="Active Apps And Next Actions">
              <:subtitle>
                Active portfolio continuity and next-action state.
              </:subtitle>
              <div class="overflow-x-auto">
                <table class="min-w-full text-left text-sm">
                  <thead class="text-xs uppercase tracking-wide text-slate-500">
                    <tr>
                      <th class="px-2 py-2">App</th>
                      <th class="px-2 py-2">Lifecycle</th>
                      <th class="px-2 py-2">Posture</th>
                      <th class="px-2 py-2">Next action</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-slate-100 dark:divide-slate-800">
                    <tr
                      :for={app <- @dashboard.active_apps}
                      class="hover:bg-slate-50 dark:hover:bg-slate-900"
                    >
                      <td class="px-2 py-2 font-medium">
                        <.link navigate={~p"/apps/#{app.id}"}>{app.name}</.link>
                      </td>
                      <td class="px-2 py-2"><.status_badge status={app.lifecycle_stage} /></td>
                      <td class="px-2 py-2"><.status_badge status={app.business_posture} /></td>
                      <td class="px-2 py-2 text-slate-600 dark:text-slate-300">
                        {app.next_action || "Missing next action"}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </.panel>
          </main>

          <aside class="space-y-4">
            <.panel title="Quick Create Ticket">
              <:subtitle>Board-ready work capture.</:subtitle>
              <.form
                for={@ticket_form}
                id="today-ticket-form"
                phx-submit="create_ticket"
                class="space-y-2"
              >
                <.input
                  field={@ticket_form[:app_id]}
                  type="select"
                  label="App"
                  options={@app_options}
                  prompt="Choose app"
                />
                <.input field={@ticket_form[:title]} label="Title" required />
                <.input
                  field={@ticket_form[:status]}
                  type="select"
                  label="Status"
                  options={Afp.Factory.options(Afp.Factory.ticket_statuses())}
                  value="ready"
                />
                <.input
                  field={@ticket_form[:risk_level]}
                  type="select"
                  label="Risk"
                  options={Afp.Factory.options(Afp.Factory.risk_levels())}
                  value="normal"
                />
                <.button type="submit" variant="primary">
                  <.icon name="hero-plus" class="size-4" /> Create
                </.button>
              </.form>
            </.panel>

            <.panel title="Supporting Queues">
              <:subtitle>
                Review, release, business, and repository queues.
              </:subtitle>

              <.disclosure
                title="Stopped sessions"
                subtitle={"#{length(@dashboard.review_sessions)} waiting for review"}
                open={length(@dashboard.review_sessions) > 0}
              >
                <div :if={@dashboard.review_sessions == []}>
                  <.empty_state message="No stopped sessions need review." />
                </div>
                <div
                  :for={session <- @dashboard.review_sessions}
                  class="mb-2 rounded border border-amber-200 bg-amber-50 p-3 text-sm dark:border-amber-900 dark:bg-amber-950"
                >
                  <div class="font-medium">{session.external_session_id}</div>
                  <div class="text-slate-600 dark:text-slate-300">
                    {(session.app && session.app.name) || session.cwd || "Unlinked"}
                  </div>
                </div>
              </.disclosure>

              <.disclosure
                title="Release blockers"
                subtitle={"#{length(@dashboard.release_blockers)} failed or blocked releases"}
                open={length(@dashboard.release_blockers) > 0}
              >
                <div :if={@dashboard.release_blockers == []}>
                  <.empty_state message="No release blockers." />
                </div>
                <div
                  :for={release <- @dashboard.release_blockers}
                  class="mb-2 rounded border border-red-200 bg-red-50 p-3 text-sm dark:border-red-900 dark:bg-red-950"
                >
                  <div class="font-medium">{release.app.name} · {release.platform}</div>
                  <div class="text-slate-600 dark:text-slate-300">
                    {release.version || release.label} · {release.status}
                  </div>
                </div>
              </.disclosure>

              <.disclosure
                title="Demand validation"
                subtitle={"#{length(@dashboard.active_demand_items)} opportunities before app promotion"}
                open={length(@dashboard.active_demand_items) > 0}
              >
                <div :if={@dashboard.active_demand_items == []}>
                  <.empty_state message="No active demand items need validation." />
                </div>
                <div
                  :for={demand_item <- @dashboard.active_demand_items}
                  class="mb-2 rounded border border-slate-200 p-3 text-sm dark:border-slate-800"
                >
                  <div class="flex items-center justify-between gap-2">
                    <div class="min-w-0 font-medium">{demand_item.title}</div>
                    <.status_badge status={demand_item.status} />
                  </div>
                  <div class="mt-1 text-xs text-slate-500">
                    {demand_item.validation_action}
                  </div>
                </div>
              </.disclosure>

              <.disclosure
                title="Maintenance and growth"
                subtitle={"#{length(@dashboard.due_maintenance)} obligations, #{length(@dashboard.review_experiments)} experiments"}
              >
                <div :if={@dashboard.due_maintenance == [] and @dashboard.review_experiments == []}>
                  <.empty_state message="No maintenance or growth reviews are due." />
                </div>
                <div
                  :for={obligation <- @dashboard.due_maintenance}
                  class="mb-2 rounded border border-slate-200 p-3 text-sm dark:border-slate-800"
                >
                  <div class="font-medium">{obligation.title}</div>
                  <div class="text-slate-500">
                    {obligation.app.name} · {obligation.category} · {obligation.due_on}
                  </div>
                </div>
                <div
                  :for={experiment <- @dashboard.review_experiments}
                  class="mb-2 rounded border border-slate-200 p-3 text-sm dark:border-slate-800"
                >
                  <div class="font-medium">{experiment.title}</div>
                  <div class="text-slate-500">
                    {experiment.app.name} · {experiment.metric || "No metric"} · {experiment.review_due_on}
                  </div>
                </div>
              </.disclosure>

              <.disclosure
                title="Operational signals"
                subtitle={"#{length(@dashboard.repo_attention_scans)} repos, #{length(@dashboard.stale_metrics_apps)} stale snapshots, #{length(@dashboard.unlinked_sessions)} unlinked sessions"}
              >
                <div :if={
                  @dashboard.repo_attention_scans == [] and @dashboard.stale_metrics_apps == [] and
                    @dashboard.unlinked_sessions == []
                }>
                  <.empty_state message="No secondary operational signals." />
                </div>
                <div
                  :for={scan <- @dashboard.repo_attention_scans}
                  class="mb-2 rounded border border-slate-200 p-3 text-sm dark:border-slate-800"
                >
                  <div class="flex items-center justify-between gap-2">
                    <div class="min-w-0 font-medium">{scan.name || scan.repository_path}</div>
                    <.status_badge status={scan.status} />
                  </div>
                  <div class="mt-1 truncate text-xs text-slate-500">
                    {scan.repository_path}
                  </div>
                </div>
                <div
                  :for={app <- @dashboard.stale_metrics_apps}
                  class="mb-2 rounded border border-slate-200 p-3 text-sm dark:border-slate-800"
                >
                  <div class="font-medium">{app.name}</div>
                  <div class="text-slate-500">{app.business_posture}</div>
                </div>
                <div
                  :for={session <- @dashboard.unlinked_sessions}
                  class="mb-2 rounded border border-slate-200 p-3 text-sm dark:border-slate-800"
                >
                  <div class="font-medium">{session.external_session_id}</div>
                  <div class="truncate text-slate-500">{session.cwd || "Unknown cwd"}</div>
                </div>
              </.disclosure>
            </.panel>
          </aside>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
