# App Factory Control Plane

Local-first Phoenix LiveView control plane for running a one-person app
factory: idea → research → build spec → agent-built app → App Store.

After the 2026-07 core refactor the app is intentionally small — two surfaces,
rebuilt outward as the factory pipeline matures:

- **Opportunities** (`/opportunities`, also the root route): the discovery
  surface. Turns an idea, need, or URL into a portable opportunity folder in
  an external research repo, runs the seven-step research pipeline with a
  coding agent (Codex or Claude Code), scores the opportunity, and generates
  the build-spec package. State lives in the repo's own `base.sqlite` under
  the contract in [`docs/opportunities-repo-contract.md`](docs/opportunities-repo-contract.md).
- **Apps** (`/apps`): the portfolio. App records with repository path,
  lifecycle stage, business posture, computed health, next action, and an
  append-only per-app event history. Lifecycle transitions are always
  operator-confirmed.

![Portfolio screen](docs/screenshots/portfolio-apps.png)

## The Factory Around This Repo

- [`docs/app-repo-contract.md`](docs/app-repo-contract.md) — the
  `afp-app-repo/v1` contract app repos follow (gate vocabulary, verify.json,
  repo-local state db).
- [afp-app-template](https://github.com/iiiyu/afp-app-template) — the golden
  Apple-native template implementing that contract: XcodeGen project, SPM
  feature modules, `Scripts/verify.sh` oracle chain, agent skills, asc-based
  release lane.
- Removed-but-proven building blocks (demand pipeline, tickets/harness
  packets, sessions, releases, evidence, metrics, BuildRunner v0) live in git
  history and will be rebuilt from the two core surfaces.

## Architecture

Thin LiveViews over fat contexts. Contexts (`Opportunities`, `Portfolio`,
`Settings`, `Events`) own validation, state transitions, and event emission;
LiveViews subscribe to `Factory.Events` over PubSub and reload on broadcast.
Agent launches go through the `Factory.AgentClient` behaviour
(`Factory.CodexAppClient` for Codex app-server JSON-RPC,
`Factory.Opportunities.ClaudeCodeClient` for headless Claude Code), supervised
by a Task.Supervisor. All external-repo SQLite access goes through
`Factory.RepoSqlite`.

See [`AGENTS.md`](AGENTS.md) for project rules and
[`docs/database_schema.md`](docs/database_schema.md) for the schema.

## Running

```bash
mix setup        # deps, database, assets
mix phx.server   # http://localhost:4000
mix test
mix precommit    # required before committing
```
