<!-- If files in this folder change, update this document. -->
# Docs

This folder holds project documentation and agent-facing implementation
guidance. The agent rule files are referenced from `AGENTS.md` so agents can
load only the detailed guidance relevant to the current task.

## Files

- `README.md` - Folder index for the docs directory.
- `agent_framework_rules.md` - Agent framework guide: detailed Elixir, Phoenix, Ecto, router, controller, schema, and HEEx implementation rules referenced from `AGENTS.md`.
- `agent_liveview_rules.md` - Agent LiveView guide: detailed LiveView, stream, test, JavaScript interop, and form rules referenced from `AGENTS.md`.
- `agent_ui_rules.md` - Agent UI guide: detailed Tailwind, CSS, JavaScript bundle, and visual presentation rules referenced from `AGENTS.md`.
- `database_schema.md` - Current PostgreSQL schema summary, core constraints, and controlled state fields.
- `demand-repo-control-plane-design.md` - Design contract for demand source repositories, scheduled/manual research runs, human-confirmed gates, product packages, and required repo-local SQLite.
- `opportunities-repo-contract.md` - Contract for the primary `/opportunities` portable repo, required structure, `base.sqlite` tables, health rules, and Codex launch boundary.
- `phase-2-dogfood-operating-loop.md` - Phase 2 operating loop scope, flow, non-goals, and verification contract.
- `screenshots/` - README screenshots generated from the local Phoenix UI.
