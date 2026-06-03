defmodule Afp.Repo.Migrations.CreateFactoryControlPlaneTables do
  use Ecto.Migration

  def up do
    create table(:apps, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :slug, :text, null: false
      add :repo_path, :text
      add :platforms, {:array, :text}, null: false, default: []
      add :lifecycle_stage, :text, null: false
      add :business_posture, :text, null: false, default: "unknown"
      add :health_state, :text, null: false, default: "unknown"
      add :product_thesis, :jsonb, null: false, default: fragment("'{}'::jsonb")
      add :next_action, :text
      add :current_version, :text
      add :current_build, :text
      add :last_activity_at, :utc_datetime_usec
      add :paused_reason, :text
      add :archived_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:apps, [:slug])
    create unique_index(:apps, [:repo_path], where: "repo_path IS NOT NULL AND repo_path <> ''")
    create index(:apps, [:lifecycle_stage])
    create index(:apps, [:business_posture])
    create index(:apps, [:last_activity_at])

    create table(:tickets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :app_id, references(:apps, type: :binary_id, on_delete: :delete_all), null: false
      add :title, :text, null: false
      add :description, :text
      add :status, :text, null: false, default: "backlog"
      add :lifecycle_gate, :text
      add :priority, :text, null: false, default: "normal"
      add :risk_level, :text, null: false, default: "normal"
      add :blocked_reason, :text
      add :review_note, :text
      add :done_at, :utc_datetime_usec
      add :dropped_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tickets, [:app_id])
    create index(:tickets, [:status])
    create index(:tickets, [:lifecycle_gate])

    create table(:release_targets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :app_id, references(:apps, type: :binary_id, on_delete: :delete_all), null: false
      add :platform, :text, null: false
      add :label, :text
      add :version, :text
      add :build, :text
      add :status, :text, null: false, default: "draft"
      add :submitted_at, :utc_datetime_usec
      add :released_at, :utc_datetime_usec
      add :decision_note, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:release_targets, [:app_id])
    create index(:release_targets, [:status])
    create index(:release_targets, [:platform])

    create table(:harness_packets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :app_id, references(:apps, type: :binary_id, on_delete: :delete_all), null: false
      add :ticket_id, references(:tickets, type: :binary_id, on_delete: :nilify_all)

      add :release_target_id,
          references(:release_targets, type: :binary_id, on_delete: :nilify_all)

      add :state, :text, null: false, default: "draft"
      add :objective, :text, null: false
      add :repository_path, :text
      add :lifecycle_gate, :text
      add :context_inputs, :jsonb, null: false, default: fragment("'{}'::jsonb")
      add :constraints, :jsonb, null: false, default: fragment("'{}'::jsonb")
      add :non_goals, :jsonb, null: false, default: fragment("'[]'::jsonb")
      add :allowed_tools, :jsonb, null: false, default: fragment("'[]'::jsonb")
      add :risk_level, :text, null: false, default: "normal"
      add :expected_output, :text
      add :verification_plan, :jsonb, null: false, default: fragment("'{}'::jsonb")
      add :required_evidence, :jsonb, null: false, default: fragment("'[]'::jsonb")
      add :approval_points, :jsonb, null: false, default: fragment("'[]'::jsonb")
      add :launch_mode, :text, null: false, default: "manual"
      add :review_route, :text
      add :result_summary, :text
      add :next_route, :text
      add :superseded_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:harness_packets, [:app_id])
    create index(:harness_packets, [:ticket_id])
    create index(:harness_packets, [:state])
    create index(:harness_packets, [:risk_level])

    create table(:codex_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :external_session_id, :text, null: false
      add :app_id, references(:apps, type: :binary_id, on_delete: :nilify_all)
      add :cwd, :text
      add :model, :text
      add :status, :text, null: false, default: "detected"
      add :transcript_path, :text
      add :latest_turn_id, :text
      add :summary, :text
      add :first_seen_at, :utc_datetime_usec
      add :last_seen_at, :utc_datetime_usec
      add :stopped_at, :utc_datetime_usec
      add :reviewed_at, :utc_datetime_usec
      add :ignored_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:codex_sessions, [:external_session_id])
    create index(:codex_sessions, [:app_id])
    create index(:codex_sessions, [:cwd])
    create index(:codex_sessions, [:status])

    create table(:ticket_session_links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :ticket_id, references(:tickets, type: :binary_id, on_delete: :delete_all), null: false

      add :codex_session_id,
          references(:codex_sessions, type: :binary_id, on_delete: :delete_all), null: false

      add :link_reason, :text

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:ticket_session_links, [:ticket_id, :codex_session_id])
    create index(:ticket_session_links, [:codex_session_id])

    create table(:evidence_packets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :app_id, references(:apps, type: :binary_id, on_delete: :delete_all), null: false
      add :type, :text, null: false
      add :title, :text, null: false
      add :summary, :text, null: false
      add :source_path, :text
      add :source_url, :text
      add :reliability, :text, null: false, default: "unknown"
      add :payload, :jsonb, null: false, default: fragment("'{}'::jsonb")

      timestamps(type: :utc_datetime_usec)
    end

    create index(:evidence_packets, [:app_id])
    create index(:evidence_packets, [:type])
    create index(:evidence_packets, [:inserted_at])

    create table(:evidence_links, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :evidence_packet_id,
          references(:evidence_packets, type: :binary_id, on_delete: :delete_all), null: false

      add :subject_type, :text, null: false
      add :subject_id, :binary_id, null: false
      add :link_reason, :text

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create index(:evidence_links, [:evidence_packet_id])
    create index(:evidence_links, [:subject_type, :subject_id])

    create table(:release_check_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :release_target_id,
          references(:release_targets, type: :binary_id, on_delete: :delete_all), null: false

      add :category, :text, null: false
      add :title, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :required, :boolean, null: false, default: true
      add :waiver_reason, :text
      add :decision_note, :text
      add :position, :integer, null: false, default: 0
      add :updated_by, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:release_check_items, [:release_target_id])
    create index(:release_check_items, [:status])
    create index(:release_check_items, [:category])

    create table(:metrics_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :app_id, references(:apps, type: :binary_id, on_delete: :delete_all), null: false
      add :snapshot_date, :date, null: false
      add :downloads, :integer
      add :impressions, :integer
      add :product_page_views, :integer
      add :conversion_rate, :numeric
      add :revenue, :numeric
      add :trials, :integer
      add :subscriptions, :integer
      add :refunds, :integer
      add :rating, :numeric
      add :reviews_count, :integer
      add :crashes, :integer
      add :support_issues, :integer
      add :notes, :text
      add :payload, :jsonb, null: false, default: fragment("'{}'::jsonb")

      timestamps(type: :utc_datetime_usec)
    end

    create index(:metrics_snapshots, [:app_id])
    create index(:metrics_snapshots, [:snapshot_date])

    create table(:hook_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :external_session_id, :text
      add :event_name, :text, null: false
      add :cwd, :text
      add :model, :text
      add :transcript_path, :text
      add :turn_id, :text
      add :payload, :jsonb, null: false, default: fragment("'{}'::jsonb")
      add :received_at, :utc_datetime_usec, null: false
      add :processed_at, :utc_datetime_usec
      add :processing_error, :text
    end

    create index(:hook_events, [:external_session_id])
    create index(:hook_events, [:received_at])
    create index(:hook_events, [:processed_at])

    create table(:events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :subject_type, :text, null: false
      add :subject_id, :binary_id
      add :event_type, :text, null: false
      add :payload, :jsonb, null: false, default: fragment("'{}'::jsonb")

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create index(:events, [:subject_type, :subject_id])
    create index(:events, [:event_type])
    create index(:events, [:inserted_at])

    create table(:settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key, :text, null: false
      add :value, :jsonb, null: false, default: fragment("'{}'::jsonb")

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:settings, [:key])

    Oban.Migrations.up()
  end

  def down do
    Oban.Migrations.down()

    drop table(:settings)
    drop table(:events)
    drop table(:hook_events)
    drop table(:metrics_snapshots)
    drop table(:release_check_items)
    drop table(:evidence_links)
    drop table(:evidence_packets)
    drop table(:ticket_session_links)
    drop table(:codex_sessions)
    drop table(:harness_packets)
    drop table(:release_targets)
    drop table(:tickets)
    drop table(:apps)
  end
end
