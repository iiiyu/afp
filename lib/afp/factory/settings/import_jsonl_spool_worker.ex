# @input  - Oban job args with optional JSONL spool path
# @output - Imported Codex hook events through the session intake context
# @pos    - Background worker for retryable local spool ingestion
defmodule Afp.Factory.Settings.ImportJsonlSpoolWorker do
  use Oban.Worker, queue: :intake, max_attempts: 3

  alias Afp.Factory.Settings

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    path = Map.get(args, "path")

    case Settings.import_jsonl_spool(path) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
