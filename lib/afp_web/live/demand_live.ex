# @input  - Demand item, launch request, promotion, and filter form params
# @output - Demand management LiveView for pre-app research and promotion
# @pos    - UI layer before portfolio app lifecycle ownership begins
defmodule AfpWeb.DemandLive do
  use AfpWeb, :live_view

  alias Afp.Factory
  alias Afp.Factory.Demand
  alias Afp.Factory.Demand.CodexLaunchRequest
  alias Afp.Factory.Demand.DemandItem

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Demand")
     |> assign(:filters, params)
     |> assign(:filter_form, to_form(params, as: :filters))
     |> assign(:demand_form, to_form(Demand.change_demand_item(%DemandItem{})))
     |> assign(:launch_form, to_form(Demand.change_launch_request(%CodexLaunchRequest{})))
     |> assign(:promote_form, to_form(%{}, as: :promotion))
     |> load_demand(params)}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:filter_form, to_form(filters, as: :filters))
     |> load_demand(filters)}
  end

  def handle_event("create_demand", %{"demand_item" => params}, socket) do
    case Demand.create_demand_item(params) do
      {:ok, _demand_item} ->
        {:noreply,
         socket
         |> put_flash(:info, "Demand item created.")
         |> assign(:demand_form, to_form(Demand.change_demand_item(%DemandItem{})))
         |> load_demand(socket.assigns.filters)}

      {:error, changeset} ->
        {:noreply, assign(socket, :demand_form, to_form(changeset))}
    end
  end

  def handle_event("transition_demand", %{"demand_id" => demand_id, "demand" => params}, socket) do
    demand_item = Demand.get_demand_item!(demand_id)

    case Demand.transition_demand(demand_item, params["status"], params) do
      {:ok, _demand_item} ->
        {:noreply,
         socket
         |> put_flash(:info, "Demand item updated.")
         |> load_demand(socket.assigns.filters)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, first_error(changeset) || "Could not update demand item.")
         |> load_demand(socket.assigns.filters)}
    end
  end

  def handle_event("create_launch_request", %{"launch_request" => params}, socket) do
    if Factory.blank?(params["demand_item_id"]) do
      {:noreply, put_flash(socket, :error, "Choose a demand item first.")}
    else
      demand_item = Demand.get_demand_item!(params["demand_item_id"])

      case Demand.create_launch_request_from_demand(demand_item, params) do
        {:ok, _launch_request} ->
          {:noreply,
           socket
           |> put_flash(:info, "Launch request created.")
           |> assign(:launch_form, to_form(Demand.change_launch_request(%CodexLaunchRequest{})))
           |> load_demand(socket.assigns.filters)}

        {:error, changeset} ->
          {:noreply, assign(socket, :launch_form, to_form(changeset))}
      end
    end
  end

  def handle_event("promote_demand", %{"promotion" => params}, socket) do
    if Factory.blank?(params["demand_item_id"]) do
      {:noreply, put_flash(socket, :error, "Choose a validated demand item first.")}
    else
      demand_item = Demand.get_demand_item!(params["demand_item_id"])

      case Demand.promote_to_app(demand_item, params) do
        {:ok, _demand_item, app} ->
          {:noreply,
           socket
           |> put_flash(:info, "Demand promoted to #{app.name}.")
           |> assign(:promote_form, to_form(%{}, as: :promotion))
           |> load_demand(socket.assigns.filters)}

        {:error, :demand_not_validated} ->
          {:noreply,
           socket
           |> put_flash(:error, "Only validated demand can be promoted.")
           |> load_demand(socket.assigns.filters)}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, first_error(changeset) || "Could not promote demand item.")
           |> load_demand(socket.assigns.filters)}
      end
    end
  end

  defp load_demand(socket, filters) do
    demand_items = Demand.list_demand_items(filters)
    all_demand_items = Demand.list_demand_items()
    launch_requests = Demand.list_launch_requests()

    socket
    |> assign(:demand_items, demand_items)
    |> assign(:launch_requests, launch_requests)
    |> assign(
      :active_demand_items,
      Enum.filter(
        all_demand_items,
        &(&1.status in ["captured", "researching", "validating", "validated"])
      )
    )
    |> assign(:validated_demand_items, Enum.filter(all_demand_items, &(&1.status == "validated")))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-4">
        <.page_header
          eyebrow="Discovery"
          title="Demand"
          subtitle="Pre-app opportunities, validation actions, launch requests, and promotion into active apps."
        >
          <:meta>
            <.summary_item title="Demand items" value={length(@demand_items)} hint="current filters" />
            <.summary_item
              title="Active"
              value={length(@active_demand_items)}
              hint="before promotion"
            />
            <.summary_item
              title="Launch requests"
              value={length(@launch_requests)}
              hint="bounded handoffs"
            />
          </:meta>
        </.page_header>

        <div class="grid gap-4 2xl:grid-cols-[minmax(0,1fr)_420px]">
          <main class="space-y-4">
            <.panel title="Demand Pipeline">
              <:subtitle>
                Opportunities before repository commitment or app lifecycle ownership.
              </:subtitle>

              <.disclosure
                title="Filters"
                subtitle="Status, confidence, and source filters."
                open={map_size(@filters) > 0}
              >
                <.form
                  for={@filter_form}
                  id="demand-filter-form"
                  phx-submit="filter"
                  class="grid gap-2 md:grid-cols-4"
                >
                  <.input
                    field={@filter_form[:status]}
                    type="select"
                    label="Status"
                    prompt="All"
                    options={Factory.options(Factory.demand_statuses())}
                  />
                  <.input
                    field={@filter_form[:confidence]}
                    type="select"
                    label="Confidence"
                    prompt="All"
                    options={Factory.options(Factory.demand_confidences())}
                  />
                  <.input
                    field={@filter_form[:source]}
                    label="Source"
                    placeholder="App Store, Reddit"
                  />
                  <.button
                    type="submit"
                    class="mt-5 inline-flex items-center justify-center gap-2 rounded border border-slate-300 px-3 py-2 text-sm font-medium hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800"
                  >
                    <.icon name="hero-funnel" class="size-4" /> Filter
                  </.button>
                </.form>
              </.disclosure>

              <div :if={@demand_items == []}>
                <.empty_state message="No demand items yet." />
              </div>
              <div class="divide-y divide-slate-100 dark:divide-slate-800">
                <article :for={demand_item <- @demand_items} class="py-4">
                  <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                    <div class="min-w-0">
                      <div class="flex flex-wrap items-center gap-2">
                        <h2 class="text-sm font-semibold text-slate-950 dark:text-white">
                          {demand_item.title}
                        </h2>
                        <.status_badge status={demand_item.status} />
                        <.status_badge status={demand_item.confidence} />
                      </div>
                      <div class="mt-2 grid gap-2 text-sm text-slate-600 dark:text-slate-300 lg:grid-cols-2">
                        <div>
                          <span class="font-medium text-slate-900 dark:text-white">Target:</span>
                          {demand_item.target_user || demand_item.job_to_be_done || "Not set"}
                        </div>
                        <div>
                          <span class="font-medium text-slate-900 dark:text-white">Source:</span>
                          {demand_item.source || "Not set"}
                        </div>
                        <div>
                          <span class="font-medium text-slate-900 dark:text-white">Signal:</span>
                          {demand_item.demand_signal || "Not set"}
                        </div>
                        <div>
                          <span class="font-medium text-slate-900 dark:text-white">Weakness:</span>
                          {demand_item.incumbent_weakness || "Not set"}
                        </div>
                      </div>
                      <p class="mt-2 text-sm text-slate-700 dark:text-slate-200">
                        {demand_item.validation_action}
                      </p>
                      <p :if={demand_item.evidence_summary} class="mt-1 text-xs text-slate-500">
                        Evidence: {demand_item.evidence_summary}
                      </p>
                      <.link
                        :if={demand_item.promoted_app}
                        navigate={~p"/apps/#{demand_item.promoted_app_id}"}
                        class="mt-2 inline-flex text-xs font-medium text-slate-700 underline dark:text-slate-200"
                      >
                        Promoted app: {demand_item.promoted_app.name}
                      </.link>
                    </div>
                    <.form
                      for={to_form(%{}, as: :demand)}
                      id={"demand-transition-#{demand_item.id}"}
                      phx-submit="transition_demand"
                      class="w-full shrink-0 space-y-2 md:w-60"
                    >
                      <input type="hidden" name="demand_id" value={demand_item.id} />
                      <.input
                        name="demand[status]"
                        id={"demand-status-#{demand_item.id}"}
                        type="select"
                        label="Move to"
                        options={Factory.options(Factory.demand_statuses())}
                        value={demand_item.status}
                      />
                      <.input
                        name="demand[rejected_reason]"
                        id={"demand-rejected-reason-#{demand_item.id}"}
                        label="Rejected reason"
                      />
                      <.input
                        name="demand[parked_reason]"
                        id={"demand-parked-reason-#{demand_item.id}"}
                        label="Parked reason"
                      />
                      <button class="inline-flex items-center rounded border border-slate-300 px-2 py-1 text-xs font-medium hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800">
                        Update
                      </button>
                    </.form>
                  </div>
                </article>
              </div>
            </.panel>

            <.panel title="Launch Requests">
              <:subtitle>
                Manual Codex handoffs from demand validation work.
              </:subtitle>
              <div :if={@launch_requests == []}>
                <.empty_state message="No launch requests yet." />
              </div>
              <div class="grid gap-3 lg:grid-cols-2">
                <article
                  :for={request <- @launch_requests}
                  class="rounded border border-slate-200 p-3 text-sm dark:border-slate-800"
                >
                  <div class="flex items-start justify-between gap-2">
                    <div class="min-w-0">
                      <div class="font-semibold">{request.title}</div>
                      <div class="text-xs text-slate-500">
                        {request.source_type} · {request.status} · {request.risk_level}
                      </div>
                    </div>
                    <.status_badge status={request.status} />
                  </div>
                  <p class="mt-2 text-slate-600 dark:text-slate-300">{request.objective}</p>
                  <.disclosure title="Handoff text" subtitle="Manual launch packet.">
                    <textarea
                      readonly
                      rows="8"
                      class="w-full rounded border border-slate-300 bg-slate-50 p-3 font-mono text-xs text-slate-700 dark:border-slate-700 dark:bg-slate-950 dark:text-slate-200"
                    ><%= request.handoff_text %></textarea>
                  </.disclosure>
                </article>
              </div>
            </.panel>
          </main>

          <aside class="space-y-4">
            <.panel title="Demand Actions">
              <.disclosure
                title="Add Demand Item"
                subtitle="Capture source evidence, target user, wedge, and validation action."
                open
              >
                <.form
                  for={@demand_form}
                  id="demand-form"
                  phx-submit="create_demand"
                  class="space-y-2"
                >
                  <.input field={@demand_form[:title]} label="Title" required />
                  <.input
                    field={@demand_form[:status]}
                    type="select"
                    label="Status"
                    options={Factory.options(Factory.demand_statuses())}
                  />
                  <.input
                    field={@demand_form[:confidence]}
                    type="select"
                    label="Confidence"
                    options={Factory.options(Factory.demand_confidences())}
                  />
                  <.input field={@demand_form[:source]} label="Source" />
                  <.input field={@demand_form[:source_url]} label="Source URL" />
                  <.input field={@demand_form[:target_user]} label="Target user" />
                  <.input field={@demand_form[:job_to_be_done]} label="Job to be done" />
                  <.input
                    field={@demand_form[:demand_signal]}
                    type="textarea"
                    label="Demand signal"
                    rows="3"
                  />
                  <.input
                    field={@demand_form[:incumbent_weakness]}
                    type="textarea"
                    label="Incumbent weakness"
                    rows="3"
                  />
                  <.input
                    field={@demand_form[:wedge_hypothesis]}
                    type="textarea"
                    label="Wedge hypothesis"
                    rows="3"
                  />
                  <.input
                    field={@demand_form[:validation_action]}
                    type="textarea"
                    label="Validation action"
                    rows="3"
                    required
                  />
                  <.input
                    field={@demand_form[:evidence_summary]}
                    type="textarea"
                    label="Evidence summary"
                    rows="3"
                  />
                  <.button type="submit" variant="primary">
                    <.icon name="hero-plus" class="size-4" /> Add demand
                  </.button>
                </.form>
              </.disclosure>

              <.disclosure
                title="Create Launch Request"
                subtitle="Bounded manual Codex handoff for demand research."
              >
                <.form
                  for={@launch_form}
                  id="launch-request-form"
                  phx-submit="create_launch_request"
                  class="space-y-2"
                >
                  <.input
                    field={@launch_form[:demand_item_id]}
                    type="select"
                    label="Demand item"
                    prompt="Choose demand"
                    options={demand_options(@active_demand_items)}
                  />
                  <.input field={@launch_form[:title]} label="Title" />
                  <.input
                    field={@launch_form[:objective]}
                    type="textarea"
                    label="Objective"
                    rows="3"
                  />
                  <.input
                    field={@launch_form[:risk_level]}
                    type="select"
                    label="Risk"
                    options={Factory.options(Factory.risk_levels())}
                  />
                  <.input
                    field={@launch_form[:status]}
                    type="select"
                    label="Status"
                    options={Factory.options(Factory.launch_request_statuses())}
                  />
                  <.input field={@launch_form[:confirmation]} label="Confirmation" />
                  <.button type="submit" variant="primary">
                    <.icon name="hero-command-line" class="size-4" /> Create request
                  </.button>
                </.form>
              </.disclosure>

              <.disclosure
                title="Promote To App"
                subtitle="Turn validated demand into portfolio state."
              >
                <.form
                  for={@promote_form}
                  id="promote-demand-form"
                  phx-submit="promote_demand"
                  class="space-y-2"
                >
                  <.input
                    field={@promote_form[:demand_item_id]}
                    type="select"
                    label="Demand item"
                    prompt="Choose validated demand"
                    options={demand_options(@validated_demand_items)}
                  />
                  <.input field={@promote_form[:name]} label="App name" required />
                  <.input field={@promote_form[:repo_path]} label="Repository path" />
                  <.input
                    field={@promote_form[:platforms]}
                    label="Platforms"
                    placeholder="ios, macos, web"
                  />
                  <.input
                    field={@promote_form[:lifecycle_stage]}
                    type="select"
                    label="Lifecycle"
                    options={Factory.options(Factory.lifecycle_stages())}
                  />
                  <.input
                    field={@promote_form[:business_posture]}
                    type="select"
                    label="Business posture"
                    options={Factory.options(Factory.business_postures())}
                  />
                  <.button type="submit" variant="primary">
                    <.icon name="hero-arrow-up-right" class="size-4" /> Promote
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

  defp demand_options(demand_items), do: Enum.map(demand_items, &{&1.title, &1.id})

  defp first_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &"#{Factory.labelize(field)} #{&1}")
    end)
    |> List.first()
  end
end
