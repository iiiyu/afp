# @input  - Ticket filters, manual ticket transition params, and packet form params
# @output - Ticket board and harness packet builder LiveView
# @pos    - Work-management surface separating ticket state from harness contracts
defmodule AfpWeb.BoardLive do
  use AfpWeb, :live_view

  alias Afp.Factory
  alias Afp.Factory.Evidence
  alias Afp.Factory.Events
  alias Afp.Factory.Portfolio
  alias Afp.Factory.Work
  alias Afp.Factory.Work.HarnessPacket

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: Events.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Board")
     |> assign(:filters, params)
     |> assign(:filter_form, to_form(params, as: :filters))
     |> assign(:packet_form, to_form(Work.change_harness_packet(%HarnessPacket{})))
     |> load_board(params)}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:filter_form, to_form(filters, as: :filters))
     |> load_board(filters)}
  end

  def handle_event("move_ticket", %{"ticket_id" => ticket_id, "ticket" => params}, socket) do
    move_ticket(socket, ticket_id, params["status"], params)
  end

  def handle_event("drop_ticket", %{"ticket_id" => ticket_id, "status" => status}, socket) do
    move_ticket(socket, ticket_id, status, %{})
  end

  def handle_event("create_packet", %{"packet" => packet_params}, socket) do
    ticket = Work.get_ticket(packet_params["ticket_id"])

    result =
      if ticket do
        Work.create_harness_packet_from_ticket(ticket, packet_params)
      else
        Work.create_harness_packet(packet_params)
      end

    case result do
      {:ok, _packet} ->
        {:noreply,
         socket
         |> put_flash(:info, "Harness packet created.")
         |> assign(:packet_form, to_form(Work.change_harness_packet(%HarnessPacket{})))
         |> load_board(socket.assigns.filters)}

      {:error, changeset} ->
        {:noreply, assign(socket, :packet_form, to_form(changeset))}
    end
  end

  def handle_event("launch_packet", %{"packet-id" => packet_id}, socket) do
    packet = Work.get_harness_packet!(packet_id)

    case Work.mark_harness_packet_launched(packet) do
      {:ok, _packet} ->
        {:noreply,
         socket
         |> put_flash(:info, "Harness packet marked launched.")
         |> load_board(socket.assigns.filters)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not launch harness packet.")}
    end
  end

  @impl true
  def handle_info({:factory_event, _event}, socket) do
    {:noreply, load_board(socket, socket.assigns.filters)}
  end

  defp load_board(socket, filters) do
    tickets =
      filters
      |> Work.list_tickets()
      |> apply_posture_filter(filters["business_posture"])

    socket
    |> assign(:tickets, tickets)
    |> assign(:harness_packets, Work.list_harness_packets() |> Enum.take(6))
    |> assign(:grouped_tickets, Enum.group_by(tickets, & &1.status))
    |> assign(:app_options, Portfolio.list_app_options())
    |> assign(:ticket_options, Enum.map(tickets, &{&1.title, &1.id}))
    |> assign(:evidence_counts, Map.new(tickets, &{&1.id, Evidence.count_links("ticket", &1.id)}))
  end

  defp apply_posture_filter(tickets, posture) when posture in [nil, ""], do: tickets

  defp apply_posture_filter(tickets, posture),
    do: Enum.filter(tickets, &(&1.app && &1.app.business_posture == posture))

  defp move_ticket(socket, ticket_id, target_status, attrs) do
    ticket = Work.get_ticket!(ticket_id)

    if ticket.status == target_status do
      {:noreply, socket}
    else
      case Work.transition_ticket(ticket, target_status, attrs) do
        {:ok, _ticket} ->
          {:noreply,
           socket |> put_flash(:info, "Ticket moved.") |> load_board(socket.assigns.filters)}

        {:error, :blocked_reason_required} ->
          {:noreply, put_flash(socket, :error, "Blocked tickets require a blocked reason.")}

        {:error, :review_or_evidence_required} ->
          {:noreply, put_flash(socket, :error, "Done requires a review note or linked evidence.")}

        {:error, :note_required} ->
          {:noreply, put_flash(socket, :error, "This transition requires a note.")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Ticket transition is not allowed.")}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-4">
        <.page_header
          eyebrow="Work routing"
          title="Board"
          subtitle="Ticket workflow, packet creation, and recent handoff state."
        >
          <:meta>
            <.summary_item title="Tickets" value={length(@tickets)} hint="current board" />
            <.summary_item
              title="Packets"
              value={length(@harness_packets)}
              hint="recent handoffs"
            />
          </:meta>
        </.page_header>

        <div class="space-y-4">
          <.panel title="Ticket Board">
            <:subtitle>
              Draggable ticket columns with evidence-aware done and blocked transitions.
            </:subtitle>
            <.form
              for={@filter_form}
              id="board-filter-form"
              phx-submit="filter"
              class="mb-4 grid gap-2 md:grid-cols-4"
            >
              <.input
                field={@filter_form[:app_id]}
                type="select"
                label="App"
                prompt="All"
                options={@app_options}
              />
              <.input
                field={@filter_form[:lifecycle_gate]}
                type="select"
                label="Lifecycle gate"
                prompt="All"
                options={Factory.options(Factory.lifecycle_stages())}
              />
              <.input
                field={@filter_form[:business_posture]}
                type="select"
                label="Business posture"
                prompt="All"
                options={Factory.options(Factory.business_postures())}
              />
              <.button
                type="submit"
                class="mt-5 inline-flex items-center justify-center gap-2 rounded border border-slate-300 px-3 py-2 text-sm font-medium hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800"
              >
                <.icon name="hero-funnel" class="size-4" /> Filter
              </.button>
            </.form>

            <div
              id="ticket-board"
              phx-hook="TicketBoardDrag"
              class="grid min-h-[520px] gap-3 overflow-x-auto xl:grid-cols-7"
            >
              <section
                :for={status <- Factory.ticket_statuses()}
                id={"ticket-column-#{status}"}
                data-ticket-drop-status={status}
                class="min-w-0 rounded border border-slate-200 bg-slate-50 dark:border-slate-800 dark:bg-slate-950"
              >
                <header class="flex items-center justify-between border-b border-slate-200 px-3 py-2 dark:border-slate-800">
                  <h2 class="text-sm font-semibold">{Factory.labelize(status)}</h2>
                  <span class="text-xs text-slate-500">
                    {length(Map.get(@grouped_tickets, status, []))}
                  </span>
                </header>
                <div
                  id={"ticket-column-body-#{status}"}
                  data-ticket-drop-status={status}
                  class="space-y-2 p-2 transition-colors"
                >
                  <div
                    :if={Map.get(@grouped_tickets, status, []) == []}
                    class="rounded border border-dashed border-slate-300 p-3 text-center text-xs text-slate-500 dark:border-slate-700"
                  >
                    Empty
                  </div>
                  <article
                    :for={ticket <- Map.get(@grouped_tickets, status, [])}
                    id={"ticket-card-#{ticket.id}"}
                    data-ticket-card
                    data-ticket-id={ticket.id}
                    data-ticket-status={ticket.status}
                    draggable="true"
                    class="cursor-grab rounded border border-slate-200 bg-white p-3 text-sm shadow-sm transition hover:border-slate-300 active:cursor-grabbing dark:border-slate-800 dark:bg-slate-900 dark:hover:border-slate-700"
                  >
                    <div class="flex items-start justify-between gap-2">
                      <div class="min-w-0 font-medium leading-snug">{ticket.title}</div>
                      <.status_badge status={ticket.risk_level} />
                    </div>
                    <div class="mt-1 text-xs text-slate-500">
                      {ticket.app.name} · {ticket.lifecycle_gate || "No gate"}
                    </div>
                    <div class="mt-2 flex flex-wrap gap-2 text-xs text-slate-500">
                      <span>{length(ticket.codex_sessions)} sessions</span>
                      <span>{@evidence_counts[ticket.id]} evidence</span>
                      <span>{length(ticket.harness_packets)} packets</span>
                    </div>
                    <.disclosure
                      title="Move ticket"
                      subtitle="Target status, review note, and blocked reason."
                      class="mt-3"
                    >
                      <.form
                        for={to_form(%{}, as: :ticket)}
                        id={"move-ticket-#{ticket.id}"}
                        phx-submit="move_ticket"
                        class="space-y-2"
                      >
                        <input type="hidden" name="ticket_id" value={ticket.id} />
                        <.input
                          name="ticket[status]"
                          id={"ticket-status-#{ticket.id}"}
                          type="select"
                          label="Move to"
                          options={Factory.options(Factory.ticket_statuses())}
                          value={ticket.status}
                        />
                        <.input
                          name="ticket[review_note]"
                          id={"ticket-review-note-#{ticket.id}"}
                          label="Review note"
                        />
                        <.input
                          name="ticket[blocked_reason]"
                          id={"ticket-blocked-reason-#{ticket.id}"}
                          label="Blocked reason"
                        />
                        <button class="inline-flex items-center gap-1 rounded border border-slate-300 px-2 py-1 text-xs font-medium hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800">
                          Move
                        </button>
                      </.form>
                    </.disclosure>
                  </article>
                </div>
              </section>
            </div>
          </.panel>

          <div class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(360px,0.8fr)]">
            <.panel title="Board Actions">
              <.disclosure
                title="Harness Packet Builder"
                subtitle="Execution context, output, verification, and review route."
                open
              >
                <.form
                  for={@packet_form}
                  id="board-packet-form"
                  phx-submit="create_packet"
                  class="space-y-2"
                >
                  <.input
                    field={@packet_form[:ticket_id]}
                    type="select"
                    label="Ticket"
                    prompt="Manual packet"
                    options={@ticket_options}
                  />
                  <.input
                    field={@packet_form[:app_id]}
                    type="select"
                    label="App"
                    prompt="Choose app"
                    options={@app_options}
                  />
                  <.input
                    field={@packet_form[:state]}
                    type="select"
                    label="State"
                    options={Factory.options(Factory.packet_states())}
                    value="draft"
                  />
                  <.input
                    field={@packet_form[:objective]}
                    type="textarea"
                    label="Objective"
                    rows="3"
                  />
                  <.input
                    field={@packet_form[:expected_output]}
                    type="textarea"
                    label="Expected output"
                    rows="3"
                  />
                  <.input
                    field={@packet_form[:verification_plan]}
                    type="textarea"
                    label="Verification plan"
                    rows="3"
                  />
                  <.input field={@packet_form[:review_route]} label="Review route" />
                  <.input
                    field={@packet_form[:risk_level]}
                    type="select"
                    label="Risk"
                    options={Factory.options(Factory.risk_levels())}
                    value="normal"
                  />
                  <.disclosure
                    title="Advanced packet fields"
                    subtitle="Context, constraints, and evidence details."
                  >
                    <.input
                      field={@packet_form[:context_inputs]}
                      type="textarea"
                      label="Context inputs"
                      rows="3"
                    />
                    <.input
                      field={@packet_form[:constraints]}
                      type="textarea"
                      label="Constraints"
                      rows="3"
                    />
                    <.input
                      field={@packet_form[:required_evidence]}
                      type="textarea"
                      label="Required evidence"
                      rows="3"
                    />
                  </.disclosure>
                  <.button type="submit" variant="primary">
                    <.icon name="hero-document-plus" class="size-4" /> Save packet
                  </.button>
                </.form>
              </.disclosure>
            </.panel>

            <.panel title="Recent Harness Handoffs">
              <:subtitle>
                Copyable packet text and launch state.
              </:subtitle>
              <div :if={@harness_packets == []}>
                <.empty_state message="No harness packets yet." />
              </div>
              <div class="space-y-3">
                <article
                  :for={packet <- @harness_packets}
                  class="rounded border border-slate-200 p-3 dark:border-slate-800"
                >
                  <div class="mb-2 flex items-start justify-between gap-3">
                    <div class="min-w-0">
                      <div class="truncate text-sm font-semibold">{packet.objective}</div>
                      <div class="text-xs text-slate-500">
                        {packet.app.name} · {packet.state} · {packet.risk_level}
                      </div>
                    </div>
                    <button
                      type="button"
                      phx-click="launch_packet"
                      phx-value-packet-id={packet.id}
                      class="rounded border border-slate-300 px-2 py-1 text-xs font-medium hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800"
                    >
                      Launch
                    </button>
                  </div>
                  <.disclosure title="Handoff text" subtitle="Packet text for external execution.">
                    <textarea
                      id={"handoff-#{packet.id}"}
                      readonly
                      rows="10"
                      class="w-full rounded border border-slate-300 bg-slate-50 p-3 font-mono text-xs text-slate-700 dark:border-slate-700 dark:bg-slate-950 dark:text-slate-200"
                    ><%= Work.handoff_text(packet) %></textarea>
                  </.disclosure>
                </article>
              </div>
            </.panel>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
