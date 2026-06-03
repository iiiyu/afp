# App Factory Control Plane

Phoenix LiveView MVP for a local-first one-person app factory control plane. It
tracks app lifecycle state, next actions, tickets, harness packets, Codex
sessions, release readiness, evidence, metrics snapshots, and local Codex hook
intake.

## Running Locally

1. Run `mix setup` to install dependencies, create/migrate the PostgreSQL database, and build assets.
2. Start Phoenix with `mix phx.server` or `iex -S mix phx.server`.
3. Open [`localhost:4000`](http://localhost:4000). The app loads the Today command center.

## Main Surfaces

- Today - Focus queue, review queue, unlinked sessions, release blockers, stale apps, and quick ticket creation.
- Apps - Portfolio table, filters, app creation, and app detail cockpit.
- Board - Ticket columns and harness packet builder.
- Sessions - Codex hook/session inbox, linking, ignore, and manual review.
- Releases - Release targets, checklist gates, evidence attachment, and manual release transitions.
- Evidence - Manual evidence capture and multi-object linking.
- Metrics - Manual business snapshots and stale-live-app flags.
- Settings - Repository roots, Codex intake settings, privacy defaults, and JSONL spool import.

## Codex Hook Intake

The local HTTP receiver is:

```text
POST http://127.0.0.1:4000/api/codex/hooks
```

It stores raw hook payloads before processing and updates/creates Codex session
rows by `session_id`. JSONL spool import is configured in Settings and uses
stored byte offsets to avoid duplicate imports.

Run `mix precommit` before committing changes.
