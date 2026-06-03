# @input  - Demand, portfolio, session, release, and metrics query outputs
# @output - Today command-center queues with explicit reasons
# @pos    - Read-model context for deciding what needs attention now
defmodule Afp.Factory.Dashboard do
  alias Afp.Factory.Demand
  alias Afp.Factory.Metrics
  alias Afp.Factory.Growth
  alias Afp.Factory.Maintenance
  alias Afp.Factory.Portfolio
  alias Afp.Factory.Repositories
  alias Afp.Factory.Releases
  alias Afp.Factory.Sessions
  alias Afp.Factory.Work

  def today do
    review_sessions = Sessions.list_stopped_review_sessions()
    unlinked_sessions = Sessions.list_unlinked_sessions()
    release_blockers = Releases.list_blocking_targets()
    apps_without_next_action = Portfolio.apps_without_next_action()
    apps_with_invalid_repo = Portfolio.apps_with_invalid_repo()
    repo_attention_scans = Repositories.list_repo_attention_scans()
    active_demand_items = Demand.list_active_demand_items()
    stale_metrics_apps = Metrics.apps_with_stale_metrics()
    due_maintenance = Maintenance.list_due_obligations()
    review_experiments = Growth.list_review_due_experiments()
    active_apps = Portfolio.list_active_apps()

    %{
      focus_queue:
        focus_queue(%{
          review_sessions: review_sessions,
          release_blockers: release_blockers,
          apps_without_next_action: apps_without_next_action,
          apps_with_invalid_repo: apps_with_invalid_repo,
          repo_attention_scans: repo_attention_scans,
          active_demand_items: active_demand_items,
          stale_metrics_apps: stale_metrics_apps,
          unlinked_sessions: unlinked_sessions,
          due_maintenance: due_maintenance,
          review_experiments: review_experiments
        }),
      review_sessions: review_sessions,
      unlinked_sessions: unlinked_sessions,
      release_blockers: release_blockers,
      apps_without_next_action: apps_without_next_action,
      apps_with_invalid_repo: apps_with_invalid_repo,
      repo_attention_scans: repo_attention_scans,
      active_demand_items: active_demand_items,
      stale_metrics_apps: stale_metrics_apps,
      due_maintenance: due_maintenance,
      review_experiments: review_experiments,
      active_apps: active_apps
    }
  end

  def focus_queue(data) do
    data.review_sessions
    |> Enum.map(&session_focus_item/1)
    |> Kernel.++(Enum.map(data.release_blockers, &release_focus_item/1))
    |> Kernel.++(Enum.map(data.apps_with_invalid_repo, &invalid_repo_focus_item/1))
    |> Kernel.++(Enum.map(data.repo_attention_scans, &repo_scan_focus_item/1))
    |> Kernel.++(Enum.map(data.active_demand_items, &demand_focus_item/1))
    |> Kernel.++(Enum.map(data.due_maintenance, &maintenance_focus_item/1))
    |> Kernel.++(Enum.map(data.review_experiments, &experiment_focus_item/1))
    |> Kernel.++(Enum.map(data.apps_without_next_action, &missing_next_action_focus_item/1))
    |> Kernel.++(Enum.map(data.stale_metrics_apps, &stale_metrics_focus_item/1))
    |> Kernel.++(Enum.map(data.unlinked_sessions, &unlinked_session_focus_item/1))
  end

  defp demand_focus_item(demand_item) do
    %{
      type: "demand_validation",
      urgency: 4,
      title: "Validate demand",
      reason: "demand #{demand_item.status}",
      detail: "#{demand_item.title}: #{demand_item.validation_action}",
      app: nil,
      demand_item: demand_item,
      link: "/demand"
    }
  end

  def top_focus_item do
    today().focus_queue |> List.first()
  end

  def active_ticket_count(app_id), do: Work.count_active_tickets(app_id)
  def active_session_count(app_id), do: Sessions.count_active_sessions(app_id)

  defp session_focus_item(session) do
    %{
      type: "session_review",
      urgency: 1,
      title: "Review stopped Codex session",
      reason: "stopped session",
      detail: "Codex session #{session.external_session_id}",
      app: session.app,
      session: session,
      link: "/sessions"
    }
  end

  defp release_focus_item(release_target) do
    %{
      type: "release_blocker",
      urgency: 2,
      title: "Resolve release blocker",
      reason: "release blocker",
      detail: "#{release_target.app.name}: #{release_target.version || release_target.label}",
      app: release_target.app,
      release_target: release_target,
      link: "/releases"
    }
  end

  defp invalid_repo_focus_item(app) do
    %{
      type: "invalid_repo",
      urgency: 3,
      title: "Fix repository path",
      reason: "invalid repository path",
      detail: "#{app.name}: #{app.repo_path}",
      app: app,
      link: "/apps/#{app.id}"
    }
  end

  defp repo_scan_focus_item(scan) do
    %{
      type: "repo_scan_attention",
      urgency: 3,
      title: "Review repository state",
      reason: "repository #{scan.status}",
      detail:
        "#{scan.name || scan.repository_path}: #{scan.changed_count} changed, #{scan.untracked_count} untracked",
      app: scan.app,
      repo_scan: scan,
      link: (scan.app && "/apps/#{scan.app.id}") || "/settings"
    }
  end

  defp maintenance_focus_item(obligation) do
    %{
      type: "maintenance_due",
      urgency: 4,
      title: "Handle maintenance obligation",
      reason: "maintenance due",
      detail: "#{obligation.app.name}: #{obligation.title}",
      app: obligation.app,
      maintenance_obligation: obligation,
      link: "/apps/#{obligation.app_id}"
    }
  end

  defp experiment_focus_item(experiment) do
    %{
      type: "growth_review",
      urgency: 4,
      title: "Review growth experiment",
      reason: "growth review",
      detail: "#{experiment.app.name}: #{experiment.title}",
      app: experiment.app,
      growth_experiment: experiment,
      link: "/apps/#{experiment.app_id}"
    }
  end

  defp missing_next_action_focus_item(app) do
    %{
      type: "missing_next_action",
      urgency: 4,
      title: "Define next action",
      reason: "stale next action",
      detail: "#{app.name}: No next action",
      app: app,
      link: "/apps/#{app.id}"
    }
  end

  defp stale_metrics_focus_item(app) do
    %{
      type: "stale_metrics",
      urgency: 5,
      title: "Refresh business snapshot",
      reason: "business posture needs attention",
      detail: "#{app.name}: #{app.business_posture}",
      app: app,
      link: "/apps/#{app.id}"
    }
  end

  defp unlinked_session_focus_item(session) do
    %{
      type: "unlinked_session",
      urgency: 6,
      title: "Link Codex session",
      reason: "unlinked session",
      detail: "Codex session #{session.external_session_id}",
      app: nil,
      session: session,
      link: "/sessions"
    }
  end
end
