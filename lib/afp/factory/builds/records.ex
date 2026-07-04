# @input  - Raw string-keyed afp/state.sqlite rows from Builds.Storage
# @output - Typed build read-model structs (Milestone, BuildRun)
# @pos    - The shape that crosses the Builds storage seam; column names stop here
defmodule Afp.Factory.Builds.Milestone do
  @moduledoc "Typed read model for a `build_milestones` row (agent-owned)."

  @columns ~w(id milestone_key milestone_index title status spec_ref summary
              artifact_path attempts created_at updated_at)

  defstruct [
    :id,
    :milestone_key,
    :milestone_index,
    :title,
    :status,
    :spec_ref,
    :summary,
    :artifact_path,
    :attempts,
    :created_at,
    :updated_at
  ]

  def columns, do: @columns
  def select_columns, do: Enum.join(@columns, ", ")

  def from_row(row) when is_map(row) do
    %__MODULE__{
      id: row["id"],
      milestone_key: row["milestone_key"],
      milestone_index: row["milestone_index"],
      title: row["title"],
      status: row["status"],
      spec_ref: row["spec_ref"],
      summary: row["summary"],
      artifact_path: row["artifact_path"],
      attempts: row["attempts"],
      created_at: row["created_at"],
      updated_at: row["updated_at"]
    }
  end

  def launchable?(%__MODULE__{status: status}), do: status in ~w(pending failed blocked)
end

defmodule Afp.Factory.Builds.BuildRun do
  @moduledoc """
  Typed read model for a `build_runs` row (AFP-owned). New table, honest
  column names — no legacy mapping needed. `verify_json` is decoded once
  into `verify` / `verify_pass`.
  """

  @columns ~w(id milestone_key task_text agent model status prompt agent_session_id
              agent_thread_id agent_turn_id transcript_path final_answer
              verify_json verify_pass reviewed_at error started_at completed_at
              created_at updated_at)

  defstruct [
    :id,
    :milestone_key,
    :task_text,
    :agent,
    :model,
    :status,
    :prompt,
    :agent_session_id,
    :agent_thread_id,
    :agent_turn_id,
    :transcript_path,
    :final_answer,
    :verify_pass,
    :reviewed_at,
    :error,
    :started_at,
    :completed_at,
    :created_at,
    :updated_at,
    verify: %{}
  ]

  def columns, do: @columns
  def select_columns, do: Enum.join(@columns, ", ")

  def from_row(row) when is_map(row) do
    %__MODULE__{
      id: row["id"],
      milestone_key: row["milestone_key"],
      task_text: row["task_text"],
      agent: row["agent"],
      model: row["model"],
      status: row["status"],
      prompt: row["prompt"],
      agent_session_id: row["agent_session_id"],
      agent_thread_id: row["agent_thread_id"],
      agent_turn_id: row["agent_turn_id"],
      transcript_path: row["transcript_path"],
      final_answer: row["final_answer"],
      verify: decode_verify(row["verify_json"]),
      verify_pass: decode_pass(row["verify_pass"]),
      reviewed_at: row["reviewed_at"],
      error: row["error"],
      started_at: row["started_at"],
      completed_at: row["completed_at"],
      created_at: row["created_at"],
      updated_at: row["updated_at"]
    }
  end

  def active?(%__MODULE__{status: status}), do: status in ~w(queued running verifying)
  def completed?(%__MODULE__{status: status}), do: status == "completed"

  def awaiting_review?(%__MODULE__{} = run),
    do: completed?(run) and is_nil(run.reviewed_at)

  def subject(%__MODULE__{milestone_key: key}) when is_binary(key) and key != "", do: key
  def subject(%__MODULE__{task_text: text}) when is_binary(text), do: text
  def subject(_run), do: "ad-hoc task"

  defp decode_verify(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, verify} when is_map(verify) -> verify
      _decoded -> %{}
    end
  end

  defp decode_verify(_json), do: %{}

  defp decode_pass(1), do: true
  defp decode_pass(0), do: false
  defp decode_pass(_value), do: nil
end
