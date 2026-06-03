# @input  - Portfolio, session, release, and metrics query outputs
# @output - Today command-center queues with explicit reasons
# @pos    - Read-model context for deciding what needs attention now
defmodule Afp.Factory.Dashboard do
  alias Afp.Factory.Metrics
  alias Afp.Factory.Portfolio
  alias Afp.Factory.Releases
  alias Afp.Factory.Sessions
  alias Afp.Factory.Work

  def today do
    review_sessions = Sessions.list_stopped_review_sessions()
    unlinked_sessions = Sessions.list_unlinked_sessions()
    release_blockers = Releases.list_blocking_targets()
    apps_without_next_action = Portfolio.apps_without_next_action()
    apps_with_invalid_repo = Portfolio.apps_with_invalid_repo()
    stale_metrics_apps = Metrics.apps_with_stale_metrics()
    active_apps = Portfolio.list_active_apps()

    %{
      focus_queue:
        focus_queue(%{
          review_sessions: review_sessions,
          release_blockers: release_blockers,
          apps_without_next_action: apps_without_next_action,
          apps_with_invalid_repo: apps_with_invalid_repo,
          stale_metrics_apps: stale_metrics_apps,
          unlinked_sessions: unlinked_sessions
        }),
      review_sessions: review_sessions,
      unlinked_sessions: unlinked_sessions,
      release_blockers: release_blockers,
      apps_without_next_action: apps_without_next_action,
      apps_with_invalid_repo: apps_with_invalid_repo,
      stale_metrics_apps: stale_metrics_apps,
      active_apps: active_apps
    }
  end

  def focus_queue(data) do
    data.review_sessions
    |> Enum.map(&session_focus_item/1)
    |> Kernel.++(Enum.map(data.release_blockers, &release_focus_item/1))
    |> Kernel.++(Enum.map(data.apps_with_invalid_repo, &invalid_repo_focus_item/1))
    |> Kernel.++(Enum.map(data.apps_without_next_action, &missing_next_action_focus_item/1))
    |> Kernel.++(Enum.map(data.stale_metrics_apps, &stale_metrics_focus_item/1))
    |> Kernel.++(Enum.map(data.unlinked_sessions, &unlinked_session_focus_item/1))
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
      app: app,
      link: "/apps/#{app.id}"
    }
  end

  defp missing_next_action_focus_item(app) do
    %{
      type: "missing_next_action",
      urgency: 4,
      title: "Define next action",
      reason: "stale next action",
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
      app: nil,
      session: session,
      link: "/sessions"
    }
  end
end
