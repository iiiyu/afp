# @input  - Oban job args for scheduled demand source scans
# @output - Draft scheduled-scan launch requests for due healthy demand sources
# @pos    - Retryable worker for the demand repo scheduled research control loop
defmodule Afp.Factory.Demand.ScheduleResearchWorker do
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Afp.Factory.Demand

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    force? = Map.get(args, "force", false)

    {:ok, _summary} = Demand.run_scheduled_research(force: force?)
    :ok
  end
end
