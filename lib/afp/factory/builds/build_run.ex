# @input  - Harness packet launches and agent/verify completion payloads
# @output - Build run records tracking agent execution against app repos
# @pos    - Persistence schema for the BuildRunner execution loop
defmodule Afp.Factory.Builds.BuildRun do
  use Afp.Factory.Schema

  alias Afp.Factory
  alias Afp.Factory.JsonData

  schema "build_runs" do
    field :status, :string, default: "queued"
    field :agent, :string, default: "claude_code"
    field :model, :string
    field :repository_path, :string
    field :prompt, :string
    field :final_answer, :string
    field :error, :string
    field :agent_payload, JsonData, default: %{}
    field :verify_result, JsonData, default: %{}
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :app, Afp.Factory.Portfolio.App
    belongs_to :harness_packet, Afp.Factory.Work.HarnessPacket
    belongs_to :ticket, Afp.Factory.Work.Ticket
    belongs_to :evidence_packet, Afp.Factory.Evidence.EvidencePacket

    timestamps()
  end

  def changeset(build_run, attrs) do
    build_run
    |> cast(attrs, [
      :status,
      :agent,
      :model,
      :repository_path,
      :prompt,
      :final_answer,
      :error,
      :agent_payload,
      :verify_result,
      :started_at,
      :finished_at,
      :app_id,
      :harness_packet_id,
      :ticket_id,
      :evidence_packet_id
    ])
    |> validate_required([:status, :agent, :repository_path, :app_id, :harness_packet_id])
    |> validate_inclusion(:status, Factory.build_run_statuses())
  end
end
