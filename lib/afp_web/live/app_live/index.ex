# @input  - Portfolio filters and app creation form params
# @output - App portfolio LiveView
# @pos    - Scannable app inventory surface for lifecycle and next-action state
defmodule AfpWeb.AppLive.Index do
  use AfpWeb, :live_view

  alias Afp.Factory
  alias Afp.Factory.Dashboard
  alias Afp.Factory.Events
  alias Afp.Factory.Portfolio
  alias Afp.Factory.Portfolio.App

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Apps")
     |> assign(:app_form, to_form(Portfolio.change_app(%App{})))
     |> assign(:filter_form, to_form(%{}, as: :filters))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = filters_from_params(params)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:filter_form, to_form(filters, as: :filters))
     |> load_apps(filters)}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: ~p"/apps?#{filters_from_params(filters)}")}
  end

  def handle_event("create_app", %{"app" => app_params}, socket) do
    case Portfolio.create_app(app_params) do
      {:ok, _app} ->
        {:noreply,
         socket
         |> put_flash(:info, "App added.")
         |> assign(:app_form, to_form(Portfolio.change_app(%App{})))
         |> load_apps(socket.assigns.filters)}

      {:error, changeset} ->
        {:noreply, assign(socket, :app_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_info({:factory_event, _event}, socket) do
    {:noreply, load_apps(socket, socket.assigns.filters)}
  end

  defp load_apps(socket, filters) do
    apps = Portfolio.list_apps(filters)

    socket
    |> assign(:apps, apps)
    |> assign(:ticket_counts, Map.new(apps, &{&1.id, Dashboard.active_ticket_count(&1.id)}))
    |> assign(:session_counts, Map.new(apps, &{&1.id, Dashboard.active_session_count(&1.id)}))
  end

  defp filters_from_params(params) do
    %{
      "lifecycle_stage" => Map.get(params, "lifecycle_stage", ""),
      "business_posture" => Map.get(params, "business_posture", ""),
      "health_state" => Map.get(params, "health_state", ""),
      "platform" => Map.get(params, "platform", ""),
      "stale" => Map.get(params, "stale", ""),
      "sort" => Map.get(params, "sort", "last_activity"),
      "include_archived" => Map.get(params, "include_archived", "false")
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp platform_text(platforms), do: Enum.join(platforms || [], ", ")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-4">
        <.page_header
          eyebrow="Portfolio"
          title="Apps"
          subtitle="Lifecycle, posture, health, current action, and active work state."
        >
          <:meta>
            <.summary_item title="Visible apps" value={length(@apps)} hint="current filters" />
            <.summary_item
              title="Attention"
              value={
                Enum.count(
                  @apps,
                  &(&1.health_state in ["needs_next_action", "repo_missing", "repo_dirty", "blocked"])
                )
              }
              hint="health flags"
            />
          </:meta>
        </.page_header>

        <div class="grid gap-4 xl:grid-cols-[minmax(0,1.4fr)_380px]">
          <main class="space-y-4">
            <.panel title="Portfolio">
              <:subtitle>
                Inventory view for lifecycle, health, current action, and active work.
              </:subtitle>
              <:actions>
                <span class="text-xs text-slate-500">{length(@apps)} apps</span>
              </:actions>

              <.disclosure
                title="Filters and sorting"
                subtitle="Lifecycle, posture, health, attention, and sorting controls."
                open={map_size(@filters) > 1}
              >
                <.form
                  for={@filter_form}
                  id="app-filter-form"
                  phx-submit="filter"
                  class="grid gap-2 md:grid-cols-7"
                >
                  <.input
                    field={@filter_form[:lifecycle_stage]}
                    type="select"
                    label="Lifecycle"
                    prompt="All"
                    options={Factory.options(Factory.lifecycle_stages())}
                  />
                  <.input
                    field={@filter_form[:business_posture]}
                    type="select"
                    label="Posture"
                    prompt="All"
                    options={Factory.options(Factory.business_postures())}
                  />
                  <.input
                    field={@filter_form[:health_state]}
                    type="select"
                    label="Health"
                    prompt="All"
                    options={Factory.options(Factory.health_states())}
                  />
                  <.input field={@filter_form[:platform]} label="Platform" placeholder="ios" />
                  <.input
                    field={@filter_form[:stale]}
                    type="select"
                    label="Attention"
                    prompt="All"
                    options={[
                      {"Missing next action", "missing_next_action"},
                      {"Invalid repo", "invalid_repo"}
                    ]}
                  />
                  <.input
                    field={@filter_form[:sort]}
                    type="select"
                    label="Sort"
                    options={[
                      {"Last activity", "last_activity"},
                      {"Name", "name"},
                      {"Lifecycle", "lifecycle"},
                      {"Posture", "posture"},
                      {"Health", "health"}
                    ]}
                  />
                  <.button
                    type="submit"
                    class="mt-5 inline-flex items-center justify-center gap-2 rounded border border-slate-300 px-3 py-2 text-sm font-medium hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800"
                  >
                    <.icon name="hero-funnel" class="size-4" /> Filter
                  </.button>
                </.form>
              </.disclosure>

              <div class="overflow-x-auto">
                <table class="min-w-full text-left text-sm">
                  <thead class="border-y border-slate-200 bg-slate-50 text-xs uppercase tracking-wide text-slate-500 dark:border-slate-800 dark:bg-slate-950">
                    <tr>
                      <th class="px-2 py-2">App</th>
                      <th class="px-2 py-2">Lifecycle</th>
                      <th class="px-2 py-2">Posture</th>
                      <th class="px-2 py-2">Health</th>
                      <th class="px-2 py-2">Platform</th>
                      <th class="px-2 py-2">Next action</th>
                      <th class="px-2 py-2">Work</th>
                      <th class="px-2 py-2">Last activity</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-slate-100 dark:divide-slate-800">
                    <tr :for={app <- @apps} class="hover:bg-slate-50 dark:hover:bg-slate-950/80">
                      <td class="max-w-56 px-2 py-2">
                        <.link
                          navigate={~p"/apps/#{app.id}?#{@filters}"}
                          class="font-medium text-slate-950 hover:underline dark:text-white"
                        >
                          {app.name}
                        </.link>
                        <div class="truncate text-xs text-slate-500">
                          {app.repo_path || "No repository path"}
                        </div>
                      </td>
                      <td class="px-2 py-2"><.status_badge status={app.lifecycle_stage} /></td>
                      <td class="px-2 py-2"><.status_badge status={app.business_posture} /></td>
                      <td class="px-2 py-2"><.status_badge status={app.health_state} /></td>
                      <td class="px-2 py-2 text-slate-600 dark:text-slate-300">
                        {platform_text(app.platforms)}
                      </td>
                      <td class="max-w-80 px-2 py-2 text-slate-600 dark:text-slate-300">
                        {app.next_action || "Missing next action"}
                      </td>
                      <td class="px-2 py-2 text-xs text-slate-500">
                        {@ticket_counts[app.id]} tickets · {@session_counts[app.id]} sessions
                      </td>
                      <td class="px-2 py-2 text-xs text-slate-500">
                        {format_datetime(app.last_activity_at)}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </.panel>
          </main>

          <aside>
            <.panel title="Portfolio Actions">
              <.disclosure
                title="Add App"
                subtitle="App shell, repository path, lifecycle, and next action."
                open
              >
                <.form for={@app_form} id="app-form" phx-submit="create_app" class="space-y-2">
                  <.input field={@app_form[:name]} label="Name" required />
                  <.input
                    field={@app_form[:repo_path]}
                    label="Repository path"
                    placeholder="/Users/ewan/Developer/Apps/MyApp"
                  />
                  <.input
                    field={@app_form[:platforms]}
                    label="Platforms"
                    placeholder="ios, macos, web"
                  />
                  <.input
                    field={@app_form[:lifecycle_stage]}
                    type="select"
                    label="Lifecycle"
                    options={Factory.options(Factory.lifecycle_stages())}
                  />
                  <.input
                    field={@app_form[:business_posture]}
                    type="select"
                    label="Business posture"
                    options={Factory.options(Factory.business_postures())}
                  />
                  <.input
                    field={@app_form[:next_action]}
                    type="textarea"
                    label="Next action"
                    rows="3"
                  />
                  <.input
                    field={@app_form[:product_thesis]}
                    type="textarea"
                    label="Product thesis"
                    rows="4"
                    placeholder="Problem, promise, target user, business case"
                  />
                  <.button type="submit" variant="primary">
                    <.icon name="hero-plus" class="size-4" /> Add app
                  </.button>
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
