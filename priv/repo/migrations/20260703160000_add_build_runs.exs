defmodule Afp.Repo.Migrations.AddBuildRuns do
  use Ecto.Migration

  def change do
    create table(:build_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :status, :text, null: false, default: "queued"
      add :agent, :text, null: false, default: "claude_code"
      add :model, :text
      add :repository_path, :text, null: false
      add :prompt, :text
      add :final_answer, :text
      add :error, :text
      add :agent_payload, :jsonb, null: false, default: fragment("'{}'::jsonb")
      add :verify_result, :jsonb, null: false, default: fragment("'{}'::jsonb")
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      add :app_id, references(:apps, type: :binary_id, on_delete: :delete_all), null: false

      add :harness_packet_id,
          references(:harness_packets, type: :binary_id, on_delete: :delete_all),
          null: false

      add :ticket_id, references(:tickets, type: :binary_id, on_delete: :nilify_all)

      add :evidence_packet_id,
          references(:evidence_packets, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:build_runs, [:app_id])
    create index(:build_runs, [:harness_packet_id])
    create index(:build_runs, [:status])
  end
end
