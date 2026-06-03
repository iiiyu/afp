<!-- If files in this folder change, update this document. -->

# Live Views

## Architecture Summary

This folder contains Phoenix LiveViews for the local-first one-person app factory
control plane. Screens stay thin: they render compact operational UI, call
`Afp.Factory.*` contexts for domain rules, and reload their read model when the
factory event log broadcasts updates.

## File Inventory

- `today_live.ex` - Today command center with focus queues and quick ticket creation.
- `app_live/index.ex` - App portfolio table, filters, and app creation.
- `app_live/show.ex` - App detail cockpit with lifecycle, tickets, sessions, releases, evidence, and metrics entry points.
- `board_live.ex` - Draggable ticket board and harness packet builder.
- `sessions_live.ex` - Codex session inbox, linking, ignore, and review workflows.
- `releases_live.ex` - Release targets, checklist gates, transitions, and checklist evidence.
- `evidence_live.ex` - Evidence packet creation, listing, and optional subject linking.
- `metrics_live.ex` - Manual metrics snapshots and stale live-app business flags.
- `settings_live.ex` - Repository roots, Codex intake, privacy, and JSONL import controls.
