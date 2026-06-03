defmodule Afp.Repo.Migrations.AddPhase2OperatingLoopTables do
  use Ecto.Migration

  def change do
    create table(:repo_scans, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :app_id, references(:apps, type: :binary_id, on_delete: :nilify_all)
      add :root_path, :text
      add :repository_path, :text, null: false
      add :name, :text
      add :status, :text, null: false, default: "unknown"
      add :branch, :text
      add :dirty, :boolean, null: false, default: false
      add :changed_count, :integer, null: false, default: 0
      add :untracked_count, :integer, null: false, default: 0
      add :latest_commit_sha, :text
      add :latest_commit_subject, :text
      add :latest_commit_at, :utc_datetime_usec
      add :platform_hints, {:array, :text}, null: false, default: []
      add :scan_reason, :text
      add :error, :text
      add :payload, :jsonb, null: false, default: fragment("'{}'::jsonb")
      add :scanned_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:repo_scans, [:app_id])
    create index(:repo_scans, [:root_path])
    create index(:repo_scans, [:status])
    create index(:repo_scans, [:scanned_at])
    create unique_index(:repo_scans, [:repository_path])

    create table(:growth_experiments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :app_id, references(:apps, type: :binary_id, on_delete: :delete_all), null: false
      add :title, :text, null: false
      add :hypothesis, :text
      add :metric, :text
      add :status, :text, null: false, default: "idea"
      add :priority, :text, null: false, default: "normal"
      add :started_at, :utc_datetime_usec
      add :review_due_on, :date
      add :ended_at, :utc_datetime_usec
      add :outcome_note, :text
      add :payload, :jsonb, null: false, default: fragment("'{}'::jsonb")

      timestamps(type: :utc_datetime_usec)
    end

    create index(:growth_experiments, [:app_id])
    create index(:growth_experiments, [:status])
    create index(:growth_experiments, [:review_due_on])

    create table(:maintenance_obligations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :app_id, references(:apps, type: :binary_id, on_delete: :delete_all), null: false
      add :title, :text, null: false
      add :category, :text, null: false, default: "maintenance"
      add :status, :text, null: false, default: "open"
      add :priority, :text, null: false, default: "normal"
      add :due_on, :date
      add :recurrence, :text
      add :notes, :text
      add :completed_at, :utc_datetime_usec
      add :payload, :jsonb, null: false, default: fragment("'{}'::jsonb")

      timestamps(type: :utc_datetime_usec)
    end

    create index(:maintenance_obligations, [:app_id])
    create index(:maintenance_obligations, [:status])
    create index(:maintenance_obligations, [:due_on])
  end
end
