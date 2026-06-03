# @input  - Oban job args and configured repository roots
# @output - Background repository root scan execution
# @pos    - Retryable worker for local repository health checks
defmodule Afp.Factory.Repositories.ScanRepositoryRootsWorker do
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Afp.Factory.Repositories
  alias Afp.Factory.Settings

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    reason = Map.get(args, "reason", "oban_root_scan")

    {:ok, _result} =
      Repositories.scan_repository_roots(Settings.repository_roots(), reason: reason)

    :ok
  end
end
