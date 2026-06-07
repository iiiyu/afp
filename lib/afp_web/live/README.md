<!-- If files in this folder change, update this document. -->

# Live Views

## Architecture Summary

This folder contains Phoenix LiveViews for the local-first one-person app factory
control plane. Screens stay thin: they render compact operational UI, call
`Afp.Factory.*` contexts for domain rules, and reload their read model when the
factory event log broadcasts updates.

Each page follows the same information hierarchy: a persistent global sidebar
on desktop, a page header, a primary reading surface, collapsible secondary
context, and a separate action rail for forms that mutate state.

## File Inventory

- `today_live.ex` - Today command center with focus queues and quick ticket creation.
- `demand_live.ex` - Standard demand source repo creation, source repo health, editable source schedules, scheduled due-scan drafts, legacy source detection, source-level manual idea/URL handoffs, indexed candidate queues, package verification, research runs, message templates, manual Codex launch handoffs, existing-session follow-ups, legacy demand items, and promotion into apps.
- `app_live/index.ex` - App portfolio table, filters, and app creation.
- `app_live/show.ex` - App detail cockpit with lifecycle, tickets, sessions, releases, evidence, and metrics entry points.
- `board_live.ex` - Draggable ticket board and harness packet builder.
- `sessions_live.ex` - Codex session inbox, linking, ignore, and review workflows.
- `releases_live.ex` - Release targets, checklist gates, transitions, and checklist evidence.
- `evidence_live.ex` - Evidence packet creation, listing, and optional subject linking.
- `metrics_live.ex` - Manual metrics snapshots and stale live-app business flags.
- `settings_live.ex` - Repository roots, Codex intake, privacy, and JSONL import controls.
