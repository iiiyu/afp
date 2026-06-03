# @input  - Metrics snapshot params and metrics read model
# @output - Metrics snapshot LiveView
# @pos    - Manual business-signal capture surface for live apps
defmodule AfpWeb.MetricsLive do
  use AfpWeb, :live_view

  alias Afp.Factory.Events
  alias Afp.Factory.Metrics
  alias Afp.Factory.Portfolio

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Metrics")
     |> assign(:metrics_form, to_form(%{"snapshot_date" => Date.utc_today()}, as: :metrics))
     |> load_metrics()}
  end

  @impl true
  def handle_event("create_metrics", %{"metrics" => params}, socket) do
    case Metrics.create_metrics_snapshot(params) do
      {:ok, _snapshot} ->
        {:noreply,
         socket
         |> put_flash(:info, "Metrics snapshot saved.")
         |> assign(:metrics_form, to_form(%{"snapshot_date" => Date.utc_today()}, as: :metrics))
         |> load_metrics()}

      {:error, changeset} ->
        {:noreply, assign(socket, :metrics_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_info({:factory_event, _event}, socket), do: {:noreply, load_metrics(socket)}

  defp load_metrics(socket) do
    socket
    |> assign(:snapshots, Metrics.list_metrics_snapshots())
    |> assign(:stale_apps, Metrics.apps_with_stale_metrics())
    |> assign(:app_options, Portfolio.list_app_options())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-4">
        <.page_header
          eyebrow="Business signals"
          title="Metrics"
          subtitle="Live app metric freshness, stored snapshots, and compact business inputs."
        >
          <:meta>
            <.summary_item title="Stale live apps" value={length(@stale_apps)} hint="need snapshot" />
            <.summary_item title="Snapshots" value={length(@snapshots)} hint="stored rows" />
          </:meta>
        </.page_header>

        <div class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_380px]">
          <main class="space-y-4">
            <.panel title="Stale Or Missing Live Metrics">
              <div :if={@stale_apps == []}>
                <.empty_state message="No live apps have stale metrics." />
              </div>
              <div
                :for={app <- @stale_apps}
                class="mb-2 rounded border border-amber-200 bg-amber-50 p-3 text-sm dark:border-amber-900 dark:bg-amber-950"
              >
                <div class="font-medium">{app.name}</div>
                <div class="text-slate-600 dark:text-slate-300">
                  {app.business_posture} · {app.next_action || "No next action"}
                </div>
              </div>
            </.panel>

            <.panel title="Metrics History">
              <.disclosure title="Metrics Snapshots" subtitle="Historical rows for trend inspection.">
                <div :if={@snapshots == []}>
                  <.empty_state message="No metrics snapshots yet." />
                </div>
                <div class="overflow-x-auto">
                  <table class="min-w-full text-left text-sm">
                    <thead class="border-y border-slate-200 bg-slate-50 text-xs uppercase tracking-wide text-slate-500 dark:border-slate-800 dark:bg-slate-950">
                      <tr>
                        <th class="px-2 py-2">App</th>
                        <th class="px-2 py-2">Date</th>
                        <th class="px-2 py-2">Downloads</th>
                        <th class="px-2 py-2">Revenue</th>
                        <th class="px-2 py-2">Rating</th>
                        <th class="px-2 py-2">Crashes</th>
                        <th class="px-2 py-2">Notes</th>
                      </tr>
                    </thead>
                    <tbody class="divide-y divide-slate-100 dark:divide-slate-800">
                      <tr
                        :for={snapshot <- @snapshots}
                        class="hover:bg-slate-50 dark:hover:bg-slate-950"
                      >
                        <td class="px-2 py-2 font-medium">{snapshot.app.name}</td>
                        <td class="px-2 py-2">{format_date(snapshot.snapshot_date)}</td>
                        <td class="px-2 py-2">{snapshot.downloads || "blank"}</td>
                        <td class="px-2 py-2">{snapshot.revenue || "blank"}</td>
                        <td class="px-2 py-2">{snapshot.rating || "blank"}</td>
                        <td class="px-2 py-2">{snapshot.crashes || "blank"}</td>
                        <td class="max-w-96 px-2 py-2 text-slate-600 dark:text-slate-300">
                          {snapshot.notes}
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </.disclosure>
            </.panel>
          </main>

          <aside>
            <.panel title="Metrics Actions">
              <.disclosure
                title="Add Metrics Snapshot"
                subtitle="Record the smallest useful business snapshot."
                open
              >
                <.form
                  for={@metrics_form}
                  id="metrics-form"
                  phx-submit="create_metrics"
                  class="space-y-2"
                >
                  <.input
                    field={@metrics_form[:app_id]}
                    type="select"
                    label="App"
                    prompt="Choose app"
                    options={@app_options}
                  />
                  <.input field={@metrics_form[:snapshot_date]} type="date" label="Snapshot date" />
                  <.input field={@metrics_form[:downloads]} type="number" label="Downloads" />
                  <.input field={@metrics_form[:revenue]} type="number" step="0.01" label="Revenue" />
                  <.input field={@metrics_form[:rating]} type="number" step="0.1" label="Rating" />
                  <.disclosure
                    title="Acquisition metrics"
                    subtitle="Traffic, conversion, trials, and subscriptions."
                  >
                    <.input field={@metrics_form[:impressions]} type="number" label="Impressions" />
                    <.input
                      field={@metrics_form[:product_page_views]}
                      type="number"
                      label="Product page views"
                    />
                    <.input
                      field={@metrics_form[:conversion_rate]}
                      type="number"
                      step="0.01"
                      label="Conversion rate"
                    />
                    <.input field={@metrics_form[:trials]} type="number" label="Trials" />
                    <.input field={@metrics_form[:subscriptions]} type="number" label="Subscriptions" />
                  </.disclosure>
                  <.disclosure title="Quality signals" subtitle="Support, crash, and review counters.">
                    <.input field={@metrics_form[:reviews_count]} type="number" label="Reviews count" />
                    <.input field={@metrics_form[:crashes]} type="number" label="Crashes" />
                    <.input
                      field={@metrics_form[:support_issues]}
                      type="number"
                      label="Support issues"
                    />
                  </.disclosure>
                  <.input field={@metrics_form[:notes]} type="textarea" label="Notes" rows="4" />
                  <.button type="submit" variant="primary">Save snapshot</.button>
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
