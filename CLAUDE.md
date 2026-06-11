# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- `mix setup` — install deps, create/migrate PostgreSQL database, build assets
- `mix phx.server` — run the app at http://localhost:4000 (or `iex -S mix phx.server`)
- `mix test` — run tests (auto-creates/migrates the test database)
- `mix test test/afp/factory/work_test.exs` — run one test file; append `:LINE` for one test
- `mix precommit` — required before committing: compiles with `--warnings-as-errors`, checks unused deps, formats, runs tests. Fix anything it reports.

## Required reading before editing

`AGENTS.md` holds the core project rules. Additionally, read the matching reference doc before working in that area:

- Elixir/Phoenix/Ecto/router/controller/schema/HEEx: `docs/agent_framework_rules.md`
- LiveView, streams, LiveView tests, forms: `docs/agent_liveview_rules.md`
- CSS, JS hooks, UI presentation: `docs/agent_ui_rules.md`

## Architecture

App Factory Control Plane: a local-first Phoenix 1.8 LiveView app (PostgreSQL, Oban, Bandit) for running a one-person app portfolio — demand discovery, app lifecycle, tickets/harness packets, Codex session intake, releases, evidence, and metrics.

The core pattern is thin LiveViews over fat contexts:

- **Contexts** (`lib/afp/factory/*`) own all validation, state-transition rules, and event emission. One context per PRD boundary: `Opportunities`, `Demand`, `Portfolio`, `Work`, `Sessions`, `Releases`, `Evidence`, `Metrics`, `Repositories`, `Growth`, `Maintenance`, `Settings`, `Dashboard` (Today read model), `Events`.
- **LiveViews** (`lib/afp_web/live/*`) render UI, call contexts, and reload their read model when `Factory.Events` broadcasts over Phoenix PubSub. `Factory.Events` is also an append-only audit log — mutations in contexts record events; LiveViews subscribe and refresh.
- **Lifecycle is manual.** Tickets, sessions, releases, and evidence orbit the app record but never auto-advance its lifecycle stage; the operator confirms transitions explicitly. Release state is separate from app lifecycle.
- **External integrations**: Codex hook intake at `POST /api/codex/hooks` plus a JSONL spool importer (Oban worker in `Factory.Settings`); `Factory.Demand` supervises long-running Codex app-server JSON-RPC launches; `Factory.Opportunities` launches research with either Codex (app-server) or Claude Code (headless `claude -p` stream-json adapter in `Factory.Opportunities.ClaudeCodeClient`); `Factory.Opportunities` and `Factory.Demand` read/write external repos that keep their own repo-local SQLite state (`base.sqlite`) under manifest-declared contracts (see `docs/opportunities-repo-contract.md` and `docs/demand-repo-control-plane-design.md`).
- Shared schema defaults (UUID PKs, timestamps) live in `Factory.Schema`; shared constants/normalizers in `Afp.Factory`; flexible jsonb columns use `Factory.JsonData`.

## Project conventions (from AGENTS.md — see it for the full list)

- Don't fix unrelated behavior opportunistically; stay scoped to the request.
- Public/app-facing API contracts are backward-compatible by default — version or add endpoints instead of breaking existing ones.
- Use `Req` for HTTP; never add `:httpoison`, `:tesla`, or `:httpc`.
- Source files keep a 3-line `# @input / # @output / # @pos` header block; durable source directories keep a `README.md` inventory that must be updated when files change.
- Database changes require updating `docs/database_schema.md`; keep root `README.md` aligned with architecture changes.
- HEEx/UI hard rules: templates start with `<Layouts.app flash={@flash} ...>`; use imported `<.icon>` and `<.input>` components; Tailwind v4 syntax, no `@apply`, no inline `<script>`, no daisyUI.
- After a feature-sized milestone passes validation, commit and push the task-related changes.
