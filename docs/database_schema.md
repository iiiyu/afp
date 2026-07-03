<!-- If files in this folder change, update this document. -->

# Database Schema

PostgreSQL is the application source of truth for the core surfaces
(Opportunities + Apps). Core domain tables use UUID primary keys,
`utc_datetime_usec` timestamps, text-backed controlled states validated in
Ecto, and jsonb for flexible payload fields.

The 2026-07 core refactor dropped all non-core tables (demand, work/tickets,
harness packets, sessions, evidence, releases, metrics, repo scans, growth,
maintenance, build runs) via `20260703170000_drop_non_core_tables`; their
definitions remain in git history for future rebuilds.

## Tables

- `apps` - Portfolio inventory, lifecycle state, business posture, computed
  health state, repository path, product thesis, next action, version/build,
  and archival fields.
- `events` - Append-only audit log for state changes and operator decisions
  (`subject_type`, `subject_id`, `event_type`, jsonb payload).
- `settings` - jsonb-backed local configuration key/value store, including the
  configured opportunities repo path and its latest health snapshot.
- `oban_jobs` and related Oban database objects - Background job storage
  (currently no workers; kept for future use).

## External Opportunity Repo SQLite

The `/opportunities` surface does not add PostgreSQL tables for individual
opportunities. AFP persists the selected repo path in `settings` and reads or
writes the repo-local `base.sqlite` database described in
[`docs/opportunities-repo-contract.md`](opportunities-repo-contract.md).

`base.sqlite` contains:

- `repo_metadata` - schema version, template version, display name, and repo
  metadata.
- `opportunities` - raw input, normalized title, source URL, launch agent
  (`codex` or `claude_code`), status, stage, route, score, current run, agent
  session, latest summary, error, and timestamps.
- `opportunity_runs` - agent launch prompt, launch agent, run type
  (`initial_research` or `build_spec`), run status, stage, session/thread/turn
  metadata, transcript path, final answer, error, payload, and timestamps.
- `opportunity_step_results` - one row per research pipeline step per
  opportunity (`pending`/`completed`/`failed`), with step key/index, score,
  evidence strength, summary, artifact path, and structured payload. Seven
  rows are pre-seeded as `pending` per launch.
- `opportunity_step_evidence` - one row per kept per-step evidence file
  (20-80 rule, max 3 per step), with step key, title, kind
  (`analysis`/`screenshot`/`source_excerpt`), file path, why it matters, and
  source URL.
- `opportunity_files` - Markdown/image files under `opportunities/[uuid]/`,
  including build-spec package files under `spec/`, with relative path, file
  type, size, mtime, and timestamps.

## External App Repo SQLite

App repos (`afp-app-repo/v1`) keep build state in their own
`afp/state.sqlite`: `build_milestones` (agent-owned milestone plan),
`build_runs` (AFP-owned launch records with authoritative verify results and
the `reviewed_at` hard-gate column), and `build_evidence`. AFP reads and
writes them through `Factory.RepoSqlite`; no PostgreSQL tables are involved.

## Important Constraints

- `apps.slug` is unique.
- `apps.repo_path` is unique when present, preventing duplicate
  repository-backed app records.
- `apps.health_state` is computed on write (archived → repo_missing →
  needs_next_action → healthy) and can be overridden by the operator.
- The configured opportunities repo is stored as one `settings` value; the
  portable opportunity rows, run rows, and file index stay in the external
  repo's `base.sqlite`.

## State Fields

- App lifecycle: `idea`, `validation_ready`, `validation_sprint`,
  `build_ready`, `in_build`, `release_ready`, `submitted`, `live`,
  `iterating`, `maintained`, `paused`, `archived`.
- Business posture: `unknown`, `grow`, `maintain`, `fix`, `harvest`, `pause`,
  `kill`.
- App health: `unknown`, `healthy`, `needs_next_action`, `repo_missing`,
  `repo_dirty`, `blocked`, `archived`.
- Opportunity repo health: `healthy`, `missing`, `sqlite_missing`,
  `sqlite_invalid`, `agents_missing`, `invalid_structure`.
- Opportunity status in `base.sqlite`: `captured`, `queued`, `running`,
  `researched`, `build_spec_ready`, `promoted`, `failed`.
- Opportunity run type in `base.sqlite`: `initial_research`, `build_spec`.
- Opportunity run status in `base.sqlite`: `queued`, `running`, `completed`,
  `failed`.
- Opportunity step result status in `base.sqlite`: `pending`, `completed`,
  `failed`.
