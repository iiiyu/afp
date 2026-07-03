# @input  - Raw string-keyed base.sqlite rows from Storage queries
# @output - Typed opportunity read-model structs with resolved fields
# @pos    - The shape that crosses the Storage seam; SQL column names stop here
defmodule Afp.Factory.Opportunities.Opportunity do
  @moduledoc """
  Typed read model for an `opportunities` row. Physical column names (including
  the legacy `codex_session_id`) are mapped to neutral fields here and nowhere
  else — external repos keep their schema, callers never see column names.
  """

  @columns ~w(id title raw_input source_url agent status stage route total_score
              current_run_id codex_session_id latest_summary error created_at updated_at)

  defstruct [
    :id,
    :title,
    :raw_input,
    :source_url,
    :agent,
    :status,
    :stage,
    :route,
    :total_score,
    :current_run_id,
    :agent_session_id,
    :latest_summary,
    :error,
    :created_at,
    :updated_at
  ]

  def columns, do: @columns
  def select_columns, do: Enum.join(@columns, ", ")

  def from_row(row) when is_map(row) do
    %__MODULE__{
      id: row["id"],
      title: row["title"],
      raw_input: row["raw_input"],
      source_url: row["source_url"],
      agent: row["agent"],
      status: row["status"],
      stage: row["stage"],
      route: row["route"],
      total_score: row["total_score"],
      current_run_id: row["current_run_id"],
      agent_session_id: row["codex_session_id"],
      latest_summary: row["latest_summary"],
      error: row["error"],
      created_at: row["created_at"],
      updated_at: row["updated_at"]
    }
  end

  def running?(%__MODULE__{status: status}), do: status == "running"
  def researched?(%__MODULE__{status: status}), do: status == "researched"
  def failed?(%__MODULE__{status: status}), do: status == "failed"
end

defmodule Afp.Factory.Opportunities.Run do
  @moduledoc """
  Typed read model for an `opportunity_runs` row. `payload_json` is decoded
  once here (`payload`, `model`); the legacy `codex_*` columns surface as
  neutral `agent_*` fields.
  """

  @columns ~w(id opportunity_id run_type agent status stage prompt codex_session_id
              codex_thread_id codex_turn_id transcript_path final_answer error
              started_at completed_at created_at updated_at payload_json)

  defstruct [
    :id,
    :opportunity_id,
    :run_type,
    :agent,
    :model,
    :status,
    :stage,
    :prompt,
    :agent_session_id,
    :agent_thread_id,
    :agent_turn_id,
    :transcript_path,
    :final_answer,
    :error,
    :started_at,
    :completed_at,
    :created_at,
    :updated_at,
    payload: %{}
  ]

  def columns, do: @columns
  def select_columns, do: Enum.join(@columns, ", ")

  def from_row(row) when is_map(row) do
    payload = decode_payload(row["payload_json"])

    %__MODULE__{
      id: row["id"],
      opportunity_id: row["opportunity_id"],
      run_type: row["run_type"],
      agent: row["agent"],
      model: payload_model(payload),
      status: row["status"],
      stage: row["stage"],
      prompt: row["prompt"],
      agent_session_id: row["codex_session_id"],
      agent_thread_id: row["codex_thread_id"],
      agent_turn_id: row["codex_turn_id"],
      transcript_path: row["transcript_path"],
      final_answer: row["final_answer"],
      error: row["error"],
      started_at: row["started_at"],
      completed_at: row["completed_at"],
      created_at: row["created_at"],
      updated_at: row["updated_at"],
      payload: payload
    }
  end

  def running?(%__MODULE__{status: status}), do: status == "running"

  defp decode_payload(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, payload} when is_map(payload) -> payload
      _decoded -> %{}
    end
  end

  defp decode_payload(_json), do: %{}

  defp payload_model(%{"model" => model}) when is_binary(model) and model != "", do: model
  defp payload_model(_payload), do: nil
end

defmodule Afp.Factory.Opportunities.StepResult do
  @moduledoc "Typed read model for an `opportunity_step_results` row."

  @columns ~w(id opportunity_id run_id step_key step_index status score
              evidence_strength summary artifact_path created_at updated_at)

  defstruct [
    :id,
    :opportunity_id,
    :run_id,
    :step_key,
    :step_index,
    :status,
    :score,
    :evidence_strength,
    :summary,
    :artifact_path,
    :created_at,
    :updated_at
  ]

  def columns, do: @columns
  def select_columns, do: Enum.join(@columns, ", ")

  def from_row(row) when is_map(row) do
    %__MODULE__{
      id: row["id"],
      opportunity_id: row["opportunity_id"],
      run_id: row["run_id"],
      step_key: row["step_key"],
      step_index: row["step_index"],
      status: row["status"],
      score: row["score"],
      evidence_strength: row["evidence_strength"],
      summary: row["summary"],
      artifact_path: row["artifact_path"],
      created_at: row["created_at"],
      updated_at: row["updated_at"]
    }
  end
end

defmodule Afp.Factory.Opportunities.StepEvidence do
  @moduledoc "Typed read model for an `opportunity_step_evidence` row."

  @columns ~w(id opportunity_id run_id step_key title kind file_path
              why_it_matters source_url created_at updated_at)

  defstruct [
    :id,
    :opportunity_id,
    :run_id,
    :step_key,
    :title,
    :kind,
    :file_path,
    :why_it_matters,
    :source_url,
    :created_at,
    :updated_at
  ]

  def columns, do: @columns
  def select_columns, do: Enum.join(@columns, ", ")

  def from_row(row) when is_map(row) do
    %__MODULE__{
      id: row["id"],
      opportunity_id: row["opportunity_id"],
      run_id: row["run_id"],
      step_key: row["step_key"],
      title: row["title"],
      kind: row["kind"],
      file_path: row["file_path"],
      why_it_matters: row["why_it_matters"],
      source_url: row["source_url"],
      created_at: row["created_at"],
      updated_at: row["updated_at"]
    }
  end
end
