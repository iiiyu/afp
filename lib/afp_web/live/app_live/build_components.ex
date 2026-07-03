# @input  - Build read-model structs, repo health, launch-block state, live activity
# @output - Function components for the app repo detail's build surface
# @pos    - Render layer for BuildRunner v2 on the App detail page
defmodule AfpWeb.AppLive.BuildComponents do
  @moduledoc false

  use AfpWeb, :html

  alias Afp.Factory.Builds.BuildRun

  attr :repo_health, :map, default: nil
  attr :milestones, :list, required: true
  attr :launch_blocked, :any, default: nil
  attr :task_form, Phoenix.HTML.Form, required: true

  def build_panel(assigns) do
    ~H"""
    <.panel title="Build">
      <:subtitle>
        Milestones and runs live in the repo's afp/state.sqlite (afp-app-repo/v1).
      </:subtitle>
      <:actions>
        <.status_badge :if={@repo_health} status={@repo_health.health_state} />
      </:actions>

      <div :if={is_nil(@repo_health)} class="text-sm text-slate-500">
        No repository path configured.
      </div>

      <div :if={@repo_health && @repo_health.health_state != "healthy"} class="space-y-1 text-sm">
        <p class="text-slate-600 dark:text-slate-300">
          Repo is not launchable: <span class="font-medium">{@repo_health.health_state}</span>
        </p>
        <p :for={note <- @repo_health.notes} class="text-xs text-slate-500">{note}</p>
      </div>

      <div :if={@repo_health && @repo_health.health_state == "healthy"} class="space-y-4">
        <div
          :if={@launch_blocked}
          class="rounded border border-amber-300 bg-amber-50 px-3 py-2 text-xs text-amber-900 dark:border-amber-700 dark:bg-amber-950 dark:text-amber-200"
        >
          <%= case @launch_blocked do %>
            <% {:active_run, run} -> %>
              A run is in flight ({BuildRun.subject(run)}) — per-app launches are serial.
            <% {:unreviewed_run, run} -> %>
              Review gate: mark run for “{BuildRun.subject(run)}” reviewed before the next launch.
          <% end %>
        </div>

        <div>
          <div class="mb-1 text-xs font-semibold uppercase tracking-wide text-slate-500">
            Milestones
          </div>
          <div :if={@milestones == []} class="text-sm text-slate-500">
            No milestones in the state db yet (scaffold seeds them from spec/08-milestones.md).
          </div>
          <div class="divide-y divide-slate-100 dark:divide-slate-800">
            <div
              :for={milestone <- @milestones}
              id={"milestone-#{milestone.milestone_key}"}
              class="flex items-center gap-3 py-2 text-sm"
            >
              <span class="w-5 shrink-0 text-xs text-slate-400">{milestone.milestone_index}</span>
              <.status_badge status={milestone.status} />
              <div class="min-w-0 flex-1">
                <div class="font-medium text-slate-950 dark:text-white">{milestone.title}</div>
                <div class="truncate text-xs text-slate-500">
                  {milestone.milestone_key}
                  <span :if={milestone.summary}>· {milestone.summary}</span>
                </div>
              </div>
              <button
                :if={Afp.Factory.Builds.Milestone.launchable?(milestone) && is_nil(@launch_blocked)}
                type="button"
                phx-click="launch_milestone"
                phx-value-key={milestone.milestone_key}
                data-confirm={"Launch the agent against #{milestone.milestone_key}?"}
                class="shrink-0 rounded border border-emerald-400 px-2 py-1 text-xs font-medium text-emerald-700 hover:bg-emerald-50 dark:border-emerald-700 dark:text-emerald-300 dark:hover:bg-emerald-950"
              >
                Launch
              </button>
            </div>
          </div>
        </div>

        <.form for={@task_form} id="build-task-form" phx-submit="launch_task" class="space-y-2">
          <.input
            field={@task_form[:task_text]}
            type="textarea"
            rows="2"
            label="Ad-hoc task"
            placeholder="One bounded task for the agent (retrofit fallback)"
          />
          <.button type="submit" variant="primary" disabled={not is_nil(@launch_blocked)}>
            <.icon name="hero-play" class="size-4" /> Launch task
          </.button>
        </.form>
      </div>
    </.panel>
    """
  end

  attr :runs, :list, required: true
  attr :run_activity, :list, required: true

  def runs_panel(assigns) do
    ~H"""
    <.panel title="Build runs">
      <:subtitle>Newest first; a completed run must be reviewed before the next launch.</:subtitle>
      <div :if={@runs == []} class="text-sm text-slate-500">No runs yet.</div>

      <div :if={@run_activity != []} class="mb-3">
        <div class="mb-1 text-xs font-semibold uppercase tracking-wide text-slate-500">
          Live activity
        </div>
        <div class="max-h-56 space-y-1.5 overflow-y-auto rounded border border-slate-200 bg-slate-50 p-2 dark:border-slate-800 dark:bg-slate-950">
          <div
            :for={entry <- @run_activity}
            id={"build-activity-#{entry["id"]}"}
            class="flex items-start gap-1.5 text-xs"
          >
            <.icon
              name={activity_icon(entry["kind"])}
              class={[
                "mt-0.5 size-3.5 shrink-0",
                if(entry["kind"] == "tool_error", do: "text-red-500", else: "text-slate-400")
              ]}
            />
            <span class="min-w-0 break-words text-slate-600 dark:text-slate-300">
              {entry["text"]}
            </span>
          </div>
        </div>
      </div>

      <div class="divide-y divide-slate-100 dark:divide-slate-800">
        <article :for={run <- @runs} id={"build-run-#{run.id}"} class="space-y-1 py-3 text-sm">
          <div class="flex flex-wrap items-center gap-2">
            <.status_badge status={run.status} />
            <span class="font-medium text-slate-950 dark:text-white">{BuildRun.subject(run)}</span>
            <span :if={run.verify_pass == true} class="text-xs text-emerald-600">verify pass</span>
            <span :if={run.verify_pass == false} class="text-xs text-red-600">verify fail</span>
            <span :if={run.reviewed_at} class="text-xs text-slate-500">reviewed</span>
            <span
              :if={BuildRun.awaiting_review?(run)}
              class="rounded bg-amber-100 px-1.5 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-200"
            >
              awaiting review
            </span>
          </div>

          <div :if={run.verify["gates"]} class="text-xs text-slate-500">
            {gate_summary(run.verify)}
            <span :if={run.verify["retried_infra_false_red"]}>· retried infra false-red</span>
          </div>

          <div class="text-xs text-slate-500">
            {run.agent} · {short_timestamp(run.created_at)}
            <span :if={run.agent_session_id} class="break-all">· {run.agent_session_id}</span>
          </div>

          <p :if={run.final_answer} class="line-clamp-2 text-xs text-slate-600 dark:text-slate-300">
            {run.final_answer}
          </p>
          <p :if={run.error} class="text-xs text-red-700 dark:text-red-300">{run.error}</p>

          <div class="flex gap-2 pt-1">
            <button
              :if={BuildRun.awaiting_review?(run)}
              type="button"
              phx-click="mark_run_reviewed"
              phx-value-run-id={run.id}
              class="rounded border border-slate-300 px-2 py-1 text-xs font-medium hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800"
            >
              Mark reviewed
            </button>
            <button
              :if={BuildRun.active?(run)}
              type="button"
              phx-click="force_fail_run"
              phx-value-run-id={run.id}
              data-confirm="Force-fail this run?"
              class="rounded border border-red-300 px-2 py-1 text-xs font-medium text-red-700 hover:bg-red-50 dark:border-red-800 dark:text-red-300 dark:hover:bg-red-950"
            >
              Force fail
            </button>
          </div>
        </article>
      </div>
    </.panel>
    """
  end

  attr :report_files, :list, required: true
  attr :selected_report_name, :string, default: nil
  attr :selected_report, :string, default: nil

  def reports_panel(assigns) do
    ~H"""
    <.panel :if={@report_files != []} title="Reports">
      <:subtitle>afp/reports/ in the app repo.</:subtitle>
      <div class="flex flex-wrap gap-2">
        <button
          :for={name <- @report_files}
          type="button"
          phx-click="select_report"
          phx-value-name={name}
          class={[
            "rounded border px-2 py-1 text-xs font-medium",
            if(@selected_report_name == name,
              do:
                "border-slate-950 bg-slate-950 text-white dark:border-white dark:bg-white dark:text-slate-950",
              else: "border-slate-300 hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800"
            )
          ]}
        >
          {name}
        </button>
      </div>
      <pre
        :if={@selected_report}
        class="mt-3 max-h-96 overflow-auto whitespace-pre-wrap break-words rounded border border-slate-200 bg-slate-50 p-3 font-mono text-xs leading-5 text-slate-800 dark:border-slate-800 dark:bg-slate-950 dark:text-slate-100"
      >{@selected_report}</pre>
    </.panel>
    """
  end

  defp gate_summary(%{"gates" => gates}) when is_list(gates) do
    Enum.map_join(gates, ", ", fn gate -> "#{gate["id"]}=#{gate["status"]}" end)
  end

  defp gate_summary(_verify), do: nil

  defp activity_icon("tool"), do: "hero-wrench-screwdriver"
  defp activity_icon("tool_error"), do: "hero-exclamation-triangle"
  defp activity_icon(_kind), do: "hero-chat-bubble-left-ellipsis"

  defp short_timestamp(nil), do: "–"

  defp short_timestamp(timestamp) when is_binary(timestamp) do
    timestamp |> String.replace("T", " ") |> String.slice(0, 16)
  end
end
