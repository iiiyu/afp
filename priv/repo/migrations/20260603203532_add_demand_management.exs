defmodule Afp.Repo.Migrations.AddDemandManagement do
  use Ecto.Migration

  def change do
    create table(:demand_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :text, null: false
      add :status, :text, null: false, default: "captured"
      add :source, :text
      add :source_url, :text
      add :target_user, :text
      add :job_to_be_done, :text
      add :demand_signal, :text
      add :incumbent_weakness, :text
      add :wedge_hypothesis, :text
      add :validation_action, :text, null: false
      add :evidence_summary, :text
      add :confidence, :text, null: false, default: "unknown"
      add :promoted_app_id, references(:apps, type: :binary_id, on_delete: :nilify_all)
      add :promoted_at, :utc_datetime_usec
      add :rejected_reason, :text
      add :parked_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:demand_items, [:status])
    create index(:demand_items, [:confidence])
    create index(:demand_items, [:promoted_app_id])
    create index(:demand_items, [:inserted_at])

    create table(:codex_launch_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :demand_item_id, references(:demand_items, type: :binary_id, on_delete: :nilify_all)
      add :app_id, references(:apps, type: :binary_id, on_delete: :nilify_all)
      add :ticket_id, references(:tickets, type: :binary_id, on_delete: :nilify_all)

      add :release_target_id,
          references(:release_targets, type: :binary_id, on_delete: :nilify_all)

      add :source_type, :text, null: false
      add :source_id, :binary_id
      add :title, :text, null: false
      add :objective, :text, null: false
      add :context, :text
      add :risk_level, :text, null: false, default: "normal"
      add :launch_mode, :text, null: false, default: "manual_handoff"
      add :status, :text, null: false, default: "draft"
      add :confirmation, :text
      add :handoff_text, :text
      add :launched_at, :utc_datetime_usec
      add :cancelled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:codex_launch_requests, [:demand_item_id])
    create index(:codex_launch_requests, [:app_id])
    create index(:codex_launch_requests, [:ticket_id])
    create index(:codex_launch_requests, [:status])
    create index(:codex_launch_requests, [:source_type, :source_id])
  end
end
