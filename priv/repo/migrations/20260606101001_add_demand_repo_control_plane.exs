defmodule Afp.Repo.Migrations.AddDemandRepoControlPlane do
  use Ecto.Migration

  def change do
    create table(:demand_source_repos, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :repo_path, :text, null: false
      add :display_name, :text, null: false
      add :kind, :text, null: false, default: "product_demand_repo"
      add :description, :text
      add :manifest_path, :text, null: false, default: "afp-demand-source.json"
      add :manifest_schema_version, :integer
      add :lanes, {:array, :text}, null: false, default: []
      add :agent_entrypoint, :text, null: false, default: "AGENTS.md"
      add :agent_required, :boolean, null: false, default: true
      add :skill_policy, :text
      add :required_skills, {:array, :text}, null: false, default: []
      add :optional_skills, {:array, :text}, null: false, default: []
      add :read_order, {:array, :text}, null: false, default: []
      add :write_targets, :jsonb, null: false, default: fragment("'{}'::jsonb")
      add :sqlite_path, :text
      add :sqlite_mode, :text
      add :sqlite_owner, :text
      add :sqlite_schema_path, :text
      add :sqlite_migrations_path, :text
      add :sqlite_allowed_operations, {:array, :text}, null: false, default: []
      add :schedule_enabled, :boolean, null: false, default: false
      add :schedule_interval_hours, :integer, null: false, default: 12
      add :health_state, :text, null: false, default: "unknown"
      add :health_summary, :text
      add :missing_paths, {:array, :text}, null: false, default: []
      add :parse_errors, {:array, :text}, null: false, default: []
      add :latest_scan_at, :utc_datetime_usec
      add :latest_index_at, :utc_datetime_usec
      add :last_run_at, :utc_datetime_usec
      add :payload, :jsonb, null: false, default: fragment("'{}'::jsonb")

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:demand_source_repos, [:repo_path])
    create index(:demand_source_repos, [:health_state])
    create index(:demand_source_repos, [:schedule_enabled])

    create table(:demand_candidates, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :demand_source_repo_id,
          references(:demand_source_repos, type: :binary_id, on_delete: :delete_all),
          null: false

      add :demand_item_id, references(:demand_items, type: :binary_id, on_delete: :nilify_all)
      add :lane, :text, null: false
      add :external_id, :text, null: false
      add :title, :text, null: false
      add :source_status, :text, null: false, default: "new"
      add :afp_status, :text, null: false, default: "not_picked_up"
      add :score, :integer
      add :confidence, :text, null: false, default: "unknown"
      add :target_user, :text
      add :demand_signal, :text
      add :incumbent_weakness, :text
      add :wedge_hypothesis, :text
      add :validation_action, :text
      add :primary_path, :text
      add :report_path, :text
      add :package_path, :text
      add :evidence_paths, {:array, :text}, null: false, default: []
      add :observed_at, :date
      add :limitations, :text
      add :review_note, :text
      add :picked_up_at, :utc_datetime_usec
      add :approved_for_package_at, :utc_datetime_usec
      add :handed_off_at, :utc_datetime_usec
      add :rejected_at, :utc_datetime_usec
      add :parked_at, :utc_datetime_usec
      add :payload, :jsonb, null: false, default: fragment("'{}'::jsonb")

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:demand_candidates, [:demand_source_repo_id, :lane, :external_id])
    create index(:demand_candidates, [:demand_source_repo_id])
    create index(:demand_candidates, [:demand_item_id])
    create index(:demand_candidates, [:lane])
    create index(:demand_candidates, [:source_status])
    create index(:demand_candidates, [:afp_status])
    create index(:demand_candidates, [:observed_at])

    create table(:demand_message_templates, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :purpose, :text
      add :default_run_type, :text, null: false, default: "manual_idea"
      add :default_lane, :text, null: false, default: "app"
      add :default_target, :text, null: false, default: "manual_handoff"
      add :required_variables, {:array, :text}, null: false, default: []
      add :body, :text, null: false
      add :safety_notes, :text
      add :expected_output_paths, {:array, :text}, null: false, default: []
      add :requires_confirmation, :boolean, null: false, default: true
      add :active, :boolean, null: false, default: true
      add :payload, :jsonb, null: false, default: fragment("'{}'::jsonb")

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:demand_message_templates, [:name])
    create index(:demand_message_templates, [:default_run_type])
    create index(:demand_message_templates, [:active])

    create table(:demand_research_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :demand_source_repo_id,
          references(:demand_source_repos, type: :binary_id, on_delete: :nilify_all)

      add :demand_candidate_id,
          references(:demand_candidates, type: :binary_id, on_delete: :nilify_all)

      add :message_template_id,
          references(:demand_message_templates, type: :binary_id, on_delete: :nilify_all)

      add :codex_launch_request_id,
          references(:codex_launch_requests, type: :binary_id, on_delete: :nilify_all)

      add :codex_session_id, references(:codex_sessions, type: :binary_id, on_delete: :nilify_all)
      add :run_type, :text, null: false
      add :lane, :text
      add :input_text, :text
      add :input_url, :text
      add :objective, :text, null: false
      add :rendered_message, :text
      add :output_paths, {:array, :text}, null: false, default: []
      add :status, :text, null: false, default: "draft"
      add :error, :text
      add :limitations, :text
      add :review_note, :text
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :payload, :jsonb, null: false, default: fragment("'{}'::jsonb")

      timestamps(type: :utc_datetime_usec)
    end

    create index(:demand_research_runs, [:demand_source_repo_id])
    create index(:demand_research_runs, [:demand_candidate_id])
    create index(:demand_research_runs, [:message_template_id])
    create index(:demand_research_runs, [:codex_launch_request_id])
    create index(:demand_research_runs, [:status])
    create index(:demand_research_runs, [:run_type])
    create index(:demand_research_runs, [:updated_at])

    create table(:demand_sent_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :demand_research_run_id,
          references(:demand_research_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :message_template_id,
          references(:demand_message_templates, type: :binary_id, on_delete: :nilify_all)

      add :codex_launch_request_id,
          references(:codex_launch_requests, type: :binary_id, on_delete: :nilify_all)

      add :codex_session_id, references(:codex_sessions, type: :binary_id, on_delete: :nilify_all)
      add :target, :text, null: false, default: "manual_handoff"
      add :status, :text, null: false, default: "draft"
      add :rendered_body, :text, null: false
      add :edited_body, :text
      add :confirmed_at, :utc_datetime_usec
      add :sent_at, :utc_datetime_usec
      add :failed_at, :utc_datetime_usec
      add :payload, :jsonb, null: false, default: fragment("'{}'::jsonb")

      timestamps(type: :utc_datetime_usec)
    end

    create index(:demand_sent_messages, [:demand_research_run_id])
    create index(:demand_sent_messages, [:message_template_id])
    create index(:demand_sent_messages, [:codex_launch_request_id])
    create index(:demand_sent_messages, [:status])
  end
end
