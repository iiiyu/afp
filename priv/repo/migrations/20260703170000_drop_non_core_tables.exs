defmodule Afp.Repo.Migrations.DropNonCoreTables do
  use Ecto.Migration

  # Refactor to the Opportunities + Apps core: everything else is removed and
  # will be rebuilt outward from these two surfaces. Dropped in FK order.
  @tables ~w(
    build_runs
    ticket_session_links
    release_check_items
    evidence_links
    demand_sent_messages
    demand_research_runs
    codex_launch_requests
    demand_candidates
    demand_message_templates
    demand_items
    demand_source_repos
    harness_packets
    tickets
    codex_sessions
    hook_events
    evidence_packets
    release_targets
    metrics_snapshots
    repo_scans
    growth_experiments
    maintenance_obligations
  )

  def up do
    Enum.each(@tables, fn table ->
      execute("DROP TABLE IF EXISTS #{table} CASCADE")
    end)
  end

  def down do
    raise Ecto.MigrationError,
      message: "irreversible: dropped non-core tables; restore from git history migrations"
  end
end
