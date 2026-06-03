# @input  - Evidence packet params and optional subject-link params
# @output - Evidence store LiveView
# @pos    - Manual proof capture and attachment surface
defmodule AfpWeb.EvidenceLive do
  use AfpWeb, :live_view

  alias Afp.Factory
  alias Afp.Factory.Evidence
  alias Afp.Factory.Events
  alias Afp.Factory.Portfolio

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Evidence")
     |> assign(:evidence_form, to_form(%{}, as: :evidence))
     |> load_evidence()}
  end

  @impl true
  def handle_event("create_evidence", %{"evidence" => params}, socket) do
    link =
      if params["subject_type"] not in [nil, ""] and params["subject_id"] not in [nil, ""] do
        [
          %{
            "subject_type" => params["subject_type"],
            "subject_id" => params["subject_id"],
            "link_reason" => params["link_reason"]
          }
        ]
      else
        []
      end

    params = Map.drop(params, ["subject_type", "subject_id", "link_reason"])

    result =
      if link == [] do
        Evidence.create_evidence_packet(params)
      else
        Evidence.create_evidence_packet(params, link)
      end

    case result do
      {:ok, _packet} ->
        {:noreply,
         socket
         |> put_flash(:info, "Evidence saved.")
         |> assign(:evidence_form, to_form(%{}, as: :evidence))
         |> load_evidence()}

      {:ok, _packet, _links} ->
        {:noreply,
         socket
         |> put_flash(:info, "Evidence saved and linked.")
         |> assign(:evidence_form, to_form(%{}, as: :evidence))
         |> load_evidence()}

      {:error, changeset} ->
        {:noreply, assign(socket, :evidence_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_info({:factory_event, _event}, socket), do: {:noreply, load_evidence(socket)}

  defp load_evidence(socket) do
    socket
    |> assign(:evidence_packets, Evidence.list_evidence())
    |> assign(:app_options, Portfolio.list_app_options())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_420px]">
        <main>
          <.panel title="Evidence Store">
            <:subtitle>
              Evidence has one primary app and may be linked to tickets, sessions, releases, checks, or metrics.
            </:subtitle>
            <div :if={@evidence_packets == []}>
              <.empty_state message="No evidence packets yet." />
            </div>
            <div class="grid gap-3 xl:grid-cols-2">
              <article
                :for={packet <- @evidence_packets}
                class="rounded border border-slate-200 bg-white p-4 dark:border-slate-800 dark:bg-slate-950"
              >
                <div class="flex items-start justify-between gap-3">
                  <div>
                    <h2 class="font-semibold">{packet.title}</h2>
                    <div class="mt-1 flex flex-wrap gap-2">
                      <.status_badge status={packet.type} />
                      <.status_badge status={packet.reliability} />
                    </div>
                  </div>
                  <div class="text-xs text-slate-500">{format_datetime(packet.inserted_at)}</div>
                </div>
                <p class="mt-3 text-sm text-slate-600 dark:text-slate-300">{packet.summary}</p>
                <div class="mt-3 space-y-1 text-xs text-slate-500">
                  <div>App: {packet.app.name}</div>
                  <div :if={packet.source_path}>Path: {packet.source_path}</div>
                  <div :if={packet.source_url}>URL: {packet.source_url}</div>
                  <div>Links: {length(packet.evidence_links)}</div>
                </div>
              </article>
            </div>
          </.panel>
        </main>

        <aside>
          <.panel title="Add Evidence">
            <.form
              for={@evidence_form}
              id="evidence-form"
              phx-submit="create_evidence"
              class="space-y-2"
            >
              <.input
                field={@evidence_form[:app_id]}
                type="select"
                label="Primary app"
                prompt="Choose app"
                options={@app_options}
              />
              <.input
                field={@evidence_form[:type]}
                type="select"
                label="Type"
                options={Factory.options(Factory.evidence_types())}
              />
              <.input
                field={@evidence_form[:summary]}
                type="textarea"
                label="Summary"
                rows="4"
                required
              />
              <.input
                field={@evidence_form[:title]}
                label="Title"
                placeholder="Defaults from summary"
              />
              <.input field={@evidence_form[:source_path]} label="Source path" />
              <.input field={@evidence_form[:source_url]} label="Source URL" />
              <.input
                field={@evidence_form[:reliability]}
                type="select"
                label="Reliability"
                options={Factory.options(Factory.reliabilities())}
              />
              <div class="border-t border-slate-100 pt-3 dark:border-slate-800">
                <div class="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">
                  Optional link
                </div>
                <.input
                  field={@evidence_form[:subject_type]}
                  type="select"
                  label="Subject type"
                  prompt="None"
                  options={Factory.options(Afp.Factory.Evidence.EvidenceLink.subject_types())}
                />
                <.input field={@evidence_form[:subject_id]} label="Subject ID" />
                <.input field={@evidence_form[:link_reason]} label="Link reason" />
              </div>
              <.button type="submit" variant="primary">Save evidence</.button>
            </.form>
          </.panel>
        </aside>
      </div>
    </Layouts.app>
    """
  end
end
