# @input  - Codex session link/review params and session read models
# @output - Session bridge LiveView
# @pos    - Operator surface for linking, ignoring, and reviewing Codex sessions
defmodule AfpWeb.SessionsLive do
  use AfpWeb, :live_view

  alias Afp.Factory.Events
  alias Afp.Factory.Portfolio
  alias Afp.Factory.Sessions
  alias Afp.Factory.Settings
  alias Afp.Factory.Work

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Sessions")
     |> assign(:link_form, to_form(%{}, as: :link))
     |> assign(:session_ticket_form, to_form(%{}, as: :session_ticket))
     |> load_sessions()}
  end

  @impl true
  def handle_event("link_session", %{"link" => params}, socket) do
    session = Sessions.get_session!(params["session_id"])

    case Sessions.link_session(
           session,
           params["app_id"],
           params["ticket_id"],
           params["link_reason"]
         ) do
      {:ok, _session} ->
        {:noreply, socket |> put_flash(:info, "Session linked.") |> load_sessions()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not link session.")}
    end
  end

  def handle_event("ignore_session", %{"id" => id}, socket) do
    session = Sessions.get_session!(id)

    case Sessions.mark_ignored(session, "Ignored from session bridge") do
      {:ok, _session} ->
        {:noreply, socket |> put_flash(:info, "Session ignored.") |> load_sessions()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not ignore session.")}
    end
  end

  def handle_event("review_session", %{"session_id" => id, "review" => params}, socket) do
    session = Sessions.get_session!(id)

    case Sessions.review_session(session, params) do
      {:ok, _session} ->
        {:noreply, socket |> put_flash(:info, "Session reviewed.") |> load_sessions()}

      {:error, :review_or_evidence_required} ->
        {:noreply, put_flash(socket, :error, "Pass requires a review note or linked evidence.")}

      {:error, :blocked_reason_required} ->
        {:noreply, put_flash(socket, :error, "Blocked review requires a blocked reason.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not review session.")}
    end
  end

  def handle_event("create_session_ticket", %{"session_ticket" => params}, socket) do
    session = Sessions.get_session!(params["session_id"])

    with {:ok, ticket} <-
           Work.create_ticket(%{
             "app_id" => params["app_id"],
             "title" => params["title"],
             "description" => "Created from Codex session #{session.external_session_id}.",
             "status" => "review",
             "risk_level" => "normal"
           }),
         {:ok, _session} <-
           Sessions.link_session(
             session,
             params["app_id"],
             ticket.id,
             "Created ticket from session"
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Ticket created and linked.")
       |> assign(:session_ticket_form, to_form(%{}, as: :session_ticket))
       |> load_sessions()}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not create linked ticket.")}
    end
  end

  @impl true
  def handle_info({:factory_event, _event}, socket), do: {:noreply, load_sessions(socket)}

  defp load_sessions(socket) do
    sessions = Sessions.list_sessions()
    tickets = Work.list_tickets()
    intake_settings = Settings.intake_settings()

    socket
    |> assign(:sessions, sessions)
    |> assign(:unlinked_sessions, Sessions.list_unlinked_sessions())
    |> assign(:review_sessions, Sessions.list_stopped_review_sessions())
    |> assign(:hook_events, Sessions.list_hook_events(20))
    |> assign(:app_options, Portfolio.list_app_options())
    |> assign(:session_options, Enum.map(sessions, &{&1.external_session_id, &1.id}))
    |> assign(:ticket_options, Enum.map(tickets, &{&1.title, &1.id}))
    |> assign(:show_transcript_paths, intake_settings["show_transcript_paths"])
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_420px]">
        <main class="space-y-4">
          <.panel title="Session Inbox">
            <:subtitle>
              Stopped sessions stay in review; session stop never marks a ticket done.
            </:subtitle>
            <div class="overflow-x-auto">
              <table class="min-w-full text-left text-sm">
                <thead class="border-y border-slate-200 bg-slate-50 text-xs uppercase tracking-wide text-slate-500 dark:border-slate-800 dark:bg-slate-950">
                  <tr>
                    <th class="px-2 py-2">Session</th>
                    <th class="px-2 py-2">Status</th>
                    <th class="px-2 py-2">App</th>
                    <th class="px-2 py-2">Tickets</th>
                    <th class="px-2 py-2">CWD</th>
                    <th class="px-2 py-2">Last seen</th>
                    <th class="px-2 py-2">Actions</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-slate-100 dark:divide-slate-800">
                  <tr
                    :for={session <- @sessions}
                    class="align-top hover:bg-slate-50 dark:hover:bg-slate-950"
                  >
                    <td class="px-2 py-2 font-medium">{session.external_session_id}</td>
                    <td class="px-2 py-2"><.status_badge status={session.status} /></td>
                    <td class="px-2 py-2">{(session.app && session.app.name) || "Unlinked"}</td>
                    <td class="px-2 py-2 text-xs text-slate-500">
                      {Enum.map_join(session.tickets, ", ", & &1.title)}
                    </td>
                    <td class="max-w-80 px-2 py-2">
                      <div class="truncate text-xs text-slate-500">{session.cwd}</div>
                      <div :if={@show_transcript_paths} class="truncate text-xs text-slate-400">
                        {session.transcript_path}
                      </div>
                    </td>
                    <td class="px-2 py-2 text-xs text-slate-500">
                      {format_datetime(session.last_seen_at)}
                    </td>
                    <td class="px-2 py-2">
                      <button
                        type="button"
                        phx-click="ignore_session"
                        phx-value-id={session.id}
                        class="rounded border border-slate-300 px-2 py-1 text-xs hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800"
                      >
                        Ignore
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </.panel>

          <.panel title="Review Stopped Sessions">
            <div :if={@review_sessions == []}>
              <.empty_state message="No stopped sessions waiting for review." />
            </div>
            <div
              :for={session <- @review_sessions}
              class="mb-3 rounded border border-amber-200 bg-amber-50 p-3 dark:border-amber-900 dark:bg-amber-950"
            >
              <div class="flex items-start justify-between gap-2">
                <div>
                  <div class="font-medium">{session.external_session_id}</div>
                  <div class="text-sm text-slate-600 dark:text-slate-300">
                    {(session.app && session.app.name) || session.cwd}
                  </div>
                </div>
                <.status_badge status={session.status} />
              </div>
              <.form
                for={to_form(%{}, as: :review)}
                id={"review-session-#{session.id}"}
                phx-submit="review_session"
                class="mt-3 grid gap-2 md:grid-cols-2"
              >
                <input type="hidden" name="session_id" value={session.id} />
                <.input
                  name="review[decision]"
                  id={"review-decision-#{session.id}"}
                  type="select"
                  label="Decision"
                  options={[
                    {"Pass", "pass"},
                    {"Needs work", "needs_work"},
                    {"Blocked", "blocked"},
                    {"Reject", "reject"}
                  ]}
                />
                <.input
                  name="review[review_note]"
                  id={"review-note-#{session.id}"}
                  label="Review note"
                />
                <.input
                  name="review[blocked_reason]"
                  id={"blocked-reason-#{session.id}"}
                  label="Blocked reason"
                />
                <.input
                  name="review[evidence_summary]"
                  id={"evidence-summary-#{session.id}"}
                  type="textarea"
                  label="Evidence summary"
                  rows="3"
                />
                <div class="flex items-end">
                  <button class="rounded border border-slate-950 bg-slate-950 px-3 py-2 text-sm font-medium text-white dark:border-white dark:bg-white dark:text-slate-950">
                    Record review
                  </button>
                </div>
              </.form>
            </div>
          </.panel>

          <.panel title="Recent Hook Events">
            <div :if={@hook_events == []}>
              <.empty_state message="No hook events received." />
            </div>
            <div
              :for={event <- @hook_events}
              class="mb-2 rounded border border-slate-200 p-3 text-sm dark:border-slate-800"
            >
              <div class="flex items-center justify-between gap-2">
                <div class="font-medium">{event.event_name}</div>
                <div class="text-xs text-slate-500">{format_datetime(event.received_at)}</div>
              </div>
              <div class="truncate text-xs text-slate-500">
                {event.cwd || "No cwd"} · {event.external_session_id || "No session id"}
              </div>
              <div :if={event.processing_error} class="mt-1 text-xs text-red-600">
                {event.processing_error}
              </div>
            </div>
          </.panel>
        </main>

        <aside class="space-y-4">
          <.panel title="Link Session">
            <.form for={@link_form} id="link-session-form" phx-submit="link_session" class="space-y-2">
              <.input
                field={@link_form[:session_id]}
                type="select"
                label="Session"
                prompt="Choose session"
                options={@session_options}
              />
              <.input
                field={@link_form[:app_id]}
                type="select"
                label="App"
                prompt="Choose app"
                options={@app_options}
              />
              <.input
                field={@link_form[:ticket_id]}
                type="select"
                label="Ticket"
                prompt="Optional"
                options={@ticket_options}
              />
              <.input field={@link_form[:link_reason]} label="Reason" />
              <.button type="submit" variant="primary">Link</.button>
            </.form>
          </.panel>

          <.panel title="Create Ticket From Session">
            <.form
              for={@session_ticket_form}
              id="session-ticket-form"
              phx-submit="create_session_ticket"
              class="space-y-2"
            >
              <.input
                field={@session_ticket_form[:session_id]}
                type="select"
                label="Session"
                prompt="Choose session"
                options={@session_options}
              />
              <.input
                field={@session_ticket_form[:app_id]}
                type="select"
                label="App"
                prompt="Choose app"
                options={@app_options}
              />
              <.input field={@session_ticket_form[:title]} label="Ticket title" />
              <.button type="submit">Create and link</.button>
            </.form>
          </.panel>

          <.panel title="Unlinked Sessions">
            <div :if={@unlinked_sessions == []}>
              <.empty_state message="No unlinked sessions." />
            </div>
            <div
              :for={session <- @unlinked_sessions}
              class="mb-2 rounded border border-slate-200 p-3 text-sm dark:border-slate-800"
            >
              <div class="font-medium">{session.external_session_id}</div>
              <div class="truncate text-xs text-slate-500">{session.cwd || "Unknown cwd"}</div>
            </div>
          </.panel>
        </aside>
      </div>
    </Layouts.app>
    """
  end
end
