# @input  - Opportunity repo setup forms, raw demand prompts, route params, and factory events
# @output - Opportunities repo console, launch form, table list, detail status, and Markdown/image file browser
# @pos    - LiveView surface for creating and reviewing portable opportunity repo work
defmodule AfpWeb.OpportunitiesLive do
  use AfpWeb, :live_view

  alias Afp.Factory.Events
  alias Afp.Factory.Opportunities

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Events.subscribe()
      Events.subscribe_run_activity()
    end

    {:ok,
     socket
     |> assign(:page_title, "Opportunities")
     |> assign(:repo_form, to_form(%{}, as: :opportunity_repo))
     |> assign(:repo_template_form, to_form(%{}, as: :opportunity_repo_template))
     |> assign(:opportunity_form, new_opportunity_form())
     |> assign(:selected_file_path, nil)
     |> assign(:selected_file, nil)
     |> assign(:run_activity, [])
     |> load_opportunities(params)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, load_opportunities(socket, params)}
  end

  @impl true
  def handle_info({:factory_event, event}, socket) do
    if event.subject_type in ["opportunity_repo", "opportunity", "opportunity_run", "setting"] do
      {:noreply, load_opportunities(socket, current_params(socket))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:opportunity_run_activity, %{opportunity_id: opportunity_id} = message},
        socket
      ) do
    case socket.assigns.selected_opportunity do
      %{"id" => ^opportunity_id} ->
        {:noreply,
         socket
         |> append_run_activity(message.activity)
         |> maybe_refresh_selected(opportunity_id)}

      _selected ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event(
        "create_repo_from_template",
        %{"opportunity_repo_template" => params},
        socket
      ) do
    case Opportunities.create_repo_from_template(params) do
      {:ok, _repo} ->
        {:noreply,
         socket
         |> put_flash(:info, "Opportunity repo initialized.")
         |> assign(:repo_template_form, to_form(%{}, as: :opportunity_repo_template))
         |> load_opportunities(current_params(socket))}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, repo_error(reason))
         |> load_opportunities(current_params(socket))}
    end
  end

  def handle_event("configure_repo", %{"opportunity_repo" => params}, socket) do
    case Opportunities.configure_repo(params) do
      {:ok, repo} ->
        level = if repo["health_state"] == "healthy", do: :info, else: :error

        {:noreply,
         socket
         |> put_flash(level, "Opportunity repo health: #{repo["health_state"]}.")
         |> assign(:repo_form, to_form(%{}, as: :opportunity_repo))
         |> load_opportunities(current_params(socket))}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, repo_error(reason))
         |> load_opportunities(current_params(socket))}
    end
  end

  def handle_event("refresh_repo", _params, socket) do
    case Opportunities.refresh_configured_repo() do
      {:ok, repo} ->
        {:noreply,
         socket
         |> put_flash(:info, "Opportunity repo refreshed: #{repo["health_state"]}.")
         |> load_opportunities(current_params(socket))}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, repo_error(reason))
         |> load_opportunities(current_params(socket))}
    end
  end

  def handle_event("create_opportunity", %{"opportunity" => params}, socket) do
    case Opportunities.create_opportunity(params) do
      {:ok, %{opportunity: opportunity}} ->
        agent_label = Opportunities.agent_label(opportunity["agent"])

        {:noreply,
         socket
         |> put_flash(:info, "Opportunity created and #{agent_label} launch started.")
         |> assign(:opportunity_form, new_opportunity_form())
         |> push_navigate(to: ~p"/opportunities/#{opportunity["id"]}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, launch_error(reason))
         |> load_opportunities(current_params(socket))}
    end
  end

  def handle_event("open_opportunity", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/opportunities/#{id}")}
  end

  def handle_event("select_file", %{"path" => path}, socket) do
    case socket.assigns.selected_opportunity do
      nil ->
        {:noreply, socket}

      opportunity ->
        {:noreply, assign_selected_file(socket, opportunity["id"], path)}
    end
  end

  defp load_opportunities(socket, params) do
    repo = Opportunities.configured_repo()
    opportunities = if healthy?(repo), do: Opportunities.list_opportunities(), else: []

    socket =
      socket
      |> assign(:params, params)
      |> assign(:repo, repo)
      |> assign(:repo_healthy?, healthy?(repo))
      |> assign(:opportunities, opportunities)
      |> assign(:opportunity_count, length(opportunities))
      |> assign(:running_count, Enum.count(opportunities, &(&1["status"] == "running")))

    case params["id"] do
      nil -> clear_selected(socket)
      id -> load_selected(socket, id)
    end
  end

  defp load_selected(socket, id) do
    case Opportunities.get_opportunity(id) do
      {:ok, opportunity} ->
        runs = Opportunities.list_runs(id)
        files = files_for(id)
        selected_path = selected_file_path(socket.assigns[:selected_file_path], files)

        socket
        |> clear_run_activity_on_switch(id)
        |> assign(:selected_opportunity, opportunity)
        |> assign(:opportunity_runs, runs)
        |> assign(:opportunity_files, files)
        |> assign(:step_results, step_results_for(id))
        |> assign(:active_run, Enum.find(runs, &(&1["status"] == "running")))
        |> assign_selected_file(id, selected_path)

      {:error, _reason} ->
        socket
        |> put_flash(:error, "Opportunity not found.")
        |> clear_selected()
    end
  end

  defp step_results_for(opportunity_id) do
    case Opportunities.list_step_results(opportunity_id) do
      steps when is_list(steps) -> steps
      _error -> []
    end
  end

  defp clear_selected(socket) do
    socket
    |> assign(:selected_opportunity, nil)
    |> assign(:opportunity_runs, [])
    |> assign(:opportunity_files, [])
    |> assign(:active_run, nil)
    |> assign(:selected_file_path, nil)
    |> assign(:selected_file, nil)
    |> assign(:run_activity, [])
    |> assign(:step_results, [])
  end

  # Live activity arrives much faster than the step rows change; reload the
  # selected opportunity's read model at most once per interval.
  @selected_refresh_interval_ms 2_000

  defp maybe_refresh_selected(socket, opportunity_id) do
    now = System.monotonic_time(:millisecond)
    last = socket.assigns[:last_selected_refresh_at] || 0

    if now - last >= @selected_refresh_interval_ms do
      socket
      |> assign(:last_selected_refresh_at, now)
      |> load_selected(opportunity_id)
    else
      socket
    end
  end

  defp clear_run_activity_on_switch(socket, id) do
    case socket.assigns[:selected_opportunity] do
      %{"id" => ^id} -> socket
      _selected -> assign(socket, :run_activity, [])
    end
  end

  @run_activity_limit 30

  defp append_run_activity(socket, activity) do
    entry = Map.put(activity, "id", System.unique_integer([:positive, :monotonic]))

    activities =
      [entry | socket.assigns[:run_activity] || []]
      |> Enum.take(@run_activity_limit)

    assign(socket, :run_activity, activities)
  end

  defp activity_icon("tool"), do: "hero-wrench-screwdriver"
  defp activity_icon("tool_error"), do: "hero-exclamation-triangle"
  defp activity_icon(_kind), do: "hero-chat-bubble-left-ellipsis"

  defp step_max_score(%{"step_index" => 6}), do: 100
  defp step_max_score(_step), do: 20

  defp step_artifact_available?(step, files) do
    Enum.any?(files, &(&1.relative_path == step["artifact_path"]))
  end

  defp files_for(opportunity_id) do
    case Opportunities.list_opportunity_files(opportunity_id) do
      {:ok, files} -> files
      {:error, _reason} -> []
    end
  end

  defp selected_file_path(current_path, files) do
    cond do
      current_path && Enum.any?(files, &(&1.relative_path == current_path)) ->
        current_path

      files != [] ->
        files |> List.first() |> Map.fetch!(:relative_path)

      true ->
        nil
    end
  end

  defp assign_selected_file(socket, _opportunity_id, nil) do
    socket
    |> assign(:selected_file_path, nil)
    |> assign(:selected_file, nil)
  end

  defp assign_selected_file(socket, opportunity_id, path) do
    case Opportunities.read_opportunity_file(opportunity_id, path) do
      {:ok, file} ->
        socket
        |> assign(:selected_file_path, path)
        |> assign(:selected_file, file)

      {:error, _reason} ->
        socket
        |> assign(:selected_file_path, nil)
        |> assign(:selected_file, nil)
    end
  end

  defp current_params(socket), do: socket.assigns[:params] || %{}
  defp healthy?(%{"health_state" => "healthy"}), do: true
  defp healthy?(_repo), do: false

  defp new_opportunity_form do
    to_form(%{"agent" => "codex"}, as: :opportunity)
  end

  defp agent_options do
    Enum.map(Opportunities.supported_agents(), &{Opportunities.agent_label(&1), &1})
  end

  defp configured_state(nil), do: "Not configured"
  defp configured_state(repo), do: repo["health_state"] || "unknown"

  defp format_value(nil), do: "None"
  defp format_value(""), do: "None"
  defp format_value(value), do: value

  defp format_score(nil), do: "None"
  defp format_score(score), do: score

  defp format_timestamp(nil), do: "None"

  defp format_timestamp(timestamp) when is_binary(timestamp) do
    timestamp
    |> String.replace("T", " ")
    |> String.replace("Z", "")
    |> String.slice(0, 16)
  end

  defp format_timestamp(value), do: to_string(value)

  defp repo_error(:repo_path_required), do: "Repo path is required."
  defp repo_error(:target_path_not_directory), do: "Target path is not a directory."
  defp repo_error(:target_not_empty), do: "Target directory is not empty."
  defp repo_error(:sqlite3_unavailable), do: "sqlite3 is unavailable on this machine."
  defp repo_error(:git_unavailable), do: "git is unavailable on this machine."
  defp repo_error({:target_unreadable, reason}), do: "Target directory is unreadable: #{reason}."
  defp repo_error({:mkdir_failed, path, reason}), do: "Could not create #{path}: #{reason}."
  defp repo_error({:write_failed, path, reason}), do: "Could not write #{path}: #{reason}."
  defp repo_error({:target_file_exists, path}), do: "Target file already exists: #{path}."
  defp repo_error({:sqlite_schema_failed, output}), do: "Could not create base.sqlite: #{output}."
  defp repo_error({:git_init_failed, output}), do: "Could not initialize git repo: #{output}."
  defp repo_error(reason), do: "Could not configure opportunity repo: #{inspect(reason)}"

  defp launch_error(:raw_input_required), do: "Input is required."
  defp launch_error({:unsupported_agent, agent}), do: "Unsupported agent: #{agent}."
  defp launch_error(:repo_path_required), do: "Configure an opportunity repo first."

  defp launch_error({:repo_unhealthy, state}),
    do: "Opportunity repo is not healthy yet: #{state}."

  defp launch_error(reason), do: "Could not launch opportunity: #{inspect(reason)}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-4">
        <.page_header
          eyebrow="Discovery"
          title="Opportunities"
          subtitle="Portable opportunity research repo, simple prompt launch, Codex/Claude Code run state, and Markdown/image review."
        >
          <:meta>
            <.summary_item
              title="Repo"
              value={configured_state(@repo)}
              status={configured_state(@repo)}
            />
            <.summary_item title="Opportunities" value={@opportunity_count} hint="repo-local index" />
            <.summary_item title="Running" value={@running_count} hint="active agent work" />
          </:meta>
        </.page_header>

        <%= if !@repo_healthy? do %>
          <div class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_420px]">
            <main class="space-y-4">
              <.panel title="Repo Health">
                <:subtitle>
                  Required root: base.sqlite, opportunities/, AGENTS.md, and .skills/.
                </:subtitle>

                <div :if={is_nil(@repo)}>
                  <.empty_state message="No opportunity repo configured." />
                </div>

                <div :if={!is_nil(@repo)} class="space-y-3">
                  <div class="flex flex-wrap items-center gap-2">
                    <.status_badge status={@repo["health_state"]} />
                    <span class="text-sm text-slate-600 dark:text-slate-300">
                      {@repo["health_summary"]}
                    </span>
                  </div>
                  <div class="text-sm text-slate-600 dark:text-slate-300">
                    <span class="font-medium text-slate-950 dark:text-white">Path:</span>
                    <code class="break-all text-xs">{@repo["repo_path"]}</code>
                  </div>
                  <div
                    :if={@repo["missing_paths"] != [] || @repo["parse_errors"] != []}
                    class="space-y-1 rounded border border-slate-200 bg-slate-50 p-3 text-xs text-slate-600 dark:border-slate-800 dark:bg-slate-950 dark:text-slate-300"
                  >
                    <div :for={path <- @repo["missing_paths"] || []}>
                      Missing: <code class="break-all">{path}</code>
                    </div>
                    <div :for={error <- @repo["parse_errors"] || []}>
                      Note: {error}
                    </div>
                  </div>
                  <button
                    id="refresh-opportunity-repo"
                    type="button"
                    phx-click="refresh_repo"
                    class="inline-flex items-center gap-2 rounded border border-slate-300 px-3 py-2 text-sm font-medium hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800"
                  >
                    <.icon name="hero-arrow-path" class="size-4" /> Refresh
                  </button>
                </div>
              </.panel>
            </main>

            <aside class="space-y-4">
              <.panel title="Initialize Repo">
                <:subtitle>Create a new portable opportunity repo.</:subtitle>
                <.form
                  for={@repo_template_form}
                  id="opportunity-repo-template-form"
                  phx-submit="create_repo_from_template"
                  class="space-y-3"
                >
                  <.input field={@repo_template_form[:repo_path]} label="Repo path" required />
                  <.input field={@repo_template_form[:display_name]} label="Display name" />
                  <button class="inline-flex w-full items-center justify-center gap-2 rounded bg-slate-950 px-3 py-2 text-sm font-medium text-white hover:bg-slate-800 dark:bg-white dark:text-slate-950 dark:hover:bg-slate-200">
                    <.icon name="hero-plus" class="size-4" /> Initialize repo
                  </button>
                </.form>
              </.panel>

              <.panel title="Select Existing">
                <:subtitle>Register a local repo and inspect its structure.</:subtitle>
                <.form
                  for={@repo_form}
                  id="opportunity-repo-form"
                  phx-submit="configure_repo"
                  class="space-y-3"
                >
                  <.input field={@repo_form[:repo_path]} label="Repo path" required />
                  <.input field={@repo_form[:display_name]} label="Display name" />
                  <button class="inline-flex w-full items-center justify-center gap-2 rounded border border-slate-300 px-3 py-2 text-sm font-medium hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800">
                    <.icon name="hero-folder-open" class="size-4" /> Select repo
                  </button>
                </.form>
              </.panel>
            </aside>
          </div>
        <% else %>
          <%= if is_nil(@selected_opportunity) do %>
            <div class="grid gap-4 2xl:grid-cols-[minmax(0,1fr)_420px]">
              <main class="space-y-4">
                <.panel title="New Opportunity">
                  <:subtitle>Send a rough idea, need, or URL into the configured repo.</:subtitle>
                  <.form
                    for={@opportunity_form}
                    id="opportunity-prompt-form"
                    phx-submit="create_opportunity"
                    class="space-y-3"
                  >
                    <.input
                      field={@opportunity_form[:raw_input]}
                      type="textarea"
                      label="Input"
                      required
                    />
                    <.input
                      field={@opportunity_form[:agent]}
                      type="select"
                      label="Agent"
                      options={agent_options()}
                    />
                    <button class="inline-flex items-center gap-2 rounded bg-slate-950 px-3 py-2 text-sm font-medium text-white hover:bg-slate-800 dark:bg-white dark:text-slate-950 dark:hover:bg-slate-200">
                      <.icon name="hero-play" class="size-4" /> Launch agent
                    </button>
                  </.form>
                </.panel>

                <.panel title="Opportunity List">
                  <:subtitle>Rows are backed by the repo-local base.sqlite index.</:subtitle>
                  <div :if={@opportunities == []}>
                    <.empty_state message="No opportunities yet." />
                  </div>
                  <div :if={@opportunities != []} class="overflow-x-auto">
                    <table class="min-w-full divide-y divide-slate-200 text-sm dark:divide-slate-800">
                      <thead>
                        <tr class="text-left text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
                          <th class="px-3 py-2">Title</th>
                          <th class="px-3 py-2">Status</th>
                          <th class="px-3 py-2">Stage</th>
                          <th class="px-3 py-2">Score</th>
                          <th class="px-3 py-2">Route</th>
                          <th class="px-3 py-2">Updated</th>
                        </tr>
                      </thead>
                      <tbody class="divide-y divide-slate-100 dark:divide-slate-800">
                        <tr
                          :for={opportunity <- @opportunities}
                          id={"opportunity-row-#{opportunity["id"]}"}
                          phx-click="open_opportunity"
                          phx-value-id={opportunity["id"]}
                          class="cursor-pointer hover:bg-slate-50 dark:hover:bg-slate-800/60"
                        >
                          <td class="max-w-sm px-3 py-3 font-medium text-slate-950 dark:text-white">
                            <.link
                              navigate={~p"/opportunities/#{opportunity["id"]}"}
                              class="hover:underline"
                            >
                              {opportunity["title"]}
                            </.link>
                            <div
                              :if={opportunity["source_url"]}
                              class="mt-1 truncate text-xs font-normal text-slate-500"
                            >
                              {opportunity["source_url"]}
                            </div>
                          </td>
                          <td class="px-3 py-3"><.status_badge status={opportunity["status"]} /></td>
                          <td class="px-3 py-3 text-slate-600 dark:text-slate-300">
                            {format_value(opportunity["stage"])}
                          </td>
                          <td class="px-3 py-3 text-slate-600 dark:text-slate-300">
                            {format_score(opportunity["total_score"])}
                          </td>
                          <td class="px-3 py-3 text-slate-600 dark:text-slate-300">
                            {format_value(opportunity["route"])}
                          </td>
                          <td class="px-3 py-3 text-slate-500">
                            {format_timestamp(opportunity["updated_at"])}
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                </.panel>
              </main>

              <aside class="space-y-4">
                <.panel title="Configured Repo">
                  <:subtitle>{@repo["display_name"]}</:subtitle>
                  <div class="space-y-2 text-sm text-slate-600 dark:text-slate-300">
                    <div class="flex items-center gap-2">
                      <.status_badge status={@repo["health_state"]} />
                      <span>{@repo["health_summary"]}</span>
                    </div>
                    <code class="block break-all rounded bg-slate-50 p-2 text-xs dark:bg-slate-950">
                      {@repo["repo_path"]}
                    </code>
                    <button
                      id="refresh-healthy-opportunity-repo"
                      type="button"
                      phx-click="refresh_repo"
                      class="inline-flex items-center gap-2 rounded border border-slate-300 px-3 py-2 text-sm font-medium hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800"
                    >
                      <.icon name="hero-arrow-path" class="size-4" /> Refresh
                    </button>
                  </div>
                </.panel>
              </aside>
            </div>
          <% else %>
            <div class="space-y-4">
              <.panel title={@selected_opportunity["title"]}>
                <:subtitle>
                  <.link
                    navigate={~p"/opportunities"}
                    class="inline-flex items-center gap-1 hover:underline"
                  >
                    <.icon name="hero-arrow-left" class="size-3" /> Back to opportunities
                  </.link>
                </:subtitle>
                <div class="grid gap-3 md:grid-cols-4">
                  <.stat title="Status" value={@selected_opportunity["status"]} />
                  <.stat title="Stage" value={@selected_opportunity["stage"]} />
                  <.stat title="Score" value={format_score(@selected_opportunity["total_score"])} />
                  <.stat title="Route" value={format_value(@selected_opportunity["route"])} />
                </div>
                <div class="mt-4 grid gap-3 text-sm text-slate-600 dark:text-slate-300 lg:grid-cols-2">
                  <div>
                    <span class="font-medium text-slate-950 dark:text-white">Session:</span>
                    {format_value(@selected_opportunity["codex_session_id"])}
                  </div>
                  <div>
                    <span class="font-medium text-slate-950 dark:text-white">Updated:</span>
                    {format_timestamp(@selected_opportunity["updated_at"])}
                  </div>
                  <p :if={@selected_opportunity["latest_summary"]} class="lg:col-span-2">
                    {@selected_opportunity["latest_summary"]}
                  </p>
                  <p
                    :if={@selected_opportunity["error"]}
                    class="text-red-700 dark:text-red-300 lg:col-span-2"
                  >
                    {@selected_opportunity["error"]}
                  </p>
                </div>
              </.panel>

              <div class="grid gap-4 2xl:grid-cols-[minmax(0,1fr)_420px]">
                <main class="space-y-4">
                  <.panel title="Research Steps">
                    <:subtitle>
                      Seven-step pipeline; one artifact and one base.sqlite record per step.
                    </:subtitle>
                    <div :if={@step_results == []}>
                      <.empty_state message="No step records. This opportunity predates the step pipeline." />
                    </div>
                    <div
                      :if={@step_results != []}
                      class="divide-y divide-slate-100 dark:divide-slate-800"
                    >
                      <div
                        :for={step <- @step_results}
                        id={"research-step-#{step["step_key"]}"}
                        class="flex items-center gap-3 py-2 text-sm"
                      >
                        <span class="w-5 shrink-0 text-xs text-slate-400">{step["step_index"]}</span>
                        <div class="min-w-0 flex-1">
                          <div class="flex flex-wrap items-center gap-2">
                            <.status_badge status={step["status"]} />
                            <span class="font-medium text-slate-950 dark:text-white">
                              {Opportunities.step_title(step["step_key"])}
                            </span>
                            <span :if={step["score"]} class="text-xs text-slate-500">
                              {step["score"]}/{step_max_score(step)}
                            </span>
                            <span :if={step["evidence_strength"]} class="text-xs text-slate-500">
                              evidence: {step["evidence_strength"]}
                            </span>
                          </div>
                          <p :if={step["summary"]} class="mt-0.5 truncate text-xs text-slate-500">
                            {step["summary"]}
                          </p>
                        </div>
                        <button
                          :if={step_artifact_available?(step, @opportunity_files)}
                          type="button"
                          phx-click="select_file"
                          phx-value-path={step["artifact_path"]}
                          class="shrink-0 rounded border border-slate-300 px-2 py-1 text-xs font-medium hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800"
                        >
                          View
                        </button>
                      </div>
                    </div>
                  </.panel>

                  <.panel title="Files">
                    <:subtitle>
                      Markdown and image files under the selected opportunity directory.
                    </:subtitle>
                    <div class="grid min-h-[520px] overflow-hidden rounded border border-slate-200 dark:border-slate-800 lg:grid-cols-[280px_1fr]">
                      <aside class="border-b border-slate-200 bg-slate-50 dark:border-slate-800 dark:bg-slate-950 lg:border-b-0 lg:border-r">
                        <div :if={@opportunity_files == []} class="p-3">
                          <.empty_state message="No supported files found." />
                        </div>
                        <button
                          :for={file <- @opportunity_files}
                          type="button"
                          phx-click="select_file"
                          phx-value-path={file.relative_path}
                          class={[
                            "flex w-full items-center justify-between gap-2 border-b border-slate-200 px-3 py-2 text-left text-sm hover:bg-white dark:border-slate-800 dark:hover:bg-slate-900",
                            @selected_file_path == file.relative_path &&
                              "bg-white font-medium text-slate-950 dark:bg-slate-900 dark:text-white"
                          ]}
                        >
                          <span class="min-w-0 truncate">
                            <.icon
                              name={
                                if file.type == "image", do: "hero-photo", else: "hero-document-text"
                              }
                              class="mr-1 inline size-4"
                            />
                            {file.relative_path}
                          </span>
                          <span class="shrink-0 text-xs text-slate-500">{file.type}</span>
                        </button>
                      </aside>

                      <section class="min-w-0 bg-white dark:bg-slate-900">
                        <div :if={is_nil(@selected_file)} class="p-4">
                          <.empty_state message="Select a file." />
                        </div>

                        <div :if={@selected_file && @selected_file.type == "markdown"} class="h-full">
                          <div class="border-b border-slate-100 px-4 py-2 text-xs font-medium text-slate-500 dark:border-slate-800">
                            {@selected_file.relative_path}
                          </div>
                          <pre class="min-h-[480px] overflow-auto whitespace-pre-wrap break-words p-4 font-mono text-sm leading-6 text-slate-800 dark:text-slate-100"><%= @selected_file.content %></pre>
                        </div>

                        <div :if={@selected_file && @selected_file.type == "image"} class="p-4">
                          <div class="mb-3 text-xs font-medium text-slate-500">
                            {@selected_file.relative_path}
                          </div>
                          <img
                            src={"data:#{@selected_file.mime_type};base64,#{@selected_file.data}"}
                            class="max-h-[680px] max-w-full rounded border border-slate-200 object-contain dark:border-slate-800"
                            alt={@selected_file.relative_path}
                          />
                        </div>
                      </section>
                    </div>
                  </.panel>
                </main>

                <aside class="space-y-4">
                  <.panel title="Agent Session">
                    <:subtitle>
                      <%= if @active_run do %>
                        Live run state
                      <% else %>
                        Current opportunity stage
                      <% end %>
                    </:subtitle>
                    <div
                      :if={@active_run}
                      class="space-y-2 text-sm text-slate-600 dark:text-slate-300"
                    >
                      <div class="flex items-center gap-2">
                        <.status_badge status={@active_run["status"]} />
                        <span>{@active_run["stage"]}</span>
                      </div>
                      <div>
                        <span class="font-medium text-slate-950 dark:text-white">Agent:</span>
                        {Opportunities.agent_label(@active_run["agent"])}
                      </div>
                      <div>
                        <span class="font-medium text-slate-950 dark:text-white">Session:</span>
                        {format_value(@active_run["codex_session_id"])}
                      </div>
                      <div>
                        <span class="font-medium text-slate-950 dark:text-white">Turn:</span>
                        {format_value(@active_run["codex_turn_id"])}
                      </div>
                    </div>
                    <div
                      :if={is_nil(@active_run)}
                      class="space-y-2 text-sm text-slate-600 dark:text-slate-300"
                    >
                      <div class="flex items-center gap-2">
                        <.status_badge status={@selected_opportunity["status"]} />
                        <span>{@selected_opportunity["stage"]}</span>
                      </div>
                      <div>
                        <span class="font-medium text-slate-950 dark:text-white">Agent:</span>
                        {Opportunities.agent_label(@selected_opportunity["agent"])}
                      </div>
                      <div>
                        <span class="font-medium text-slate-950 dark:text-white">Session:</span>
                        {format_value(@selected_opportunity["codex_session_id"])}
                      </div>
                    </div>

                    <div :if={@run_activity != []} class="mt-3">
                      <div class="mb-1 text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
                        Live activity
                      </div>
                      <div
                        id="agent-activity-feed"
                        class="max-h-72 space-y-1.5 overflow-y-auto rounded border border-slate-200 bg-slate-50 p-2 dark:border-slate-800 dark:bg-slate-950"
                      >
                        <div
                          :for={entry <- @run_activity}
                          id={"agent-activity-#{entry["id"]}"}
                          class="flex items-start gap-1.5 text-xs"
                        >
                          <.icon
                            name={activity_icon(entry["kind"])}
                            class={[
                              "mt-0.5 size-3.5 shrink-0",
                              if(entry["kind"] == "tool_error",
                                do: "text-red-500",
                                else: "text-slate-400"
                              )
                            ]}
                          />
                          <span class="min-w-0 break-words text-slate-600 dark:text-slate-300">
                            {entry["text"]}
                          </span>
                        </div>
                      </div>
                    </div>
                  </.panel>

                  <.panel title="Runs">
                    <div :if={@opportunity_runs == []}>
                      <.empty_state message="No runs recorded." />
                    </div>
                    <div class="divide-y divide-slate-100 dark:divide-slate-800">
                      <article :for={run <- @opportunity_runs} class="py-3 text-sm">
                        <div class="flex flex-wrap items-center gap-2">
                          <.status_badge status={run["status"]} />
                          <span class="font-medium text-slate-950 dark:text-white">
                            {run["run_type"]}
                          </span>
                          <span class="text-xs text-slate-500">
                            {Opportunities.agent_label(run["agent"])}
                          </span>
                        </div>
                        <div class="mt-1 text-slate-600 dark:text-slate-300">
                          {run["stage"]} · {format_timestamp(run["updated_at"])}
                        </div>
                        <div
                          :if={run["codex_session_id"]}
                          class="mt-1 break-all text-xs text-slate-500"
                        >
                          {run["codex_session_id"]}
                        </div>
                        <p :if={run["error"]} class="mt-1 text-xs text-red-700 dark:text-red-300">
                          {run["error"]}
                        </p>
                      </article>
                    </div>
                  </.panel>
                </aside>
              </div>
            </div>
          <% end %>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
