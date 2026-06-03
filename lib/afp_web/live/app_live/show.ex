# @input  - App ID, return filters, and app-scoped action form params
# @output - App detail cockpit LiveView
# @pos    - Single-app recovery surface for state, work, evidence, release, and metrics context
defmodule AfpWeb.AppLive.Show do
  use AfpWeb, :live_view

  alias Afp.Factory
  alias Afp.Factory.Evidence
  alias Afp.Factory.Events
  alias Afp.Factory.Growth
  alias Afp.Factory.Growth.GrowthExperiment
  alias Afp.Factory.Maintenance
  alias Afp.Factory.Maintenance.MaintenanceObligation
  alias Afp.Factory.Metrics
  alias Afp.Factory.Portfolio
  alias Afp.Factory.Repositories
  alias Afp.Factory.Releases
  alias Afp.Factory.Work
  alias Afp.Factory.Work.HarnessPacket
  alias Afp.Factory.Work.Ticket

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe()
    {:ok, assign(socket, :page_title, "App")}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    app = Portfolio.get_app!(id)

    {:noreply,
     socket
     |> assign(:filters, Map.drop(params, ["id"]))
     |> assign(:return_to, ~p"/apps?#{Map.drop(params, ["id"])}")
     |> assign_app(app)}
  end

  @impl true
  def handle_event("update_app", %{"app" => app_params}, socket) do
    case Portfolio.update_app(socket.assigns.app, app_params) do
      {:ok, app} ->
        {:noreply,
         socket |> put_flash(:info, "App updated.") |> assign_app(Portfolio.get_app!(app.id))}

      {:error, changeset} ->
        {:noreply, assign(socket, :app_form, to_form(changeset))}
    end
  end

  def handle_event("save_next_action", %{"app" => %{"next_action" => next_action}}, socket) do
    case Portfolio.update_next_action(socket.assigns.app, next_action) do
      {:ok, app} ->
        {:noreply,
         socket
         |> put_flash(:info, "Next action updated.")
         |> assign_app(Portfolio.get_app!(app.id))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update next action.")}
    end
  end

  def handle_event("transition_lifecycle", %{"lifecycle" => params}, socket) do
    case Portfolio.transition_lifecycle(
           socket.assigns.app,
           params["lifecycle_stage"],
           params["note"],
           params
         ) do
      {:ok, app} ->
        {:noreply,
         socket
         |> put_flash(:info, "Lifecycle updated.")
         |> assign_app(Portfolio.get_app!(app.id))}

      {:error, :note_required} ->
        {:noreply, put_flash(socket, :error, "Lifecycle transition requires a note.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not update lifecycle.")}
    end
  end

  def handle_event("transition_posture", %{"posture" => params}, socket) do
    case Portfolio.transition_business_posture(
           socket.assigns.app,
           params["business_posture"],
           params["note"],
           params
         ) do
      {:ok, app} ->
        {:noreply,
         socket
         |> put_flash(:info, "Business posture updated.")
         |> assign_app(Portfolio.get_app!(app.id))}

      {:error, :note_required} ->
        {:noreply, put_flash(socket, :error, "Business posture change requires a note.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not update business posture.")}
    end
  end

  def handle_event("create_ticket", %{"ticket" => ticket_params}, socket) do
    params = Map.put(ticket_params, "app_id", socket.assigns.app.id)

    case Work.create_ticket(params) do
      {:ok, _ticket} -> {:noreply, socket |> put_flash(:info, "Ticket created.") |> reload_app()}
      {:error, changeset} -> {:noreply, assign(socket, :ticket_form, to_form(changeset))}
    end
  end

  def handle_event("create_ticket_from_next_action", _params, socket) do
    case Work.create_ticket_from_next_action(socket.assigns.app) do
      {:ok, _ticket} ->
        {:noreply, socket |> put_flash(:info, "Ticket created from next action.") |> reload_app()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create ticket from next action.")}
    end
  end

  def handle_event("create_packet", %{"packet" => packet_params}, socket) do
    params = Map.put(packet_params, "app_id", socket.assigns.app.id)

    case Work.create_harness_packet(params) do
      {:ok, _packet} ->
        {:noreply, socket |> put_flash(:info, "Harness packet created.") |> reload_app()}

      {:error, changeset} ->
        {:noreply, assign(socket, :packet_form, to_form(changeset))}
    end
  end

  def handle_event("create_release", %{"release" => release_params}, socket) do
    params = Map.put(release_params, "app_id", socket.assigns.app.id)

    case Releases.create_release_target(params) do
      {:ok, _release} ->
        {:noreply, socket |> put_flash(:info, "Release target created.") |> reload_app()}

      {:error, changeset} ->
        {:noreply, assign(socket, :release_form, to_form(changeset))}
    end
  end

  def handle_event("create_evidence", %{"evidence" => evidence_params}, socket) do
    params = Map.put(evidence_params, "app_id", socket.assigns.app.id)

    case Evidence.create_evidence_packet(params) do
      {:ok, packet} ->
        Evidence.attach_evidence(packet, "app", socket.assigns.app.id, "App cockpit evidence")
        {:noreply, socket |> put_flash(:info, "Evidence attached.") |> reload_app()}

      {:error, changeset} ->
        {:noreply, assign(socket, :evidence_form, to_form(changeset))}
    end
  end

  def handle_event("create_metrics", %{"metrics" => metrics_params}, socket) do
    params = Map.put(metrics_params, "app_id", socket.assigns.app.id)

    case Metrics.create_metrics_snapshot(params) do
      {:ok, _snapshot} ->
        {:noreply, socket |> put_flash(:info, "Metrics snapshot saved.") |> reload_app()}

      {:error, changeset} ->
        {:noreply, assign(socket, :metrics_form, to_form(changeset))}
    end
  end

  def handle_event("scan_repository", _params, socket) do
    case Repositories.scan_app(socket.assigns.app, "app_cockpit_scan") do
      {:ok, scan} ->
        {:noreply,
         socket
         |> put_flash(:info, "Repository scanned: #{scan.status}.")
         |> reload_app()}

      {:error, :repo_path_missing} ->
        {:noreply, put_flash(socket, :error, "App needs a repository path before scanning.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Repository scan failed: #{inspect(reason)}")}
    end
  end

  def handle_event("create_experiment", %{"experiment" => experiment_params}, socket) do
    params = Map.put(experiment_params, "app_id", socket.assigns.app.id)

    case Growth.create_experiment(params) do
      {:ok, _experiment} ->
        {:noreply, socket |> put_flash(:info, "Growth experiment created.") |> reload_app()}

      {:error, changeset} ->
        {:noreply, assign(socket, :experiment_form, to_form(changeset))}
    end
  end

  def handle_event("update_experiment", %{"_id" => id, "experiment" => params}, socket) do
    experiment = Growth.get_experiment!(id)

    case Growth.update_experiment(experiment, params) do
      {:ok, _experiment} ->
        {:noreply, socket |> put_flash(:info, "Growth experiment updated.") |> reload_app()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update growth experiment.")}
    end
  end

  def handle_event("create_maintenance", %{"maintenance" => maintenance_params}, socket) do
    params = Map.put(maintenance_params, "app_id", socket.assigns.app.id)

    case Maintenance.create_obligation(params) do
      {:ok, _obligation} ->
        {:noreply, socket |> put_flash(:info, "Maintenance obligation created.") |> reload_app()}

      {:error, changeset} ->
        {:noreply, assign(socket, :maintenance_form, to_form(changeset))}
    end
  end

  def handle_event("update_maintenance", %{"_id" => id, "maintenance" => params}, socket) do
    obligation = Maintenance.get_obligation!(id)

    case Maintenance.update_obligation(obligation, params) do
      {:ok, _obligation} ->
        {:noreply, socket |> put_flash(:info, "Maintenance obligation updated.") |> reload_app()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update maintenance obligation.")}
    end
  end

  @impl true
  def handle_info({:factory_event, _event}, socket), do: {:noreply, reload_app(socket)}

  defp reload_app(socket), do: assign_app(socket, Portfolio.get_app!(socket.assigns.app.id))

  defp assign_app(socket, app) do
    latest_metrics = List.first(app.metrics_snapshots)

    current_release =
      app.release_targets |> Enum.reject(&(&1.status in ["live", "cancelled"])) |> List.first()

    socket
    |> assign(:app, app)
    |> assign(:page_title, app.name)
    |> assign(:latest_metrics, latest_metrics)
    |> assign(:latest_repo_scan, List.first(app.repo_scans))
    |> assign(:current_release, current_release)
    |> assign(:blocked_tickets, Enum.filter(app.tickets, &(&1.status == "blocked")))
    |> assign(:app_form, to_form(Portfolio.change_app(app)))
    |> assign(:next_action_form, to_form(%{"next_action" => app.next_action}, as: :app))
    |> assign(
      :lifecycle_form,
      to_form(%{"lifecycle_stage" => app.lifecycle_stage}, as: :lifecycle)
    )
    |> assign(:posture_form, to_form(%{"business_posture" => app.business_posture}, as: :posture))
    |> assign(:ticket_form, to_form(Work.change_ticket(%Ticket{app_id: app.id, status: "ready"})))
    |> assign(
      :packet_form,
      to_form(
        Work.change_harness_packet(%HarnessPacket{app_id: app.id, repository_path: app.repo_path})
      )
    )
    |> assign(:release_form, to_form(%{}, as: :release))
    |> assign(:evidence_form, to_form(%{}, as: :evidence))
    |> assign(:metrics_form, to_form(%{"snapshot_date" => Date.utc_today()}, as: :metrics))
    |> assign(
      :experiment_form,
      to_form(Growth.change_experiment(%GrowthExperiment{app_id: app.id, status: "idea"}))
    )
    |> assign(
      :maintenance_form,
      to_form(
        Maintenance.change_obligation(%MaintenanceObligation{app_id: app.id, status: "open"})
      )
    )
  end

  defp active_tickets(app), do: Enum.reject(app.tickets, &(&1.status in ["done", "dropped"]))

  defp active_sessions(app),
    do:
      Enum.filter(app.codex_sessions, &(&1.status in ["linked", "running", "waiting", "stopped"]))

  defp active_experiments(app),
    do: Enum.reject(app.growth_experiments, &(&1.status in ["won", "lost", "dropped"]))

  defp open_maintenance(app),
    do: Enum.reject(app.maintenance_obligations, &(&1.status in ["done", "dropped"]))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-4">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <.link
              navigate={@return_to}
              class="mb-2 inline-flex items-center gap-1 text-xs text-slate-500 hover:text-slate-900 dark:hover:text-white"
            >
              <.icon name="hero-arrow-left" class="size-4" /> Apps
            </.link>
            <h1 class="text-2xl font-semibold">{@app.name}</h1>
            <div class="mt-2 flex flex-wrap gap-2">
              <.status_badge status={@app.lifecycle_stage} />
              <.status_badge status={@app.business_posture} />
              <.status_badge status={@app.health_state} />
            </div>
          </div>
          <div class="text-right text-xs text-slate-500">
            <div>{@app.repo_path || "No repository path"}</div>
            <div>Last activity {format_datetime(@app.last_activity_at)}</div>
          </div>
        </div>

        <div class="grid gap-4 xl:grid-cols-[420px_minmax(0,1fr)_420px]">
          <aside class="space-y-4">
            <.panel title="Identity">
              <.form for={@app_form} id="app-edit-form" phx-submit="update_app" class="space-y-2">
                <.input field={@app_form[:name]} label="Name" />
                <.input field={@app_form[:repo_path]} label="Repository path" />
                <.input field={@app_form[:platforms]} label="Platforms" />
                <.input field={@app_form[:current_version]} label="Current version" />
                <.input field={@app_form[:current_build]} label="Current build" />
                <.input
                  field={@app_form[:product_thesis]}
                  type="textarea"
                  label="Product thesis"
                  rows="4"
                />
                <.button type="submit">Save</.button>
              </.form>
            </.panel>

            <.panel title="State Transitions">
              <.form
                for={@lifecycle_form}
                id="lifecycle-form"
                phx-submit="transition_lifecycle"
                class="space-y-2"
              >
                <.input
                  field={@lifecycle_form[:lifecycle_stage]}
                  type="select"
                  label="Lifecycle"
                  options={Factory.options(Factory.lifecycle_stages())}
                />
                <.input field={@lifecycle_form[:note]} label="Decision note" required />
                <.input
                  field={@lifecycle_form[:evidence_summary]}
                  type="textarea"
                  label="Evidence summary"
                  rows="3"
                />
                <.button type="submit">Update lifecycle</.button>
              </.form>
              <div class="my-4 border-t border-slate-100 dark:border-slate-800" />
              <.form
                for={@posture_form}
                id="posture-form"
                phx-submit="transition_posture"
                class="space-y-2"
              >
                <.input
                  field={@posture_form[:business_posture]}
                  type="select"
                  label="Business posture"
                  options={Factory.options(Factory.business_postures())}
                />
                <.input field={@posture_form[:note]} label="Decision note" required />
                <.input
                  field={@posture_form[:evidence_summary]}
                  type="textarea"
                  label="Evidence summary"
                  rows="3"
                />
                <.button type="submit">Update posture</.button>
              </.form>
            </.panel>
          </aside>

          <main class="space-y-4">
            <.panel title="Next Action">
              <.form
                for={@next_action_form}
                id="next-action-form"
                phx-submit="save_next_action"
                class="space-y-2"
              >
                <.input
                  field={@next_action_form[:next_action]}
                  type="textarea"
                  label="Next action"
                  rows="3"
                />
                <div class="flex flex-wrap gap-2">
                  <.button type="submit" variant="primary">Save next action</.button>
                  <button
                    type="button"
                    phx-click="create_ticket_from_next_action"
                    class="inline-flex items-center gap-2 rounded border border-slate-300 px-3 py-2 text-sm font-medium hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800"
                  >
                    <.icon name="hero-ticket" class="size-4" /> Ticket from next action
                  </button>
                </div>
              </.form>
            </.panel>

            <div class="grid gap-4 lg:grid-cols-2">
              <.panel title="Active Tickets">
                <div :if={active_tickets(@app) == []}>
                  <.empty_state message="No active tickets." />
                </div>
                <div
                  :for={ticket <- active_tickets(@app)}
                  class="mb-2 rounded border border-slate-200 p-3 text-sm dark:border-slate-800"
                >
                  <div class="flex items-start justify-between gap-2">
                    <div class="font-medium">{ticket.title}</div>
                    <.status_badge status={ticket.status} />
                  </div>
                  <div class="mt-1 flex gap-2 text-xs text-slate-500">
                    <span>{ticket.lifecycle_gate || "No gate"}</span>
                    <span>{ticket.risk_level}</span>
                  </div>
                </div>
              </.panel>

              <.panel title="Active Sessions">
                <div :if={active_sessions(@app) == []}>
                  <.empty_state message="No active or stopped sessions." />
                </div>
                <div
                  :for={session <- active_sessions(@app)}
                  class="mb-2 rounded border border-slate-200 p-3 text-sm dark:border-slate-800"
                >
                  <div class="flex items-start justify-between gap-2">
                    <div class="font-medium">{session.external_session_id}</div>
                    <.status_badge status={session.status} />
                  </div>
                  <div class="truncate text-xs text-slate-500">{session.cwd}</div>
                </div>
              </.panel>
            </div>

            <.panel title="Current Release">
              <div :if={!@current_release}>
                <.empty_state message="No active release target." />
              </div>
              <div
                :if={@current_release}
                class="rounded border border-slate-200 p-3 text-sm dark:border-slate-800"
              >
                <div class="flex items-center justify-between">
                  <div class="font-medium">
                    {@current_release.platform} · {@current_release.version || @current_release.label}
                  </div>
                  <.status_badge status={@current_release.status} />
                </div>
                <div class="mt-1 text-xs text-slate-500">{@current_release.build || "No build"}</div>
              </div>
            </.panel>

            <div class="grid gap-4 lg:grid-cols-3">
              <.panel title="Repository Snapshot">
                <div :if={!@latest_repo_scan}>
                  <.empty_state message="No repository scan yet." />
                </div>
                <div :if={@latest_repo_scan} class="space-y-2 text-sm">
                  <div class="flex items-center justify-between gap-3">
                    <div class="font-medium">{@latest_repo_scan.branch || "No branch"}</div>
                    <.status_badge status={@latest_repo_scan.status} />
                  </div>
                  <div class="text-slate-500">
                    {@latest_repo_scan.changed_count} changed · {@latest_repo_scan.untracked_count} untracked
                  </div>
                  <div class="truncate text-xs text-slate-500">
                    {@latest_repo_scan.latest_commit_sha || "No commit"} · {@latest_repo_scan.latest_commit_subject ||
                      "No subject"}
                  </div>
                </div>
                <button
                  type="button"
                  phx-click="scan_repository"
                  class="mt-3 rounded border border-slate-300 px-3 py-2 text-sm font-medium hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800"
                >
                  Scan repository
                </button>
              </.panel>

              <.panel title="Growth Experiments">
                <div :if={active_experiments(@app) == []}>
                  <.empty_state message="No active growth experiments." />
                </div>
                <div
                  :for={experiment <- active_experiments(@app)}
                  class="mb-2 rounded border border-slate-200 p-3 text-sm dark:border-slate-800"
                >
                  <div class="flex items-start justify-between gap-2">
                    <div class="font-medium">{experiment.title}</div>
                    <.status_badge status={experiment.status} />
                  </div>
                  <div class="mt-1 text-xs text-slate-500">
                    {experiment.metric || "No metric"} · review {format_date(experiment.review_due_on)}
                  </div>
                  <.form
                    for={
                      to_form(
                        %{"status" => experiment.status, "outcome_note" => experiment.outcome_note},
                        as: :experiment
                      )
                    }
                    id={"experiment-update-#{experiment.id}"}
                    phx-submit="update_experiment"
                    class="mt-2 grid gap-2"
                  >
                    <input type="hidden" name="_id" value={experiment.id} />
                    <.input
                      name="experiment[status]"
                      id={"experiment-status-#{experiment.id}"}
                      type="select"
                      label="Status"
                      value={experiment.status}
                      options={Factory.options(Factory.experiment_statuses())}
                    />
                    <.input
                      name="experiment[outcome_note]"
                      id={"experiment-note-#{experiment.id}"}
                      label="Outcome note"
                      value={experiment.outcome_note}
                    />
                    <.button type="submit">Update</.button>
                  </.form>
                </div>
              </.panel>

              <.panel title="Maintenance">
                <div :if={open_maintenance(@app) == []}>
                  <.empty_state message="No open maintenance obligations." />
                </div>
                <div
                  :for={obligation <- open_maintenance(@app)}
                  class="mb-2 rounded border border-slate-200 p-3 text-sm dark:border-slate-800"
                >
                  <div class="flex items-start justify-between gap-2">
                    <div class="font-medium">{obligation.title}</div>
                    <.status_badge status={obligation.status} />
                  </div>
                  <div class="mt-1 text-xs text-slate-500">
                    {obligation.category} · due {format_date(obligation.due_on)}
                  </div>
                  <.form
                    for={
                      to_form(%{"status" => obligation.status, "notes" => obligation.notes},
                        as: :maintenance
                      )
                    }
                    id={"maintenance-update-#{obligation.id}"}
                    phx-submit="update_maintenance"
                    class="mt-2 grid gap-2"
                  >
                    <input type="hidden" name="_id" value={obligation.id} />
                    <.input
                      name="maintenance[status]"
                      id={"maintenance-status-#{obligation.id}"}
                      type="select"
                      label="Status"
                      value={obligation.status}
                      options={Factory.options(Factory.maintenance_statuses())}
                    />
                    <.input
                      name="maintenance[notes]"
                      id={"maintenance-notes-#{obligation.id}"}
                      label="Notes"
                      value={obligation.notes}
                    />
                    <.button type="submit">Update</.button>
                  </.form>
                </div>
              </.panel>
            </div>

            <.panel title="Blockers">
              <div :if={
                @blocked_tickets == [] and
                  (@current_release == nil or @current_release.status != "blocked")
              }>
                <.empty_state message="No app blockers recorded." />
              </div>
              <div
                :for={ticket <- @blocked_tickets}
                class="mb-2 rounded border border-red-200 bg-red-50 p-3 text-sm dark:border-red-900 dark:bg-red-950"
              >
                <div class="font-medium">{ticket.title}</div>
                <div class="text-xs text-red-700 dark:text-red-200">{ticket.blocked_reason}</div>
              </div>
            </.panel>
          </main>

          <aside class="space-y-4">
            <.panel title="Create Ticket">
              <.form
                for={@ticket_form}
                id="app-ticket-form"
                phx-submit="create_ticket"
                class="space-y-2"
              >
                <.input field={@ticket_form[:title]} label="Title" />
                <.input
                  field={@ticket_form[:description]}
                  type="textarea"
                  label="Description"
                  rows="3"
                />
                <.input
                  field={@ticket_form[:status]}
                  type="select"
                  label="Status"
                  options={Factory.options(Factory.ticket_statuses())}
                />
                <.input
                  field={@ticket_form[:risk_level]}
                  type="select"
                  label="Risk"
                  options={Factory.options(Factory.risk_levels())}
                />
                <.button type="submit">Create ticket</.button>
              </.form>
            </.panel>

            <.panel title="Create Harness Packet">
              <.form
                for={@packet_form}
                id="app-packet-form"
                phx-submit="create_packet"
                class="space-y-2"
              >
                <.input
                  field={@packet_form[:ticket_id]}
                  type="select"
                  label="Ticket"
                  prompt="Optional"
                  options={Enum.map(active_tickets(@app), &{&1.title, &1.id})}
                />
                <.input field={@packet_form[:objective]} type="textarea" label="Objective" rows="3" />
                <.input
                  field={@packet_form[:expected_output]}
                  type="textarea"
                  label="Expected output"
                  rows="2"
                />
                <.input
                  field={@packet_form[:verification_plan]}
                  type="textarea"
                  label="Verification plan"
                  rows="2"
                />
                <.input field={@packet_form[:review_route]} label="Review route" />
                <.input
                  field={@packet_form[:risk_level]}
                  type="select"
                  label="Risk"
                  options={Factory.options(Factory.risk_levels())}
                />
                <.button type="submit">Save packet</.button>
              </.form>
            </.panel>

            <.panel title="Add Release Target">
              <.form
                for={@release_form}
                id="app-release-form"
                phx-submit="create_release"
                class="space-y-2"
              >
                <.input field={@release_form[:platform]} label="Platform" />
                <.input field={@release_form[:version]} label="Version" />
                <.input field={@release_form[:build]} label="Build" />
                <.input field={@release_form[:label]} label="Label" />
                <.button type="submit">Create release</.button>
              </.form>
            </.panel>

            <.panel title="Add Evidence">
              <.form
                for={@evidence_form}
                id="app-evidence-form"
                phx-submit="create_evidence"
                class="space-y-2"
              >
                <.input
                  field={@evidence_form[:type]}
                  type="select"
                  label="Type"
                  options={Factory.options(Factory.evidence_types())}
                />
                <.input field={@evidence_form[:summary]} type="textarea" label="Summary" rows="3" />
                <.input field={@evidence_form[:source_path]} label="Source path" />
                <.input field={@evidence_form[:source_url]} label="Source URL" />
                <.input
                  field={@evidence_form[:reliability]}
                  type="select"
                  label="Reliability"
                  options={Factory.options(Factory.reliabilities())}
                />
                <.button type="submit">Attach evidence</.button>
              </.form>
            </.panel>

            <.panel title="Latest Metrics">
              <div :if={@latest_metrics} class="mb-3 grid grid-cols-2 gap-2 text-sm">
                <div>Snapshot: {format_date(@latest_metrics.snapshot_date)}</div>
                <div>Revenue: {@latest_metrics.revenue || "blank"}</div>
                <div>Downloads: {@latest_metrics.downloads || "blank"}</div>
                <div>Rating: {@latest_metrics.rating || "blank"}</div>
              </div>
              <.form
                for={@metrics_form}
                id="app-metrics-form"
                phx-submit="create_metrics"
                class="space-y-2"
              >
                <.input field={@metrics_form[:snapshot_date]} type="date" label="Snapshot date" />
                <.input field={@metrics_form[:downloads]} type="number" label="Downloads" />
                <.input field={@metrics_form[:revenue]} type="number" step="0.01" label="Revenue" />
                <.input field={@metrics_form[:rating]} type="number" step="0.1" label="Rating" />
                <.input field={@metrics_form[:notes]} type="textarea" label="Notes" rows="3" />
                <.button type="submit">Save metrics</.button>
              </.form>
            </.panel>

            <.panel title="Add Growth Experiment">
              <.form
                for={@experiment_form}
                id="app-growth-form"
                phx-submit="create_experiment"
                class="space-y-2"
              >
                <.input field={@experiment_form[:title]} label="Title" />
                <.input
                  field={@experiment_form[:hypothesis]}
                  type="textarea"
                  label="Hypothesis"
                  rows="3"
                />
                <.input field={@experiment_form[:metric]} label="Metric" />
                <.input
                  field={@experiment_form[:status]}
                  type="select"
                  label="Status"
                  options={Factory.options(Factory.experiment_statuses())}
                />
                <.input
                  field={@experiment_form[:priority]}
                  type="select"
                  label="Priority"
                  options={Factory.options(Factory.priorities())}
                />
                <.input field={@experiment_form[:review_due_on]} type="date" label="Review due" />
                <.button type="submit">Create experiment</.button>
              </.form>
            </.panel>

            <.panel title="Add Maintenance Obligation">
              <.form
                for={@maintenance_form}
                id="app-maintenance-form"
                phx-submit="create_maintenance"
                class="space-y-2"
              >
                <.input field={@maintenance_form[:title]} label="Title" />
                <.input
                  field={@maintenance_form[:category]}
                  type="select"
                  label="Category"
                  options={Factory.options(Factory.maintenance_categories())}
                />
                <.input
                  field={@maintenance_form[:status]}
                  type="select"
                  label="Status"
                  options={Factory.options(Factory.maintenance_statuses())}
                />
                <.input
                  field={@maintenance_form[:priority]}
                  type="select"
                  label="Priority"
                  options={Factory.options(Factory.priorities())}
                />
                <.input field={@maintenance_form[:due_on]} type="date" label="Due on" />
                <.input
                  field={@maintenance_form[:notes]}
                  type="textarea"
                  label="Notes"
                  rows="3"
                />
                <.button type="submit">Create obligation</.button>
              </.form>
            </.panel>
          </aside>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
