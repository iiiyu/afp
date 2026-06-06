# @input  - Demand source, candidate, template, launch, promotion, and filter form params
# @output - Demand repo control console for research, pickup, launch handoff, and promotion
# @pos    - UI layer before portfolio app lifecycle ownership begins
defmodule AfpWeb.DemandLive do
  use AfpWeb, :live_view

  alias Afp.Factory
  alias Afp.Factory.Demand.Candidate
  alias Afp.Factory.Demand
  alias Afp.Factory.Demand.CodexLaunchRequest
  alias Afp.Factory.Demand.DemandItem
  alias Afp.Factory.Demand.MessageTemplate
  alias Afp.Factory.Demand.SourceRepo
  alias Afp.Factory.Sessions

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Demand")
     |> assign(:filters, params)
     |> assign(:filter_form, to_form(params, as: :filters))
     |> assign(:source_repo_form, to_form(Demand.change_source_repo(%SourceRepo{})))
     |> assign(:candidate_form, to_form(Demand.change_candidate(%Candidate{})))
     |> assign(
       :message_template_form,
       to_form(Demand.change_message_template(%MessageTemplate{}))
     )
     |> assign(:source_launch_form, to_form(%{}, as: :source_launch))
     |> assign(:candidate_launch_form, to_form(%{}, as: :candidate_launch))
     |> assign(:session_followup_form, to_form(%{}, as: :session_followup))
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

  def handle_event("create_source_repo", %{"source_repo" => params}, socket) do
    case Demand.create_source_repo(params) do
      {:ok, _source_repo} ->
        {:noreply,
         socket
         |> put_flash(:info, "Demand source added.")
         |> assign(:source_repo_form, to_form(Demand.change_source_repo(%SourceRepo{})))
         |> load_demand(socket.assigns.filters)}

      {:error, changeset} ->
        {:noreply, assign(socket, :source_repo_form, to_form(changeset))}
    end
  end

  def handle_event("refresh_source_repo", %{"source_repo_id" => source_repo_id}, socket) do
    source_repo = Demand.get_source_repo!(source_repo_id)

    case Demand.refresh_source_repo_index(source_repo) do
      {:ok, result} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Demand source refreshed with #{length(result.candidates)} candidates."
         )
         |> load_demand(socket.assigns.filters)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, first_error(reason) || refresh_error(reason))
         |> load_demand(socket.assigns.filters)}
    end
  end

  def handle_event("create_candidate", %{"candidate" => params}, socket) do
    if Factory.blank?(params["demand_source_repo_id"]) do
      {:noreply, put_flash(socket, :error, "Choose a source repo first.")}
    else
      source_repo = Demand.get_source_repo!(params["demand_source_repo_id"])

      case Demand.index_candidate(source_repo, params) do
        {:ok, _candidate} ->
          {:noreply,
           socket
           |> put_flash(:info, "Demand candidate indexed.")
           |> assign(:candidate_form, to_form(Demand.change_candidate(%Candidate{})))
           |> load_demand(socket.assigns.filters)}

        {:error, changeset} ->
          {:noreply, assign(socket, :candidate_form, to_form(changeset))}
      end
    end
  end

  def handle_event(
        "transition_candidate",
        %{"candidate_id" => candidate_id, "candidate" => params},
        socket
      ) do
    candidate = Demand.get_candidate!(candidate_id)

    case Demand.transition_candidate(candidate, params["afp_status"], params) do
      {:ok, _candidate} ->
        {:noreply,
         socket
         |> put_flash(:info, "Candidate route updated.")
         |> load_demand(socket.assigns.filters)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, first_error(changeset) || "Could not update candidate.")
         |> load_demand(socket.assigns.filters)}
    end
  end

  def handle_event("verify_candidate_package", %{"candidate_id" => candidate_id}, socket) do
    candidate = Demand.get_candidate!(candidate_id)

    case Demand.verify_candidate_package(candidate) do
      {:ok, package_candidate} ->
        {:noreply,
         socket
         |> put_flash(:info, "Package verified for #{package_candidate.title}.")
         |> load_demand(socket.assigns.filters)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, first_error(reason) || refresh_error(reason))
         |> load_demand(socket.assigns.filters)}
    end
  end

  def handle_event("pickup_candidate", %{"candidate_id" => candidate_id}, socket) do
    candidate = Demand.get_candidate!(candidate_id)

    case Demand.pick_up_candidate(candidate) do
      {:ok, _candidate, demand_item} ->
        {:noreply,
         socket
         |> put_flash(:info, "Candidate picked up as #{demand_item.title}.")
         |> load_demand(socket.assigns.filters)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, first_error(changeset) || "Could not pick up candidate.")
         |> load_demand(socket.assigns.filters)}
    end
  end

  def handle_event("create_message_template", %{"message_template" => params}, socket) do
    case Demand.create_message_template(params) do
      {:ok, _template} ->
        {:noreply,
         socket
         |> put_flash(:info, "Message template created.")
         |> assign(
           :message_template_form,
           to_form(Demand.change_message_template(%MessageTemplate{}))
         )
         |> load_demand(socket.assigns.filters)}

      {:error, changeset} ->
        {:noreply, assign(socket, :message_template_form, to_form(changeset))}
    end
  end

  def handle_event("create_source_launch", %{"source_launch" => params}, socket) do
    cond do
      Factory.blank?(params["source_repo_id"]) ->
        {:noreply, put_flash(socket, :error, "Choose a source repo first.")}

      Factory.blank?(params["message_template_id"]) ->
        {:noreply, put_flash(socket, :error, "Choose a message template first.")}

      true ->
        source_repo = Demand.get_source_repo!(params["source_repo_id"])
        template = Demand.get_message_template!(params["message_template_id"])

        case Demand.create_source_launch_request(source_repo, template, params) do
          {:ok, _records} ->
            {:noreply,
             socket
             |> put_flash(:info, "Source research handoff created.")
             |> assign(:source_launch_form, to_form(%{}, as: :source_launch))
             |> load_demand(socket.assigns.filters)}

          {:error, {:missing_variables, variables}} ->
            {:noreply,
             put_flash(socket, :error, "Template is missing: #{Enum.join(variables, ", ")}.")}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, first_error(reason) || refresh_error(reason))
             |> load_demand(socket.assigns.filters)}
        end
    end
  end

  def handle_event("create_candidate_launch", %{"candidate_launch" => params}, socket) do
    cond do
      Factory.blank?(params["candidate_id"]) ->
        {:noreply, put_flash(socket, :error, "Choose a candidate first.")}

      Factory.blank?(params["message_template_id"]) ->
        {:noreply, put_flash(socket, :error, "Choose a message template first.")}

      true ->
        candidate = Demand.get_candidate!(params["candidate_id"])
        template = Demand.get_message_template!(params["message_template_id"])

        case Demand.create_candidate_launch_request(candidate, template, params) do
          {:ok, _records} ->
            {:noreply,
             socket
             |> put_flash(:info, "Candidate launch handoff created.")
             |> assign(:candidate_launch_form, to_form(%{}, as: :candidate_launch))
             |> load_demand(socket.assigns.filters)}

          {:error, {:missing_variables, variables}} ->
            {:noreply,
             put_flash(socket, :error, "Template is missing: #{Enum.join(variables, ", ")}.")}

          {:error, changeset} ->
            {:noreply,
             socket
             |> put_flash(:error, first_error(changeset) || "Could not create handoff.")
             |> load_demand(socket.assigns.filters)}
        end
    end
  end

  def handle_event("create_session_followup", %{"session_followup" => params}, socket) do
    cond do
      Factory.blank?(params["research_run_id"]) ->
        {:noreply, put_flash(socket, :error, "Choose a research run first.")}

      Factory.blank?(params["codex_session_id"]) ->
        {:noreply, put_flash(socket, :error, "Choose a Codex session first.")}

      Factory.blank?(params["message_template_id"]) ->
        {:noreply, put_flash(socket, :error, "Choose a message template first.")}

      true ->
        research_run = Demand.get_research_run!(params["research_run_id"])
        codex_session = Sessions.get_session!(params["codex_session_id"])
        template = Demand.get_message_template!(params["message_template_id"])

        case Demand.create_session_followup(research_run, codex_session, template, params) do
          {:ok, _records} ->
            {:noreply,
             socket
             |> put_flash(:info, "Session follow-up handoff created.")
             |> assign(:session_followup_form, to_form(%{}, as: :session_followup))
             |> load_demand(socket.assigns.filters)}

          {:error, {:missing_variables, variables}} ->
            {:noreply,
             put_flash(socket, :error, "Template is missing: #{Enum.join(variables, ", ")}.")}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, first_error(reason) || refresh_error(reason))
             |> load_demand(socket.assigns.filters)}
        end
    end
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
    source_repos = Demand.list_source_repos()
    candidates = Demand.list_candidates()
    demand_items = Demand.list_demand_items(filters)
    all_demand_items = Demand.list_demand_items()
    research_runs = Demand.list_research_runs()
    message_templates = Demand.list_message_templates(%{"active" => "true"})
    launch_requests = Demand.list_launch_requests()
    codex_sessions = Sessions.list_sessions()

    socket
    |> assign(:source_repos, source_repos)
    |> assign(:demand_candidates, candidates)
    |> assign(:pickup_candidates, Demand.list_pickup_candidates())
    |> assign(:package_candidates, Demand.list_package_candidates())
    |> assign(:handoff_candidates, Demand.list_handoff_candidates())
    |> assign(:research_runs, research_runs)
    |> assign(:message_templates, message_templates)
    |> assign(:codex_sessions, codex_sessions)
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
            <.summary_item title="Sources" value={length(@source_repos)} hint="repo contracts" />
            <.summary_item title="Candidates" value={length(@demand_candidates)} hint="indexed pool" />
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
            <.panel title="Source Repos">
              <:subtitle>
                Configured demand repositories, manifest health, schedule, and repo-local contract state.
              </:subtitle>

              <div :if={@source_repos == []}>
                <.empty_state message="No demand source repos configured." />
              </div>
              <div class="divide-y divide-slate-100 dark:divide-slate-800">
                <article :for={source_repo <- @source_repos} class="py-4">
                  <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                    <div class="min-w-0">
                      <div class="flex flex-wrap items-center gap-2">
                        <h2 class="text-sm font-semibold text-slate-950 dark:text-white">
                          {source_repo.display_name}
                        </h2>
                        <.status_badge status={source_repo.health_state} />
                      </div>
                      <div class="mt-2 grid gap-2 text-sm text-slate-600 dark:text-slate-300 lg:grid-cols-2">
                        <div>
                          <span class="font-medium text-slate-900 dark:text-white">Path:</span>
                          <code class="break-all text-xs">{source_repo.repo_path}</code>
                        </div>
                        <div>
                          <span class="font-medium text-slate-900 dark:text-white">Manifest:</span>
                          {source_repo.manifest_path}
                        </div>
                        <div>
                          <span class="font-medium text-slate-900 dark:text-white">Lanes:</span>
                          {Enum.join(source_repo.lanes, ", ")}
                        </div>
                        <div>
                          <span class="font-medium text-slate-900 dark:text-white">Schedule:</span>
                          {if source_repo.schedule_enabled,
                            do: "#{source_repo.schedule_interval_hours}h",
                            else: "disabled"}
                        </div>
                        <div>
                          <span class="font-medium text-slate-900 dark:text-white">Indexed:</span>
                          {format_datetime(source_repo.latest_index_at)}
                        </div>
                      </div>
                      <p class="mt-2 text-sm text-slate-700 dark:text-slate-200">
                        {source_repo.health_summary || "No health summary yet."}
                      </p>
                      <div
                        :if={source_repo.missing_paths != [] || source_repo.parse_errors != []}
                        class="mt-2 space-y-1 text-xs text-slate-500"
                      >
                        <div :for={path <- source_repo.missing_paths}>
                          Missing: <code class="break-all">{path}</code>
                        </div>
                        <div :for={error <- source_repo.parse_errors}>
                          Error: {error}
                        </div>
                      </div>
                      <p :if={source_repo.required_skills != []} class="mt-2 text-xs text-slate-500">
                        Required skills: {Enum.join(source_repo.required_skills, ", ")}
                      </p>
                      <p :if={legacy_adapter(source_repo)} class="mt-2 text-xs text-slate-500">
                        Legacy adapter: {legacy_adapter(source_repo)["label"]} · {legacy_adapter(
                          source_repo
                        )["confidence"]} confidence
                      </p>
                    </div>
                    <.form
                      for={to_form(%{}, as: :source_refresh)}
                      id={"source-refresh-#{source_repo.id}"}
                      phx-submit="refresh_source_repo"
                      class="shrink-0"
                    >
                      <input type="hidden" name="source_repo_id" value={source_repo.id} />
                      <button class="inline-flex items-center gap-2 rounded border border-slate-300 px-2 py-1 text-xs font-medium hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800">
                        <.icon name="hero-arrow-path" class="size-3" /> Refresh index
                      </button>
                    </.form>
                  </div>
                </article>
              </div>
            </.panel>

            <.panel title="Pickup And Handoff Queues">
              <:subtitle>
                Operator-confirmed transitions from indexed candidates to validation, package, and handoff.
              </:subtitle>
              <div class="grid gap-4 lg:grid-cols-3">
                <section>
                  <h3 class="text-xs font-semibold uppercase tracking-wide text-slate-500">
                    Pickup
                  </h3>
                  <div :if={@pickup_candidates == []} class="mt-2">
                    <.empty_state message="No pickup candidates." />
                  </div>
                  <div class="mt-2 divide-y divide-slate-100 dark:divide-slate-800">
                    <div :for={candidate <- @pickup_candidates} class="py-2 text-sm">
                      <div class="font-medium text-slate-950 dark:text-white">{candidate.title}</div>
                      <div class="text-xs text-slate-500">
                        {candidate.lane} · {candidate.source_status} · score {candidate.score ||
                          "none"}
                      </div>
                    </div>
                  </div>
                </section>
                <section>
                  <h3 class="text-xs font-semibold uppercase tracking-wide text-slate-500">
                    Package
                  </h3>
                  <div :if={@package_candidates == []} class="mt-2">
                    <.empty_state message="No package candidates." />
                  </div>
                  <div class="mt-2 divide-y divide-slate-100 dark:divide-slate-800">
                    <div :for={candidate <- @package_candidates} class="py-2 text-sm">
                      <div class="font-medium text-slate-950 dark:text-white">{candidate.title}</div>
                      <div class="text-xs text-slate-500">
                        {candidate.afp_status} · {candidate.package_path || "package path pending"}
                      </div>
                    </div>
                  </div>
                </section>
                <section>
                  <h3 class="text-xs font-semibold uppercase tracking-wide text-slate-500">
                    Handoff
                  </h3>
                  <div :if={@handoff_candidates == []} class="mt-2">
                    <.empty_state message="No handoff candidates." />
                  </div>
                  <div class="mt-2 divide-y divide-slate-100 dark:divide-slate-800">
                    <div :for={candidate <- @handoff_candidates} class="py-2 text-sm">
                      <div class="font-medium text-slate-950 dark:text-white">{candidate.title}</div>
                      <div class="text-xs text-slate-500">
                        {candidate.lane} · {candidate.package_path || "no package path"}
                      </div>
                    </div>
                  </div>
                </section>
              </div>
            </.panel>

            <.panel title="Candidate Pool">
              <:subtitle>
                Normalized AFP index of repo-owned opportunities. Source status and AFP routing stay separate.
              </:subtitle>

              <div :if={@demand_candidates == []}>
                <.empty_state message="No indexed candidates yet." />
              </div>
              <div class="divide-y divide-slate-100 dark:divide-slate-800">
                <article :for={candidate <- @demand_candidates} class="py-4">
                  <div class="flex flex-col gap-3 xl:flex-row xl:items-start xl:justify-between">
                    <div class="min-w-0">
                      <div class="flex flex-wrap items-center gap-2">
                        <h2 class="text-sm font-semibold text-slate-950 dark:text-white">
                          {candidate.title}
                        </h2>
                        <.status_badge status={candidate.lane} />
                        <.status_badge status={candidate.source_status} />
                        <.status_badge status={candidate.afp_status} />
                      </div>
                      <div class="mt-2 grid gap-2 text-sm text-slate-600 dark:text-slate-300 lg:grid-cols-2">
                        <div>
                          <span class="font-medium text-slate-900 dark:text-white">Source:</span>
                          {candidate.source_repo && candidate.source_repo.display_name}
                        </div>
                        <div>
                          <span class="font-medium text-slate-900 dark:text-white">Score:</span>
                          {candidate.score || "Not scored"} · {candidate.confidence}
                        </div>
                        <div>
                          <span class="font-medium text-slate-900 dark:text-white">Path:</span>
                          <code class="break-all text-xs">
                            {candidate.primary_path || "Not indexed"}
                          </code>
                        </div>
                        <div>
                          <span class="font-medium text-slate-900 dark:text-white">Report:</span>
                          <code class="break-all text-xs">
                            {candidate.report_path || "Not indexed"}
                          </code>
                        </div>
                      </div>
                      <p class="mt-2 text-sm text-slate-700 dark:text-slate-200">
                        {candidate.validation_action || candidate.wedge_hypothesis ||
                          "No validation action indexed."}
                      </p>
                      <p :if={candidate.limitations} class="mt-1 text-xs text-slate-500">
                        Limitations: {candidate.limitations}
                      </p>
                      <.link
                        :if={candidate.demand_item}
                        navigate={~p"/demand"}
                        class="mt-2 inline-flex text-xs font-medium text-slate-700 underline dark:text-slate-200"
                      >
                        Picked up demand item: {candidate.demand_item.title}
                      </.link>
                    </div>
                    <div class="grid w-full shrink-0 gap-2 xl:w-72">
                      <.form
                        for={to_form(%{}, as: :candidate_pickup)}
                        id={"candidate-pickup-#{candidate.id}"}
                        phx-submit="pickup_candidate"
                      >
                        <input type="hidden" name="candidate_id" value={candidate.id} />
                        <button
                          disabled={candidate.afp_status == "picked_up"}
                          class="inline-flex w-full items-center justify-center gap-2 rounded border border-slate-300 px-2 py-1 text-xs font-medium hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-50 dark:border-slate-700 dark:hover:bg-slate-800"
                        >
                          <.icon name="hero-inbox-arrow-down" class="size-3" /> Pick up
                        </button>
                      </.form>
                      <.form
                        for={to_form(%{}, as: :candidate_package)}
                        id={"candidate-package-#{candidate.id}"}
                        phx-submit="verify_candidate_package"
                      >
                        <input type="hidden" name="candidate_id" value={candidate.id} />
                        <button class="inline-flex w-full items-center justify-center gap-2 rounded border border-slate-300 px-2 py-1 text-xs font-medium hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800">
                          <.icon name="hero-archive-box" class="size-3" /> Verify package
                        </button>
                      </.form>
                      <.form
                        for={to_form(%{}, as: :candidate)}
                        id={"candidate-route-#{candidate.id}"}
                        phx-submit="transition_candidate"
                        class="space-y-2"
                      >
                        <input type="hidden" name="candidate_id" value={candidate.id} />
                        <.input
                          name="candidate[afp_status]"
                          id={"candidate-afp-status-#{candidate.id}"}
                          type="select"
                          label="AFP route"
                          options={Factory.options(Factory.demand_candidate_afp_statuses())}
                          value={candidate.afp_status}
                        />
                        <.input
                          name="candidate[review_note]"
                          id={"candidate-review-note-#{candidate.id}"}
                          label="Review note"
                        />
                        <button class="inline-flex items-center rounded border border-slate-300 px-2 py-1 text-xs font-medium hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800">
                          Route
                        </button>
                      </.form>
                    </div>
                  </div>
                </article>
              </div>
            </.panel>

            <.panel title="Research Runs And Templates">
              <:subtitle>
                Recent Codex work records and reusable manual-handoff message templates.
              </:subtitle>
              <div class="grid gap-4 xl:grid-cols-2">
                <section>
                  <h3 class="text-xs font-semibold uppercase tracking-wide text-slate-500">
                    Research runs
                  </h3>
                  <div :if={@research_runs == []} class="mt-2">
                    <.empty_state message="No research runs yet." />
                  </div>
                  <div class="mt-2 divide-y divide-slate-100 dark:divide-slate-800">
                    <article :for={run <- @research_runs} class="py-3 text-sm">
                      <div class="flex flex-wrap items-center gap-2">
                        <span class="font-medium text-slate-950 dark:text-white">
                          {run.objective}
                        </span>
                        <.status_badge status={run.status} />
                      </div>
                      <div class="mt-1 text-xs text-slate-500">
                        {run.run_type} · {run.lane || "no lane"} · {format_datetime(run.updated_at)}
                      </div>
                    </article>
                  </div>
                </section>
                <section>
                  <h3 class="text-xs font-semibold uppercase tracking-wide text-slate-500">
                    Message templates
                  </h3>
                  <div :if={@message_templates == []} class="mt-2">
                    <.empty_state message="No active templates yet." />
                  </div>
                  <div class="mt-2 divide-y divide-slate-100 dark:divide-slate-800">
                    <article :for={template <- @message_templates} class="py-3 text-sm">
                      <div class="flex flex-wrap items-center gap-2">
                        <span class="font-medium text-slate-950 dark:text-white">
                          {template.name}
                        </span>
                        <.status_badge status={template.default_run_type} />
                      </div>
                      <p class="mt-1 text-xs text-slate-500">
                        {template.purpose || "No purpose set."}
                      </p>
                      <p :if={template.required_variables != []} class="mt-1 text-xs text-slate-500">
                        Variables: {Enum.join(template.required_variables, ", ")}
                      </p>
                    </article>
                  </div>
                </section>
              </div>
            </.panel>

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
                title="Add Source Repo"
                subtitle="Register a manifest-backed demand repository."
                open
              >
                <.form
                  for={@source_repo_form}
                  id="source-repo-form"
                  phx-submit="create_source_repo"
                  class="space-y-2"
                >
                  <.input field={@source_repo_form[:repo_path]} label="Repository path" required />
                  <.input field={@source_repo_form[:display_name]} label="Display name" />
                  <.input
                    field={@source_repo_form[:manifest_path]}
                    label="Manifest path"
                    placeholder="afp-demand-source.json"
                  />
                  <.input
                    field={@source_repo_form[:schedule_enabled]}
                    type="checkbox"
                    label="Enable scheduled scans"
                  />
                  <.input
                    field={@source_repo_form[:schedule_interval_hours]}
                    type="number"
                    label="Interval hours"
                  />
                  <.button type="submit" variant="primary">
                    <.icon name="hero-folder-plus" class="size-4" /> Add source
                  </.button>
                </.form>
              </.disclosure>

              <.disclosure
                title="Index Candidate"
                subtitle="Add or update an AFP read-model row from repo-owned artifacts."
              >
                <.form
                  for={@candidate_form}
                  id="candidate-form"
                  phx-submit="create_candidate"
                  class="space-y-2"
                >
                  <.input
                    field={@candidate_form[:demand_source_repo_id]}
                    type="select"
                    label="Source repo"
                    prompt="Choose source"
                    options={source_repo_options(@source_repos)}
                  />
                  <.input
                    field={@candidate_form[:lane]}
                    type="select"
                    label="Lane"
                    options={Factory.options(Factory.demand_lanes())}
                  />
                  <.input field={@candidate_form[:external_id]} label="Candidate id" />
                  <.input field={@candidate_form[:title]} label="Title" required />
                  <.input
                    field={@candidate_form[:source_status]}
                    type="select"
                    label="Source status"
                    options={Factory.options(Factory.demand_candidate_source_statuses())}
                  />
                  <.input
                    field={@candidate_form[:afp_status]}
                    type="select"
                    label="AFP status"
                    options={Factory.options(Factory.demand_candidate_afp_statuses())}
                  />
                  <.input field={@candidate_form[:score]} type="number" label="Score" />
                  <.input
                    field={@candidate_form[:confidence]}
                    type="select"
                    label="Confidence"
                    options={Factory.options(Factory.demand_confidences())}
                  />
                  <.input field={@candidate_form[:target_user]} label="Target user" />
                  <.input
                    field={@candidate_form[:demand_signal]}
                    type="textarea"
                    label="Demand signal"
                    rows="3"
                  />
                  <.input
                    field={@candidate_form[:incumbent_weakness]}
                    type="textarea"
                    label="Incumbent weakness"
                    rows="3"
                  />
                  <.input
                    field={@candidate_form[:wedge_hypothesis]}
                    type="textarea"
                    label="Wedge hypothesis"
                    rows="3"
                  />
                  <.input
                    field={@candidate_form[:validation_action]}
                    type="textarea"
                    label="Validation action"
                    rows="3"
                  />
                  <.input field={@candidate_form[:primary_path]} label="Primary path" />
                  <.input field={@candidate_form[:report_path]} label="Report path" />
                  <.input field={@candidate_form[:package_path]} label="Package path" />
                  <.input
                    field={@candidate_form[:evidence_paths]}
                    type="textarea"
                    label="Evidence paths"
                    rows="3"
                  />
                  <.input
                    field={@candidate_form[:limitations]}
                    type="textarea"
                    label="Limitations"
                    rows="2"
                  />
                  <.button type="submit" variant="primary">
                    <.icon name="hero-queue-list" class="size-4" /> Index candidate
                  </.button>
                </.form>
              </.disclosure>

              <.disclosure
                title="Message Template"
                subtitle="Create a reusable launch or follow-up prompt."
              >
                <.form
                  for={@message_template_form}
                  id="message-template-form"
                  phx-submit="create_message_template"
                  class="space-y-2"
                >
                  <.input field={@message_template_form[:name]} label="Name" required />
                  <.input
                    field={@message_template_form[:purpose]}
                    type="textarea"
                    label="Purpose"
                    rows="2"
                  />
                  <.input
                    field={@message_template_form[:default_run_type]}
                    type="select"
                    label="Run type"
                    options={Factory.options(Factory.demand_research_run_types())}
                  />
                  <.input
                    field={@message_template_form[:default_lane]}
                    type="select"
                    label="Lane"
                    options={Factory.options(Factory.demand_lanes())}
                  />
                  <.input
                    field={@message_template_form[:default_target]}
                    type="select"
                    label="Target"
                    options={Factory.options(Factory.demand_message_targets())}
                  />
                  <.input
                    field={@message_template_form[:required_variables]}
                    type="textarea"
                    label="Required variables"
                    rows="2"
                  />
                  <.input
                    field={@message_template_form[:body]}
                    type="textarea"
                    label="Body"
                    rows="8"
                    required
                  />
                  <.input
                    field={@message_template_form[:safety_notes]}
                    type="textarea"
                    label="Safety notes"
                    rows="2"
                  />
                  <.input
                    field={@message_template_form[:expected_output_paths]}
                    type="textarea"
                    label="Expected output paths"
                    rows="2"
                  />
                  <.button type="submit" variant="primary">
                    <.icon name="hero-document-plus" class="size-4" /> Add template
                  </.button>
                </.form>
              </.disclosure>

              <.disclosure
                title="Source Research Handoff"
                subtitle="Draft a manual idea or URL research run before a candidate exists."
              >
                <.form
                  for={@source_launch_form}
                  id="source-launch-form"
                  phx-submit="create_source_launch"
                  class="space-y-2"
                >
                  <.input
                    field={@source_launch_form[:source_repo_id]}
                    type="select"
                    label="Source repo"
                    prompt="Choose source"
                    options={source_repo_options(@source_repos)}
                  />
                  <.input
                    field={@source_launch_form[:message_template_id]}
                    type="select"
                    label="Template"
                    prompt="Choose template"
                    options={message_template_options(@message_templates)}
                  />
                  <.input
                    field={@source_launch_form[:run_type]}
                    type="select"
                    label="Run type"
                    options={Factory.options(Factory.demand_research_run_types())}
                  />
                  <.input
                    field={@source_launch_form[:lane]}
                    type="select"
                    label="Lane"
                    options={Factory.options(Factory.demand_lanes())}
                  />
                  <.input
                    field={@source_launch_form[:input_text]}
                    type="textarea"
                    label="Idea or keywords"
                    rows="3"
                  />
                  <.input field={@source_launch_form[:input_url]} label="URL" />
                  <.input field={@source_launch_form[:title]} label="Launch title" />
                  <.input
                    field={@source_launch_form[:objective]}
                    type="textarea"
                    label="Objective"
                    rows="2"
                  />
                  <.input
                    field={@source_launch_form[:risk_level]}
                    type="select"
                    label="Risk"
                    options={Factory.options(Factory.risk_levels())}
                  />
                  <.input
                    field={@source_launch_form[:status]}
                    type="select"
                    label="Status"
                    options={Factory.options(Factory.launch_request_statuses())}
                  />
                  <.input field={@source_launch_form[:confirmation]} label="Confirmation" />
                  <.input
                    field={@source_launch_form[:edited_body]}
                    type="textarea"
                    label="Edited message"
                    rows="8"
                  />
                  <.button type="submit" variant="primary">
                    <.icon name="hero-magnifying-glass" class="size-4" /> Create research handoff
                  </.button>
                </.form>
              </.disclosure>

              <.disclosure
                title="Candidate Handoff"
                subtitle="Render a template, optionally edit it, and create a manual launch request."
              >
                <.form
                  for={@candidate_launch_form}
                  id="candidate-launch-form"
                  phx-submit="create_candidate_launch"
                  class="space-y-2"
                >
                  <.input
                    field={@candidate_launch_form[:candidate_id]}
                    type="select"
                    label="Candidate"
                    prompt="Choose candidate"
                    options={candidate_options(@demand_candidates)}
                  />
                  <.input
                    field={@candidate_launch_form[:message_template_id]}
                    type="select"
                    label="Template"
                    prompt="Choose template"
                    options={message_template_options(@message_templates)}
                  />
                  <.input field={@candidate_launch_form[:title]} label="Launch title" />
                  <.input
                    field={@candidate_launch_form[:objective]}
                    type="textarea"
                    label="Objective"
                    rows="2"
                  />
                  <.input
                    field={@candidate_launch_form[:risk_level]}
                    type="select"
                    label="Risk"
                    options={Factory.options(Factory.risk_levels())}
                  />
                  <.input
                    field={@candidate_launch_form[:status]}
                    type="select"
                    label="Status"
                    options={Factory.options(Factory.launch_request_statuses())}
                  />
                  <.input field={@candidate_launch_form[:confirmation]} label="Confirmation" />
                  <.input
                    field={@candidate_launch_form[:edited_body]}
                    type="textarea"
                    label="Edited message"
                    rows="8"
                  />
                  <.button type="submit" variant="primary">
                    <.icon name="hero-command-line" class="size-4" /> Create handoff
                  </.button>
                </.form>
              </.disclosure>

              <.disclosure
                title="Continue Session"
                subtitle="Draft a follow-up message for an existing Codex session."
              >
                <.form
                  for={@session_followup_form}
                  id="session-followup-form"
                  phx-submit="create_session_followup"
                  class="space-y-2"
                >
                  <.input
                    field={@session_followup_form[:research_run_id]}
                    type="select"
                    label="Research run"
                    prompt="Choose run"
                    options={research_run_options(@research_runs)}
                  />
                  <.input
                    field={@session_followup_form[:codex_session_id]}
                    type="select"
                    label="Codex session"
                    prompt="Choose session"
                    options={codex_session_options(@codex_sessions)}
                  />
                  <.input
                    field={@session_followup_form[:message_template_id]}
                    type="select"
                    label="Template"
                    prompt="Choose template"
                    options={message_template_options(@message_templates)}
                  />
                  <.input field={@session_followup_form[:title]} label="Launch title" />
                  <.input
                    field={@session_followup_form[:objective]}
                    type="textarea"
                    label="Objective"
                    rows="2"
                  />
                  <.input
                    field={@session_followup_form[:review_note]}
                    type="textarea"
                    label="Review note"
                    rows="3"
                  />
                  <.input
                    field={@session_followup_form[:risk_level]}
                    type="select"
                    label="Risk"
                    options={Factory.options(Factory.risk_levels())}
                  />
                  <.input
                    field={@session_followup_form[:status]}
                    type="select"
                    label="Status"
                    options={Factory.options(Factory.launch_request_statuses())}
                  />
                  <.input field={@session_followup_form[:confirmation]} label="Confirmation" />
                  <.input
                    field={@session_followup_form[:edited_body]}
                    type="textarea"
                    label="Edited message"
                    rows="8"
                  />
                  <.button type="submit" variant="primary">
                    <.icon name="hero-chat-bubble-left-right" class="size-4" /> Create follow-up
                  </.button>
                </.form>
              </.disclosure>

              <.disclosure
                title="Add Demand Item"
                subtitle="Capture source evidence, target user, wedge, and validation action."
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

  defp source_repo_options(source_repos),
    do: Enum.map(source_repos, &{&1.display_name, &1.id})

  defp candidate_options(candidates), do: Enum.map(candidates, &{&1.title, &1.id})

  defp message_template_options(templates), do: Enum.map(templates, &{&1.name, &1.id})

  defp research_run_options(research_runs) do
    Enum.map(research_runs, fn run ->
      {"#{Factory.labelize(run.run_type)} · #{run.objective}", run.id}
    end)
  end

  defp codex_session_options(codex_sessions) do
    Enum.map(codex_sessions, fn session ->
      {session.external_session_id, session.id}
    end)
  end

  defp legacy_adapter(source_repo) do
    get_in(source_repo.payload || %{}, ["legacy_adapter"])
  end

  defp demand_options(demand_items), do: Enum.map(demand_items, &{&1.title, &1.id})

  defp refresh_error({:source_unhealthy, health_state}) do
    "Source is #{Factory.labelize(health_state)}; repair source health before indexing."
  end

  defp refresh_error(:read_operation_not_allowed) do
    "Manifest must allow read_index or read_candidates before AFP reads repo SQLite."
  end

  defp refresh_error(:candidates_table_missing),
    do: "Repo SQLite is missing the candidates table."

  defp refresh_error({:missing_columns, columns}) do
    "Repo SQLite candidates table is missing: #{Enum.join(columns, ", ")}."
  end

  defp refresh_error(:source_repo_missing), do: "Candidate is not linked to a source repo."
  defp refresh_error(:package_path_missing), do: "Candidate does not have a package path."

  defp refresh_error(:package_outside_source_repo),
    do: "Package path must stay inside the source repo."

  defp refresh_error({:package_missing, paths}) do
    "Package is missing required files: #{Enum.join(paths, ", ")}."
  end

  defp refresh_error(:sqlite3_unavailable), do: "sqlite3 is unavailable on this machine."
  defp refresh_error({:sqlite_error, message}), do: "SQLite read failed: #{message}"
  defp refresh_error({:invalid_sqlite_json, message}), do: "SQLite JSON output failed: #{message}"
  defp refresh_error(_reason), do: "Could not refresh source."

  defp first_error(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &"#{Factory.labelize(field)} #{&1}")
    end)
    |> List.first()
  end

  defp first_error(_reason), do: nil
end
