# @input  - Opportunity read-model structs, repo config, forms, and feed entries
# @output - Function components for the opportunities surface
# @pos    - Render layer of the opportunities console; the LiveView stays handlers-only
defmodule AfpWeb.OpportunitiesLive.Components do
  @moduledoc false

  use AfpWeb, :html

  alias Afp.Factory.Opportunities

  attr :repo, :map, default: nil
  attr :opportunity_count, :integer, required: true
  attr :running_count, :integer, required: true

  def opportunities_header(assigns) do
    ~H"""
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
    """
  end

  attr :repo, :map, default: nil
  attr :repo_form, Phoenix.HTML.Form, required: true
  attr :repo_template_form, Phoenix.HTML.Form, required: true

  def repo_setup(assigns) do
    ~H"""
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
    """
  end

  attr :repo, :map, required: true
  attr :opportunity_form, Phoenix.HTML.Form, required: true
  attr :opportunities, :list, required: true

  def opportunity_index(assigns) do
    ~H"""
    <div class="grid gap-4 2xl:grid-cols-[minmax(0,1fr)_420px]">
      <main class="space-y-4">
        <.panel title="New Opportunity">
          <:subtitle>Send a rough idea, need, or URL into the configured repo.</:subtitle>
          <.form
            for={@opportunity_form}
            id="opportunity-prompt-form"
            phx-change="opportunity_form_changed"
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
            <.input
              field={@opportunity_form[:model]}
              type="select"
              label="Model"
              options={model_options(@opportunity_form)}
            />
            <.input
              :if={custom_model_selected?(@opportunity_form)}
              field={@opportunity_form[:model_custom]}
              label="Custom model"
              placeholder="exact model id passed to the CLI"
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
                  id={"opportunity-row-#{opportunity.id}"}
                  phx-click="open_opportunity"
                  phx-value-id={opportunity.id}
                  class="cursor-pointer hover:bg-slate-50 dark:hover:bg-slate-800/60"
                >
                  <td class="max-w-sm px-3 py-3 font-medium text-slate-950 dark:text-white">
                    <.link
                      navigate={~p"/opportunities/#{opportunity.id}"}
                      class="hover:underline"
                    >
                      {opportunity.title}
                    </.link>
                    <div
                      :if={opportunity.source_url}
                      class="mt-1 truncate text-xs font-normal text-slate-500"
                    >
                      {opportunity.source_url}
                    </div>
                  </td>
                  <td class="px-3 py-3"><.status_badge status={opportunity.status} /></td>
                  <td class="px-3 py-3 text-slate-600 dark:text-slate-300">
                    {format_value(opportunity.stage)}
                  </td>
                  <td class="px-3 py-3 text-slate-600 dark:text-slate-300">
                    {format_score(opportunity.total_score)}
                  </td>
                  <td class="px-3 py-3 text-slate-600 dark:text-slate-300">
                    {format_value(opportunity.route)}
                  </td>
                  <td class="px-3 py-3 text-slate-500">
                    {format_timestamp(opportunity.updated_at)}
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
    """
  end

  defp agent_options do
    Enum.map(Opportunities.supported_agents(), &{Opportunities.agent_label(&1), &1})
  end

  defp model_options(form) do
    known = Opportunities.known_models(selected_agent(form))

    [{"CLI default", ""}] ++
      Enum.map(known, &{&1, &1}) ++ [{"Custom…", Opportunities.custom_model_value()}]
  end

  defp selected_agent(form) do
    case form[:agent].value do
      agent when is_binary(agent) and agent != "" -> agent
      _value -> "claude_code"
    end
  end

  defp custom_model_selected?(form),
    do: form[:model].value == Opportunities.custom_model_value()

  defp configured_state(nil), do: "Not configured"
  defp configured_state(repo), do: repo["health_state"] || "unknown"

  def format_value(nil), do: "None"
  def format_value(""), do: "None"
  def format_value(value), do: value

  def format_score(nil), do: "None"
  def format_score(score), do: score

  def format_timestamp(nil), do: "None"

  def format_timestamp(timestamp) when is_binary(timestamp) do
    timestamp
    |> String.replace("T", " ")
    |> String.replace("Z", "")
    |> String.slice(0, 16)
  end

  def format_timestamp(value), do: to_string(value)
end
