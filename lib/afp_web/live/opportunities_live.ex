# @input  - Opportunity repo setup forms, raw demand prompts, route params, and factory events
# @output - Opportunities repo console, launch form, table list, detail status, and Markdown/image file browser
# @pos    - LiveView surface for creating and reviewing portable opportunity repo work
defmodule AfpWeb.OpportunitiesLive do
  use AfpWeb, :live_view

  import AfpWeb.OpportunitiesLive.Components
  import AfpWeb.OpportunitiesLive.DetailComponents

  alias Afp.Factory.Builds
  alias Afp.Factory.Events
  alias Afp.Factory.Opportunities
  alias Afp.Factory.Opportunities.ActivityFeed

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
      %{id: ^opportunity_id} ->
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
        level = if Opportunities.repo_healthy?(repo), do: :info, else: :error

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

  def handle_event("opportunity_form_changed", %{"opportunity" => params}, socket) do
    previous_agent = socket.assigns.opportunity_form.params["agent"]

    params =
      if params["agent"] == previous_agent do
        params
      else
        Map.merge(params, %{"model" => "", "model_custom" => ""})
      end

    {:noreply, assign(socket, :opportunity_form, to_form(params, as: :opportunity))}
  end

  def handle_event("create_opportunity", %{"opportunity" => params}, socket) do
    case params
         |> Opportunities.resolve_model_selection()
         |> Opportunities.create_opportunity() do
      {:ok, %{opportunity: opportunity}} ->
        agent_label = Opportunities.agent_label(opportunity.agent)

        {:noreply,
         socket
         |> put_flash(:info, "Opportunity created and #{agent_label} launch started.")
         |> assign(:opportunity_form, new_opportunity_form())
         |> push_navigate(to: ~p"/opportunities/#{opportunity.id}")}

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

  def handle_event("relaunch_opportunity", %{"id" => id}, socket) do
    case Opportunities.relaunch_opportunity(id) do
      {:ok, %{opportunity: opportunity}} ->
        agent_label = Opportunities.agent_label(opportunity.agent)

        {:noreply,
         socket
         |> put_flash(:info, "#{agent_label} launch restarted.")
         |> load_opportunities(current_params(socket))}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, launch_error(reason))
         |> load_opportunities(current_params(socket))}
    end
  end

  def handle_event("generate_build_spec", %{"id" => id}, socket) do
    case Opportunities.generate_build_spec(id) do
      {:ok, %{opportunity: opportunity}} ->
        {:noreply,
         socket
         |> put_flash(:info, "PRD/spec generation launched for #{opportunity.title}.")
         |> load_opportunities(current_params(socket))}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, launch_error(reason))
         |> load_opportunities(current_params(socket))}
    end
  end

  def handle_event("promote_opportunity", %{"promote" => params}, socket) do
    opportunity = socket.assigns.selected_opportunity

    case Builds.promote_opportunity(opportunity.id, params) do
      {:ok, app} ->
        {:noreply,
         socket
         |> put_flash(:info, "App repo created from the template — continue the build here.")
         |> push_navigate(to: ~p"/apps/#{app.id}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, promote_error(reason))
         |> load_opportunities(current_params(socket))}
    end
  end

  def handle_event("select_file", %{"path" => path}, socket) do
    case socket.assigns.selected_opportunity do
      nil ->
        {:noreply, socket}

      opportunity ->
        {:noreply, assign_selected_file(socket, opportunity.id, path)}
    end
  end

  defp load_opportunities(socket, params) do
    repo = Opportunities.configured_repo()

    opportunities =
      if Opportunities.repo_healthy?(repo), do: Opportunities.list_opportunities(), else: []

    socket =
      socket
      |> assign(:params, params)
      |> assign(:repo, repo)
      |> assign(:repo_healthy?, Opportunities.repo_healthy?(repo))
      |> assign(:opportunities, opportunities)
      |> assign(:opportunity_count, length(opportunities))
      |> assign(:running_count, Enum.count(opportunities, &Opportunities.running?/1))

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
        |> assign(:step_evidence, step_evidence_for(id))
        |> assign(:active_run, Enum.find(runs, &Opportunities.running?/1))
        |> assign(:promote_form, promote_form(opportunity))
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

  defp step_evidence_for(opportunity_id) do
    case Opportunities.list_step_evidence(opportunity_id) do
      evidence when is_list(evidence) -> Enum.group_by(evidence, & &1.step_key)
      _error -> %{}
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
    |> assign(:step_evidence, %{})
  end

  defp maybe_refresh_selected(socket, opportunity_id) do
    now = System.monotonic_time(:millisecond)

    if ActivityFeed.refresh_due?(socket.assigns[:last_selected_refresh_at], now) do
      socket
      |> assign(:last_selected_refresh_at, now)
      |> load_selected(opportunity_id)
    else
      socket
    end
  end

  defp clear_run_activity_on_switch(socket, id) do
    case socket.assigns[:selected_opportunity] do
      %{id: ^id} -> socket
      _selected -> assign(socket, :run_activity, [])
    end
  end

  defp append_run_activity(socket, activity) do
    assign(
      socket,
      :run_activity,
      ActivityFeed.append(socket.assigns[:run_activity] || [], activity)
    )
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

  defp new_opportunity_form do
    to_form(%{"agent" => "claude_code", "model" => ""}, as: :opportunity)
  end

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

  defp launch_error(:opportunity_not_researched),
    do: "Research must complete before PRD generation."

  defp launch_error({:repo_unhealthy, state}),
    do: "Opportunity repo is not healthy yet: #{state}."

  defp launch_error(reason), do: "Could not launch opportunity: #{inspect(reason)}"

  defp promote_form(opportunity) do
    to_form(%{"name" => String.slice(opportunity.title || "", 0, 60), "repo_path" => ""},
      as: :promote
    )
  end

  defp promote_error(:app_name_required), do: "App name is required."
  defp promote_error(:repo_path_required), do: "New repo path is required."
  defp promote_error(:already_promoted), do: "This opportunity was already promoted."

  defp promote_error({:not_build_spec_ready, status}),
    do: "Opportunity must be build_spec_ready (currently #{status})."

  defp promote_error(:spec_package_missing),
    do: "No spec package found under the opportunity's spec/ directory."

  defp promote_error(:target_not_empty), do: "Target directory is not empty."

  defp promote_error({:template_not_a_git_repo, path}),
    do: "App template is not a git repo: #{path}."

  defp promote_error({:template_export_failed, output}),
    do: "Template export failed: #{output}"

  defp promote_error(%Ecto.Changeset{} = changeset) do
    if changeset.errors[:repo_path],
      do: "An app already uses that repository path.",
      else: "Could not create the app record: #{inspect(changeset.errors)}"
  end

  defp promote_error(reason), do: "Could not promote: #{inspect(reason)}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-4">
        <.opportunities_header
          repo={@repo}
          opportunity_count={@opportunity_count}
          running_count={@running_count}
        />
        <%= cond do %>
          <% !@repo_healthy? -> %>
            <.repo_setup repo={@repo} repo_form={@repo_form} repo_template_form={@repo_template_form} />
          <% is_nil(@selected_opportunity) -> %>
            <.opportunity_index
              repo={@repo}
              opportunity_form={@opportunity_form}
              opportunities={@opportunities}
            />
          <% true -> %>
            <.opportunity_detail
              opportunity={@selected_opportunity}
              runs={@opportunity_runs}
              active_run={@active_run}
              step_results={@step_results}
              step_evidence={@step_evidence}
              files={@opportunity_files}
              selected_file_path={@selected_file_path}
              selected_file={@selected_file}
              run_activity={@run_activity}
              promote_form={@promote_form}
            />
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
