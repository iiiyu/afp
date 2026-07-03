<!-- If files in this folder change, update this document. -->

# Factory Contexts

## Architecture Summary

This folder contains the one-person app factory domain model, refactored down
to the two core surfaces — Opportunities and Portfolio (Apps) — plus the
shared infrastructure they need. Everything else (demand, work, sessions,
evidence, releases, metrics, growth, maintenance, dashboard, BuildRunner v0)
was removed in the 2026-07 core refactor and will be rebuilt outward from
these two; see git history for the removed implementations. State transitions
stay in contexts so LiveViews remain thin.

## File Inventory

- `factory.ex` - Shared constants (lifecycle stages, business postures, health
  states) and normalization helpers.
- `factory/schema.ex` - UUID and timestamp schema defaults.
- `factory/json_data.ex` - Flexible jsonb Ecto type.
- `factory/repo_sqlite.ex` - Single seam for all external-repo `sqlite3` CLI
  access (query/execute/escape), with busy-timeout, JSON decode, and error
  normalization.
- `factory/agent_client.ex` - `@behaviour` for a launch transport
  (`launch_new_turn/2`); implemented by `codex_app_client.ex`,
  `opportunities/claude_code_client.ex`, and the test fakes.
- `factory/codex_app_client.ex` - Codex CLI app-server JSON-RPC transport
  (Port + NDJSON stream) with manifest-bounded approval replies.
- `factory/events.ex` and `factory/events/event.ex` - Append-only audit log
  and PubSub broadcasts (global, per-subject, and run-activity topics).
- `factory/opportunities.ex` plus `factory/opportunities/*` - Portable
  opportunity repo setup, health inspection, repo-local `base.sqlite` storage,
  schema upgrades, the Markdown/image file browser, sync/async research
  launches (Codex or Claude Code via `AgentLaunchSupervisor`), and
  post-research PRD/spec generation.
- `factory/portfolio.ex` and `factory/portfolio/app.ex` - App inventory,
  lifecycle, business posture, computed health, and repo-path matching.
- `factory/settings.ex` and `factory/settings/setting.ex` - Key/value local
  settings persistence with audit events (stores the opportunities repo
  config).
