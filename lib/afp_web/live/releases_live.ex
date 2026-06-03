# @input  - Release target params, checklist updates, transitions, and evidence links
# @output - Release center LiveView
# @pos    - Shipping readiness surface with manual checklist gates
defmodule AfpWeb.ReleasesLive do
  use AfpWeb, :live_view

  alias Afp.Factory
  alias Afp.Factory.Evidence
  alias Afp.Factory.Events
  alias Afp.Factory.Portfolio
  alias Afp.Factory.Releases

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Releases")
     |> assign(:release_form, to_form(%{}, as: :release))
     |> load_releases()}
  end

  @impl true
  def handle_event("create_release", %{"release" => params}, socket) do
    case Releases.create_release_target(params) do
      {:ok, _release} ->
        {:noreply,
         socket
         |> put_flash(:info, "Release target created.")
         |> assign(:release_form, to_form(%{}, as: :release))
         |> load_releases()}

      {:error, changeset} ->
        {:noreply, assign(socket, :release_form, to_form(changeset))}
    end
  end

  def handle_event("update_check", %{"check_id" => id, "check" => params}, socket) do
    check_item = Releases.get_check_item!(id)

    case Releases.update_check_item(check_item, params) do
      {:ok, _item} ->
        {:noreply, socket |> put_flash(:info, "Checklist updated.") |> load_releases()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Waived checks require a reason.")}
    end
  end

  def handle_event("transition_release", %{"release_id" => id, "transition" => params}, socket) do
    release = Releases.get_release_target!(id)

    case Releases.transition_release_target(release, params["status"], params) do
      {:ok, _release} ->
        {:noreply, socket |> put_flash(:info, "Release state updated.") |> load_releases()}

      {:error, :checklist_incomplete} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Checklist must be passed, waived, or not applicable before ready for review."
         )}

      {:error, :submission_note_required} ->
        {:noreply, put_flash(socket, :error, "Submitting a release requires a note.")}

      {:error, :live_note_and_date_required} ->
        {:noreply, put_flash(socket, :error, "Marking live requires a note and released date.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Release transition is not allowed.")}
    end
  end

  def handle_event("create_check_ticket", %{"id" => id}, socket) do
    check_item = Releases.get_check_item!(id)

    case Releases.create_ticket_for_check_item(check_item) do
      {:ok, _ticket} ->
        {:noreply,
         socket |> put_flash(:info, "Ticket created for checklist item.") |> load_releases()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create ticket.")}
    end
  end

  def handle_event(
        "attach_check_evidence",
        %{"check_id" => id, "evidence" => %{"evidence_packet_id" => evidence_id}},
        socket
      ) do
    packet = Evidence.get_evidence_packet!(evidence_id)

    case Evidence.attach_evidence(packet, "release_check_item", id, "Release checklist evidence") do
      {:ok, _link} ->
        {:noreply,
         socket |> put_flash(:info, "Evidence linked to checklist item.") |> load_releases()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not attach evidence.")}
    end
  end

  @impl true
  def handle_info({:factory_event, _event}, socket), do: {:noreply, load_releases(socket)}

  defp load_releases(socket) do
    evidence_options = Evidence.list_evidence() |> Enum.map(&{&1.title, &1.id})

    socket
    |> assign(:releases, Releases.list_release_targets())
    |> assign(:app_options, Portfolio.list_app_options())
    |> assign(:evidence_options, evidence_options)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-4">
        <.page_header
          eyebrow="Shipping"
          title="Releases"
          subtitle="Release targets, checklist gates, and manual shipping decisions."
        >
          <:meta>
            <.summary_item title="Targets" value={length(@releases)} hint="tracked releases" />
            <.summary_item
              title="Blocked"
              value={Enum.count(@releases, &(&1.status == "blocked"))}
              hint="needs action"
            />
          </:meta>
        </.page_header>

        <div class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_380px]">
          <main class="space-y-4">
            <.panel title="Release Targets">
              <:subtitle>
                Ready for review is blocked until required checklist items pass, are waived with reason, or are marked not applicable.
              </:subtitle>
              <div :if={@releases == []}>
                <.empty_state message="No release targets yet." />
              </div>
              <article
                :for={release <- @releases}
                class="mb-4 rounded border border-slate-200 bg-white dark:border-slate-800 dark:bg-slate-950"
              >
                <header class="flex flex-wrap items-start justify-between gap-3 border-b border-slate-100 p-4 dark:border-slate-800">
                  <div>
                    <h2 class="font-semibold">{release.app.name} · {release.platform}</h2>
                    <div class="mt-1 text-sm text-slate-500">
                      {release.version || release.label} · build {release.build || "blank"}
                    </div>
                  </div>
                  <.status_badge status={release.status} />
                </header>

                <div class="p-4">
                  <.disclosure
                    title="Checklist gates"
                    subtitle="Required readiness checks for this release target."
                    open={release.status in ["preparing", "blocked", "ready_for_review"]}
                  >
                    <div class="space-y-2">
                      <div
                        :for={check <- Enum.sort_by(release.release_check_items, & &1.position)}
                        class="rounded border border-slate-200 p-3 dark:border-slate-800"
                      >
                        <div class="flex flex-wrap items-start justify-between gap-2">
                          <div>
                            <div class="font-medium">{check.title}</div>
                            <div class="text-xs text-slate-500">
                              {check.category} · {if check.required, do: "required", else: "optional"}
                            </div>
                          </div>
                          <.status_badge status={check.status} />
                        </div>
                        <.form
                          for={to_form(%{}, as: :check)}
                          id={"check-#{check.id}"}
                          phx-submit="update_check"
                          class="mt-3 grid gap-2 md:grid-cols-4"
                        >
                          <input type="hidden" name="check_id" value={check.id} />
                          <.input
                            name="check[status]"
                            id={"check-status-#{check.id}"}
                            type="select"
                            label="Status"
                            options={Factory.options(Factory.check_statuses())}
                            value={check.status}
                          />
                          <.input
                            name="check[waiver_reason]"
                            id={"check-waiver-#{check.id}"}
                            label="Waiver reason"
                            value={check.waiver_reason}
                          />
                          <.input
                            name="check[decision_note]"
                            id={"check-note-#{check.id}"}
                            label="Decision note"
                            value={check.decision_note}
                          />
                          <div class="flex items-end gap-2">
                            <button class="rounded border border-slate-300 px-2 py-1 text-xs font-medium hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800">
                              Save
                            </button>
                            <button
                              :if={check.status == "failed"}
                              type="button"
                              phx-click="create_check_ticket"
                              phx-value-id={check.id}
                              class="rounded border border-red-300 px-2 py-1 text-xs font-medium text-red-700 hover:bg-red-50 dark:border-red-900 dark:text-red-200 dark:hover:bg-red-950"
                            >
                              Ticket
                            </button>
                          </div>
                        </.form>
                        <.form
                          :if={@evidence_options != []}
                          for={to_form(%{}, as: :evidence)}
                          id={"check-evidence-#{check.id}"}
                          phx-submit="attach_check_evidence"
                          class="mt-2 flex gap-2"
                        >
                          <input type="hidden" name="check_id" value={check.id} />
                          <.input
                            name="evidence[evidence_packet_id]"
                            id={"check-evidence-id-#{check.id}"}
                            type="select"
                            label="Evidence"
                            prompt="Attach evidence"
                            options={@evidence_options}
                          />
                          <button class="mt-5 h-9 rounded border border-slate-300 px-2 text-xs font-medium hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800">
                            Attach
                          </button>
                        </.form>
                      </div>
                    </div>
                  </.disclosure>

                  <.disclosure
                    title="Release decision"
                    subtitle="Manual state movement with required notes."
                  >
                    <.form
                      for={to_form(%{}, as: :transition)}
                      id={"release-transition-#{release.id}"}
                      phx-submit="transition_release"
                      class="space-y-2 rounded border border-slate-200 p-3 dark:border-slate-800"
                    >
                      <input type="hidden" name="release_id" value={release.id} />
                      <.input
                        name="transition[status]"
                        id={"release-status-#{release.id}"}
                        type="select"
                        label="Move to"
                        options={Factory.options(Factory.release_statuses())}
                        value={release.status}
                      />
                      <.input
                        name="transition[decision_note]"
                        id={"release-note-#{release.id}"}
                        label="Decision note"
                      />
                      <.input
                        name="transition[released_at]"
                        id={"release-live-date-#{release.id}"}
                        type="datetime-local"
                        label="Released at"
                      />
                      <.button type="submit">Update release</.button>
                    </.form>
                  </.disclosure>
                </div>
              </article>
            </.panel>
          </main>

          <aside>
            <.panel title="Release Actions">
              <.disclosure
                title="Create Release Target"
                subtitle="Start a new platform/version readiness track."
                open
              >
                <.form
                  for={@release_form}
                  id="release-form"
                  phx-submit="create_release"
                  class="space-y-2"
                >
                  <.input
                    field={@release_form[:app_id]}
                    type="select"
                    label="App"
                    prompt="Choose app"
                    options={@app_options}
                  />
                  <.input field={@release_form[:platform]} label="Platform" placeholder="ios" />
                  <.input field={@release_form[:version]} label="Version" />
                  <.input field={@release_form[:build]} label="Build" />
                  <.input field={@release_form[:label]} label="Label" />
                  <.button type="submit" variant="primary">Create release</.button>
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
