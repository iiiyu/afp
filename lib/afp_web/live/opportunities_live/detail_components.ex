# @input  - A selected opportunity struct, its runs/steps/files, and live activity
# @output - The opportunity detail surface (header, steps, files, session, runs)
# @pos    - Render layer for the selected-opportunity view
defmodule AfpWeb.OpportunitiesLive.DetailComponents do
  @moduledoc false

  use AfpWeb, :html

  import AfpWeb.OpportunitiesLive.Components,
    only: [format_value: 1, format_score: 1, format_timestamp: 1]

  alias Afp.Factory.Opportunities

  attr :opportunity, Afp.Factory.Opportunities.Opportunity, required: true
  attr :runs, :list, required: true
  attr :active_run, :any, default: nil
  attr :step_results, :list, required: true
  attr :step_evidence, :map, required: true
  attr :files, :list, required: true
  attr :selected_file_path, :string, default: nil
  attr :selected_file, :any, default: nil
  attr :run_activity, :list, required: true

  def opportunity_detail(assigns) do
    ~H"""
    <div class="space-y-4">
      <.panel title={@opportunity.title}>
        <:subtitle>
          <.link
            navigate={~p"/opportunities"}
            class="inline-flex items-center gap-1 hover:underline"
          >
            <.icon name="hero-arrow-left" class="size-3" /> Back to opportunities
          </.link>
        </:subtitle>
        <div class="grid gap-3 md:grid-cols-4">
          <.stat title="Status" value={@opportunity.status} />
          <.stat title="Stage" value={@opportunity.stage} />
          <.stat title="Score" value={format_score(@opportunity.total_score)} />
          <.stat title="Route" value={format_value(@opportunity.route)} />
        </div>
        <div class="mt-4 grid gap-3 text-sm text-slate-600 dark:text-slate-300 lg:grid-cols-2">
          <div>
            <span class="font-medium text-slate-950 dark:text-white">Session:</span>
            {format_value(@opportunity.agent_session_id)}
          </div>
          <div>
            <span class="font-medium text-slate-950 dark:text-white">Updated:</span>
            {format_timestamp(@opportunity.updated_at)}
          </div>
          <p :if={@opportunity.latest_summary} class="lg:col-span-2">
            {@opportunity.latest_summary}
          </p>
          <p
            :if={@opportunity.error}
            class="text-red-700 dark:text-red-300 lg:col-span-2"
          >
            {@opportunity.error}
          </p>
          <div :if={@opportunity.status == "failed"} class="lg:col-span-2">
            <.button
              phx-click="relaunch_opportunity"
              phx-value-id={@opportunity.id}
              data-confirm="Re-run research for this opportunity?"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Re-run research
            </.button>
          </div>
          <div
            :if={@opportunity.status == "researched" && is_nil(@active_run)}
            class="lg:col-span-2"
          >
            <.button
              id={"generate-build-spec-#{@opportunity.id}"}
              phx-click="generate_build_spec"
              phx-value-id={@opportunity.id}
              data-confirm="Generate a PRD/spec package from this opportunity research?"
            >
              <.icon name="hero-document-plus" class="size-4" /> Generate PRD spec
            </.button>
          </div>
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
                id={"research-step-#{step.step_key}"}
                class="flex items-center gap-3 py-2 text-sm"
              >
                <span class="w-5 shrink-0 text-xs text-slate-400">{step.step_index}</span>
                <div class="min-w-0 flex-1">
                  <div class="flex flex-wrap items-center gap-2">
                    <.status_badge status={step.status} />
                    <span class="font-medium text-slate-950 dark:text-white">
                      {Opportunities.step_title(step.step_key)}
                    </span>
                    <span :if={step.score} class="text-xs text-slate-500">
                      {step.score}/{step_max_score(step)}
                    </span>
                    <span :if={step.evidence_strength} class="text-xs text-slate-500">
                      evidence: {step.evidence_strength}
                    </span>
                  </div>
                  <p :if={step.summary} class="mt-0.5 truncate text-xs text-slate-500">
                    {step.summary}
                  </p>
                  <div
                    :if={Map.has_key?(@step_evidence, step.step_key)}
                    class="mt-1 space-y-0.5"
                  >
                    <button
                      :for={item <- @step_evidence[step.step_key]}
                      id={"step-evidence-#{item.id}"}
                      type="button"
                      phx-click="select_file"
                      phx-value-path={item.file_path}
                      class="flex max-w-full items-center gap-1.5 text-left text-xs text-slate-500 hover:text-slate-950 hover:underline dark:hover:text-white"
                      title={item.why_it_matters}
                    >
                      <.icon
                        name={evidence_icon(item.kind)}
                        class="size-3.5 shrink-0 text-slate-400"
                      />
                      <span class="truncate">{item.title}</span>
                      <span class="shrink-0 text-slate-400">{item.kind}</span>
                    </button>
                  </div>
                </div>
                <button
                  :if={step_artifact_available?(step, @files)}
                  type="button"
                  phx-click="select_file"
                  phx-value-path={step.artifact_path}
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
                <div :if={@files == []} class="p-3">
                  <.empty_state message="No supported files found." />
                </div>
                <button
                  :for={file <- @files}
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
                      name={if file.type == "image", do: "hero-photo", else: "hero-document-text"}
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
                <.status_badge status={@active_run.status} />
                <span>{@active_run.stage}</span>
              </div>
              <div>
                <span class="font-medium text-slate-950 dark:text-white">Agent:</span>
                {Opportunities.agent_label(@active_run.agent)}
              </div>
              <div :if={@active_run.model}>
                <span class="font-medium text-slate-950 dark:text-white">Model:</span>
                {@active_run.model}
              </div>
              <div>
                <span class="font-medium text-slate-950 dark:text-white">Session:</span>
                {format_value(@active_run.agent_session_id)}
              </div>
              <div>
                <span class="font-medium text-slate-950 dark:text-white">Turn:</span>
                {format_value(@active_run.agent_turn_id)}
              </div>
            </div>
            <div
              :if={is_nil(@active_run)}
              class="space-y-2 text-sm text-slate-600 dark:text-slate-300"
            >
              <div class="flex items-center gap-2">
                <.status_badge status={@opportunity.status} />
                <span>{@opportunity.stage}</span>
              </div>
              <div>
                <span class="font-medium text-slate-950 dark:text-white">Agent:</span>
                {Opportunities.agent_label(@opportunity.agent)}
              </div>
              <div>
                <span class="font-medium text-slate-950 dark:text-white">Session:</span>
                {format_value(@opportunity.agent_session_id)}
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
            <div :if={@runs == []}>
              <.empty_state message="No runs recorded." />
            </div>
            <div class="divide-y divide-slate-100 dark:divide-slate-800">
              <article :for={run <- @runs} class="py-3 text-sm">
                <div class="flex flex-wrap items-center gap-2">
                  <.status_badge status={run.status} />
                  <span class="font-medium text-slate-950 dark:text-white">
                    {run.run_type}
                  </span>
                  <span class="text-xs text-slate-500">
                    {Opportunities.agent_label(run.agent)}
                  </span>
                  <span :if={run.model} class="text-xs text-slate-500">
                    · {run.model}
                  </span>
                </div>
                <div class="mt-1 text-slate-600 dark:text-slate-300">
                  {run.stage} · {format_timestamp(run.updated_at)}
                </div>
                <div
                  :if={run.agent_session_id}
                  class="mt-1 break-all text-xs text-slate-500"
                >
                  {run.agent_session_id}
                </div>
                <p :if={run.error} class="mt-1 text-xs text-red-700 dark:text-red-300">
                  {run.error}
                </p>
              </article>
            </div>
          </.panel>
        </aside>
      </div>
    </div>
    """
  end

  defp activity_icon("tool"), do: "hero-wrench-screwdriver"
  defp activity_icon("tool_error"), do: "hero-exclamation-triangle"
  defp activity_icon(_kind), do: "hero-chat-bubble-left-ellipsis"

  defp step_max_score(%{step_index: 6}), do: 100
  defp step_max_score(_step), do: 20

  defp evidence_icon("screenshot"), do: "hero-photo"
  defp evidence_icon("source_excerpt"), do: "hero-chat-bubble-bottom-center-text"
  defp evidence_icon(_kind), do: "hero-document-magnifying-glass"

  defp step_artifact_available?(step, files) do
    Enum.any?(files, &(&1.relative_path == step.artifact_path))
  end
end
