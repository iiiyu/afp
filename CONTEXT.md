# AFP Domain Glossary

The ubiquitous language of the App Factory control plane. Use these terms
exactly; synonyms listed as *avoid* are banned in code, docs, and issues.

## Discovery (Opportunities)

- **Opportunity** — one idea/need/URL captured into the opportunity repo and
  researched through the seven-step pipeline. Read model:
  `Opportunities.Opportunity`. *Avoid: demand item, candidate, lead.*
- **Run** — one agent execution against an opportunity (`initial_research`
  or `build_spec`). Read model: `Opportunities.Run`.
- **Step Result / Step Evidence** — one row per pipeline step per
  opportunity, plus the kept evidence files (20-80 rule, max 3 per step).
- **Opportunity Repo** — the external, portable git repo that owns
  opportunity state in its repo-local `base.sqlite` under the contract in
  `docs/opportunities-repo-contract.md`. AFP stores only its path.
- **Build Spec** — the PRD/spec package generated under
  `opportunities/<id>/spec/` after research completes.

## Portfolio (Apps)

- **App** — a portfolio record: repository path, lifecycle stage, business
  posture, computed health, next action. *Avoid: project, product.*
- **Lifecycle stage** — operator-confirmed only; nothing auto-advances it.
- **Health state** — derived at write time from repo existence and
  next-action presence (`App.computed_health_state/2`, inspector injected);
  the operator can override via `Portfolio.set_health_state/2`.
- **App Repo** — an external repo following `afp-app-repo/v1`
  (`docs/app-repo-contract.md`): golden template or retrofit.
- **Build Run** — one agent execution against a milestone (or ad-hoc task)
  in an app repo; recorded repo-locally in `afp/state.sqlite`
  (`docs/build-runner-v2-design.md`). *Avoid: build job, packet.*
- **Review gate** — the hard per-app gate: a completed build run must be
  marked reviewed before the next milestone may launch. Distinct from the
  four permanent human gates (spec approval, first submission, pricing,
  kill).

## Agent launch (the AgentClient seam)

- **AgentClient** — the behaviour every launch transport fills. Adapters:
  `CodexAppClient` (app-server JSON-RPC), `ClaudeCodeClient` (headless CLI),
  `FakeAgentClient` (tests).
- **Request / Result / Error** — the neutral envelope crossing the seam
  (`AgentClient.Request/Result/Error`). Transport detail (sandbox JSON, CLI
  permission rules) never crosses it. *Avoid: attrs map, launch envelope.*
- **Approvals / Profile** — the pure decision engine for agent
  server-requests: a `Profile` derives the launch bounds; `decide_*`
  functions return `{decision, reason}` verdicts.
- **Command Policy** — the single command-safety vocabulary
  (`AgentClient.CommandPolicy`), rendered per transport.
- **Launch events** — `:thread_started`, `:turn_started`, `:activity` with
  neutral payloads, delivered via `:on_launch_event`.
- **Activity Feed** — the bounded live-activity read model and its refresh
  throttle (`Opportunities.ActivityFeed`).

## Infrastructure

- **Events** — the append-only audit log + PubSub broadcast
  (`Factory.Events`); every context mutation records one.
- **RepoSqlite** — the single seam for external-repo `sqlite3` CLI access.
- **Storage seam** — `Opportunities.Storage`: SQL and physical column names
  stop here; typed structs cross it (see ADR-0001 for the `codex_*`
  column mapping).
