<!-- If files in this folder change, update this document. -->

# Factory Contexts

## Architecture Summary

This folder contains the one-person app factory domain model. Contexts are
split by PRD boundary: demand, portfolio, work, sessions, evidence, releases,
metrics, settings, events, and dashboard read models. State transitions stay in
contexts so LiveViews remain thin and older API/UI paths keep consistent
behavior.

## File Inventory

- `factory.ex` - Shared constants and normalization helpers.
- `factory/schema.ex` - UUID and timestamp schema defaults.
- `factory/json_data.ex` - Flexible jsonb Ecto type.
- `factory/events.ex` and `factory/events/event.ex` - Append-only audit log and PubSub broadcasts.
- `factory/demand.ex` plus `factory/demand/source_repo.ex`, `factory/demand/source_repo_scaffold.ex`, `factory/demand/source_repo_adapter.ex`, `factory/demand/codex_app_client.ex`, `factory/demand/schedule_research_worker.ex`, `factory/demand/candidate.ex`, `factory/demand/research_run.ex`, `factory/demand/message_template.ex`, `factory/demand/sent_message.ex`, `factory/demand/demand_item.ex`, and `factory/demand/codex_launch_request.ex` - Demand source repository contracts, standard source repo scaffolding, manifest-gated repo-local SQLite candidate reads, supervised long-running Codex app-server JSON-RPC launches with manifest-bounded approval replies, stdout decision logging, early thread/turn progress persistence, stale-startup reconciliation, scheduled due-scan draft handoffs, normalized candidate indexing, research-run/message history, pre-app demand capture, validation launch requests, and promotion into apps.
- `factory/portfolio.ex` and `factory/portfolio/app.ex` - App inventory, lifecycle, business posture, and repo matching.
- `factory/work.ex`, `factory/work/ticket.ex`, and `factory/work/harness_packet.ex` - Ticket workflow and harness packet contracts.
- `factory/sessions.ex`, `factory/sessions/codex_session.ex`, `factory/sessions/hook_event.ex`, and `factory/sessions/ticket_session_link.ex` - Codex hook intake, session linking, ignore, and review.
- `factory/evidence.ex`, `factory/evidence/evidence_packet.ex`, and `factory/evidence/evidence_link.ex` - Evidence store and multi-object links.
- `factory/releases.ex`, `factory/releases/release_target.ex`, and `factory/releases/release_check_item.ex` - Release targets, checklist gates, and release transitions.
- `factory/metrics.ex` and `factory/metrics/metrics_snapshot.ex` - Manual business metrics snapshots and stale-live-app flags.
- `factory/settings.ex`, `factory/settings/setting.ex`, and `factory/settings/import_jsonl_spool_worker.ex` - Repository roots, Codex intake settings, JSONL spool import, and Oban worker.
- `factory/dashboard.ex` - Today command-center read model.
- `factory/repositories.ex` and `factory/repositories/repo_scan.ex` - Local repository scanning, app matching, git status, and health signals.
- `factory/growth.ex` and `factory/growth/growth_experiment.ex` - Post-launch growth experiment tracking and review queues.
- `factory/maintenance.ex` and `factory/maintenance/maintenance_obligation.ex` - Maintenance obligation tracking and due queues.
