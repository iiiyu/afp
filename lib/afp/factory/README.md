<!-- If files in this folder change, update this document. -->

# Factory Contexts

## Architecture Summary

This folder contains the one-person app factory domain model. Contexts are
split by PRD boundary: opportunities, demand, portfolio, work, sessions,
evidence, releases, metrics, settings, events, and dashboard read models. State transitions stay in
contexts so LiveViews remain thin and older API/UI paths keep consistent
behavior.

## File Inventory

- `factory.ex` - Shared constants and normalization helpers.
- `factory/schema.ex` - UUID and timestamp schema defaults.
- `factory/json_data.ex` - Flexible jsonb Ecto type.
- `factory/repo_sqlite.ex` - Single seam for all external-repo `sqlite3` CLI access (query/execute/escape), with busy-timeout, JSON decode, and error normalization.
- `factory/agent_client.ex` - `@behaviour` for a launch transport (`launch_new_turn/2`); implemented by `demand/codex_app_client.ex`, `opportunities/claude_code_client.ex`, and the test fakes.
- `factory/events.ex` and `factory/events/event.ex` - Append-only audit log and PubSub broadcasts.
- `factory/opportunities.ex`, `factory/opportunities/repo_contract.ex`, `factory/opportunities/storage.ex`, `factory/opportunities/storage_schema.ex`, `factory/opportunities/files.ex`, `factory/opportunities/agent_run.ex`, and `factory/opportunities/README.md` - Portable opportunity repo setup, health inspection, repo-local `base.sqlite` storage, schema upgrades, the Markdown/image file browser, and sync/async agent-run launch orchestration with storage-backed run-state persistence.
- `factory/demand.ex` plus `factory/demand/source_repo.ex`, `factory/demand/source_repo_scaffold.ex`, `factory/demand/source_repo_adapter.ex`, `factory/demand/source_manifest.ex`, `factory/demand/codex_launch.ex`, `factory/demand/codex_launch_records.ex`, `factory/demand/codex_launch_context.ex`, `factory/demand/launch_workflow.ex`, `factory/demand/launch_text.ex`, `factory/demand/candidates.ex`, `factory/demand/items.ex`, `factory/demand/codex_app_client.ex`, `factory/demand/schedule_research_worker.ex`, `factory/demand/candidate.ex`, `factory/demand/research_run.ex`, `factory/demand/message_template.ex`, `factory/demand/sent_message.ex`, `factory/demand/demand_item.ex`, and `factory/demand/codex_launch_request.ex` - Demand source repository contracts, standard source repo scaffolding, manifest-gated repo-local SQLite candidate reads, supervised long-running Codex app-server JSON-RPC launches with manifest-bounded approval replies, stdout transport diagnostics, early thread/turn progress persistence, per-attempt stale-startup reconciliation, launch workflow creation, template/context rendering, scheduled due-scan draft handoffs, normalized candidate indexing and routing, research-run/message history, pre-app demand capture, validation launch requests, and promotion into apps.
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
