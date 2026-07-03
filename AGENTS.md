This is a web application written using the Phoenix web framework.

> **Claude Code**: `CLAUDE.md` points here — this file is the single source of project rules.

## Commands

- `mix setup` — install deps, create/migrate PostgreSQL database, build assets
- `mix phx.server` — run the app at http://localhost:4000 (or `iex -S mix phx.server`)
- `mix test` — run tests (auto-creates/migrates the test database)
- `mix test test/afp/factory/work_test.exs` — run one test file; append `:LINE` for one test
- `mix precommit` — required before committing: compiles with `--warnings-as-errors`, checks unused deps, formats, runs tests. Fix anything it reports.

## Architecture

App Factory Control Plane: a local-first Phoenix 1.8 LiveView app (PostgreSQL, Oban, Bandit) for running a one-person app portfolio — demand discovery, app lifecycle, tickets/harness packets, Codex session intake, releases, evidence, and metrics.

The core pattern is thin LiveViews over fat contexts:

- **Contexts** (`lib/afp/factory/*`) own all validation, state-transition rules, and event emission. One context per PRD boundary: `Opportunities`, `Demand`, `Portfolio`, `Work`, `Sessions`, `Releases`, `Evidence`, `Metrics`, `Repositories`, `Growth`, `Maintenance`, `Settings`, `Dashboard` (Today read model), `Events`.
- **LiveViews** (`lib/afp_web/live/*`) render UI, call contexts, and reload their read model when `Factory.Events` broadcasts over Phoenix PubSub. `Factory.Events` is also an append-only audit log — mutations in contexts record events; LiveViews subscribe and refresh.
- **Lifecycle is manual.** Tickets, sessions, releases, and evidence orbit the app record but never auto-advance its lifecycle stage; the operator confirms transitions explicitly. Release state is separate from app lifecycle.
- **External integrations**: Codex hook intake at `POST /api/codex/hooks` plus a JSONL spool importer (Oban worker in `Factory.Settings`); `Factory.Demand` supervises long-running Codex app-server JSON-RPC launches; `Factory.Opportunities` launches research with either Codex (app-server) or Claude Code (headless `claude -p` stream-json adapter in `Factory.Opportunities.ClaudeCodeClient`); `Factory.Opportunities` and `Factory.Demand` read/write external repos that keep their own repo-local SQLite state (`base.sqlite`) under manifest-declared contracts (see `docs/opportunities-repo-contract.md` and `docs/demand-repo-control-plane-design.md`). All external-repo SQLite access goes through the single `Factory.RepoSqlite` seam. App repos follow the target contract in `docs/app-repo-contract.md` (`afp-app-repo/v1`, golden template at `~/Developer/Websites/afp-app-template`); the AFP-side BuildRunner is not implemented yet.
- Shared schema defaults (UUID PKs, timestamps) live in `Factory.Schema`; shared constants/normalizers in `Afp.Factory`; flexible jsonb columns use `Factory.JsonData`.

## Core project rules

- Use `mix precommit` when you are done and fix any issues it reports.
- Use the included `Req` client for HTTP requests. Do not introduce `:httpoison`, `:tesla`, or `:httpc`.
- **Do not opportunistically fix unrelated behavior while working on the current request.** If you notice unrelated bugs, cleanup opportunities, or behavior mismatches, leave them unchanged unless the user explicitly asks for them.
- Prefer small, working changes that match existing project patterns.
- After completing a feature-sized milestone that passes validation, run `git add`, `git commit`, and `git push` for the task-related changes. Do not include unrelated dirty work unless the user explicitly asks for full-tree staging.

## Production API compatibility

- Existing public or app-facing API contracts are backward-compatible by default.
- When changing an existing endpoint, preserve behavior expected by older app versions, including request shape, response shape, status codes, authentication semantics, and meaningful side effects.
- If a change would break existing clients, create a new endpoint, version, or opt-in behavior instead of changing the existing contract in place.
- Treat all API upgrades as compatibility work: document or test the compatibility path when the change affects existing clients.

## Planning and scope

- For complex work, break the task into 3 to 5 stages in `IMPLEMENTATION_PLAN.md`.
- Update stage status as you progress.
- Remove `IMPLEMENTATION_PLAN.md` when all stages are complete.

## Documentation and file hygiene

- After functionality, architecture, or coding-pattern changes, update the relevant docs before finishing.
- Keep the root `README.md` and any existing directory `README.md` files aligned with code changes.
- When adding a durable source directory, include a minimal `README.md` with:
  - the header comment `<!-- If files in this folder change, update this document. -->`
  - a short architecture summary
  - a file inventory with role and purpose
- New source files, and modified source files that already use this convention, must keep the 3-line header block:

```elixir
# @input  - External dependencies this file relies on
# @output - What this file provides to the system
# @pos    - This file's role in the local architecture
```

- If the database changes in any way, update `docs/database_schema.md`.
- **Keep source files under 600 lines.** A file that exceeds 600 lines is a signal it carries too much: refactor it into deeper, smaller modules (extract a clean interface behind a new module, split a context's sub-concerns into `lib/afp/factory/<context>/*`) rather than letting it grow. Don't split arbitrarily at the line — split along a real seam.

## Hard Phoenix project constraints

- Always begin LiveView templates with `<Layouts.app flash={@flash} ...>`.
- If `current_scope` is required, fix it through the proper authenticated `live_session` and pass it into `<Layouts.app>`.
- Never call `<.flash_group>` outside `layouts.ex`.
- Use the imported `<.icon>` component for icons.
- Use the imported `<.input>` component for form inputs when available.
- Keep the Tailwind v4 import syntax in `assets/css/app.css`.
- Never use `@apply`.
- Never write inline `<script>` tags in HEEx templates.
- Do not add daisyUI.

## Task-specific reference docs

Read the relevant file before making changes in that area:

- Elixir, Phoenix, Ecto, router, controller, schema, or HEEx work:
  [`docs/agent_framework_rules.md`](docs/agent_framework_rules.md)
- LiveView implementation, streams, LiveView tests, or form handling:
  [`docs/agent_liveview_rules.md`](docs/agent_liveview_rules.md)
- CSS, JS hooks, and UI presentation work:
  [`docs/agent_ui_rules.md`](docs/agent_ui_rules.md)

## Agent skills

### Issue tracker

Issues tracked in GitHub Issues (iiiyu/afp) via the `gh` CLI; external PRs are not a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary — needs-triage / needs-info / ready-for-agent / ready-for-human / wontfix. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context (CONTEXT.md + docs/adr/ at repo root). See `docs/agents/domain.md`.
