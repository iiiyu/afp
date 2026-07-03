# @input  - Streamed run-activity payloads and monotonic timestamps
# @output - A bounded, id-stamped activity feed and refresh-throttle verdicts
# @pos    - Read-model policy for live agent activity (timing lives here, not in views)
defmodule Afp.Factory.Opportunities.ActivityFeed do
  @moduledoc """
  Live activity arrives much faster than the persisted read model changes.
  This module owns both policies the view needs: the bounded feed (newest
  first, capped) and the reload throttle (at most one read-model refresh per
  interval). Timestamps are injected so the policy is a pure function.
  """

  @limit 30
  @refresh_interval_ms 2_000

  @doc "Prepends an activity entry (stamped with a monotonic id), capped at #{@limit}."
  def append(feed, activity) when is_list(feed) and is_map(activity) do
    entry = Map.put(activity, "id", System.unique_integer([:positive, :monotonic]))
    Enum.take([entry | feed], @limit)
  end

  @doc "True when enough time has passed since `last_refresh_ms` to reload the read model."
  def refresh_due?(last_refresh_ms, now_ms) do
    now_ms - (last_refresh_ms || 0) >= @refresh_interval_ms
  end
end
