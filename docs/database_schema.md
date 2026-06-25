<!-- If files in this folder change, update this document. -->

# Database Schema

The MVP uses PostgreSQL as the application source of truth. Core domain tables
use UUID primary keys, `utc_datetime_usec` timestamps, text-backed controlled
states validated in Ecto, and jsonb for flexible packet/payload fields.

## Tables

- `demand_source_repos` - Configured external demand research repositories, manifest contract fields, agent/skill requirements, repo-local SQLite declaration, schedule settings, and source health.
- `demand_candidates` - Normalized AFP read-model rows for repo-owned app/game opportunities, with separate source status and AFP pickup/package/handoff routing status.
- `demand_message_templates` - Reusable operator-editable launch/follow-up prompt templates with required variables, safety notes, and expected output paths.
- `demand_research_runs` - Scheduled or manual research-run metadata linked to source repos, candidates, templates, launch requests, and optional Codex sessions.
- `demand_sent_messages` - Auditable rendered/edited Codex messages tied to demand research runs and manual handoff or future transport state.
- `demand_items` - Pre-app opportunities with source evidence, target user/job, demand signal, incumbent weakness, wedge hypothesis, validation action, confidence, and optional promoted app link.
- `codex_launch_requests` - Human-confirmed launch handoffs linked to demand items, apps, tickets, or release targets, with objective, context, risk, launch mode, status, confirmation, and handoff text.
- `apps` - Portfolio inventory, lifecycle state, business posture, health state, repository path, product thesis, next action, version/build, and archival fields.
- `tickets` - App-owned work items with workflow status, lifecycle gate, priority, risk, blocked reason, review note, and terminal timestamps.
- `harness_packets` - Executable work contracts linked to apps, optional tickets, and optional release targets. Stores context, constraints, non-goals, allowed tools, verification, required evidence, approval points, review route, result summary, and next route.
- `codex_sessions` - Observed Codex sessions with external session ID, app link, cwd, model, status, transcript path, latest turn, summary, and review/ignore timestamps.
- `ticket_session_links` - Many-to-many links between tickets and Codex sessions.
- `hook_events` - Raw Codex hook intake rows stored before processing, including unknown payload fields and processing errors.
- `evidence_packets` - Primary-app evidence records with type, title, summary, source path/URL, reliability, and jsonb payload.
- `evidence_links` - Non-destructive links from evidence packets to app-factory subjects such as tickets, sessions, releases, checklist items, and metrics snapshots.
- `release_targets` - Planned app releases with platform, label/version/build, status, submitted/live timestamps, and decision note.
- `release_check_items` - Release checklist rows with category, title, status, required flag, waiver reason, decision note, and position.
- `metrics_snapshots` - Dated manual business metrics with nullable numeric fields and notes.
- `repo_scans` - Local git scan snapshots with repository path, app match, scan status, branch, dirty counts, latest commit, platform hints, and scan errors.
- `growth_experiments` - Manual post-launch growth experiments with hypothesis, metric, status, priority, review due date, and outcome note.
- `maintenance_obligations` - Due operational work for live apps, including category, status, priority, due date, recurrence, notes, and completion timestamp.
- `events` - Append-only audit log for state changes, intake, and operator decisions.
- `settings` - jsonb-backed local configuration, including repository roots, the configured opportunities repo path and latest health snapshot, Codex intake settings, transcript privacy, and JSONL spool offsets.
- `oban_jobs` and related Oban database objects - Background job storage for retryable/local intake tasks.

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

## Important Constraints

- `apps.slug` is unique.
- `apps.repo_path` is unique when present, preventing duplicate repository-backed app records.
- `demand_items.promoted_app_id` references the app created from validated demand when promotion occurs.
- `demand_source_repos.repo_path` is unique, preventing duplicate source configuration.
- `demand_source_repos.payload["legacy_adapter"]` can record detected AppIdeas/GameIdeas legacy layout evidence when a git source is missing the unified manifest; the source remains `manifest_missing` until operator adoption or repair.
- `demand_candidates.demand_source_repo_id, lane, external_id` is unique, so AFP can re-index a repo-owned candidate without duplicating it.
- `demand_candidates.demand_item_id` optionally links an indexed candidate to the AFP demand item created when the operator picks it up.
- `demand_candidates.package_path` points back into the source repo; package verification requires the app-lane or game-lane package files before AFP marks the candidate `package_ready`.
- `demand_research_runs` can link to a source repo, optional candidate, message template, launch request, and Codex session while leaving detailed run artifacts in the source repo.
- `demand_sent_messages` belong to a research run and can link to the launch request/session used to hand off a new message or continue an existing Codex session. Direct Codex launches store compact JSON-RPC thread/turn metadata in `payload`.
- The configured opportunities repo is stored as one `settings` value; the portable opportunity rows, run rows, and file index stay in the external repo's `base.sqlite`.
- `demand_message_templates.name` is unique.
- Source repo index refresh reads the manifest-declared repo-local SQLite database only when `sqlite.allowed_operations` includes `read_index` or `read_candidates`; imported rows update `demand_candidates` and record a completed `repo_audit` research run.
- Scheduled demand research checks healthy, schedule-enabled source repos against `schedule_interval_hours` and `last_run_at`, then creates draft `scheduled_scan` launch requests for due sources without sending them.
- `codex_launch_requests` can point at a demand item, app, ticket, release target, or generic source pair; launch state never implies task success.
- `codex_sessions.external_session_id` is unique, so duplicate hook events update the same session rather than creating duplicate sessions.
- `ticket_session_links.ticket_id, codex_session_id` is unique.
- `repo_scans.repository_path` is unique, so each local repository has one latest scan row.
- Release checklist readiness is enforced in `Afp.Factory.Releases` before a release target can move to `ready_for_review`.
- Ticket `done` and `blocked` review requirements are enforced in `Afp.Factory.Work`.
- Growth experiments require an outcome note before terminal `won`, `lost`, or `dropped` states.
- Maintenance obligations require notes before terminal `done` state.

## State Fields

Controlled states are stored as text to keep MVP iteration simple and are
validated in Ecto changesets:

- App lifecycle: `idea`, `validation_ready`, `validation_sprint`, `build_ready`, `in_build`, `release_ready`, `submitted`, `live`, `iterating`, `maintained`, `paused`, `archived`.
- Demand status: `captured`, `researching`, `validating`, `validated`, `promoted`, `rejected`, `parked`.
- Demand confidence: `unknown`, `low`, `medium`, `high`.
- Demand source health: `unknown`, `healthy`, `missing`, `not_git`, `manifest_missing`, `invalid_manifest`, `invalid_structure`, `agents_missing`, `sqlite_missing`, `sqlite_invalid`, `skills_unavailable`, `unsupported`.
- Demand lanes: `app`, `game`.
- Demand candidate source status: `new`, `researching`, `validation-ready`, `validation-sprint`, `build-ready`, `rejected`, `parked`, `watched`, `packaged`, `superseded`.
- Demand candidate AFP status: `not_picked_up`, `pickup_recommended`, `picked_up`, `package_requested`, `package_ready`, `handoff_ready`, `promoted`, `rejected`, `parked`.
- Demand research run type: `scheduled_scan`, `manual_idea`, `manual_url`, `deep_research`, `package_generation`, `repo_audit`, `session_continue`.
- Demand research run status: `draft`, `ready`, `launched`, `running`, `completed`, `failed`, `cancelled`, `reviewed`.
- Demand message target: `new_session`, `existing_session`, `manual_handoff`.
- Demand sent message status: `draft`, `confirmed`, `sent`, `accepted`, `failed`, `superseded`.
- Opportunity repo health: `healthy`, `missing`, `sqlite_missing`, `sqlite_invalid`, `agents_missing`, `invalid_structure`.
- Opportunity status in `base.sqlite`: `captured`, `queued`, `running`, `researched`, `build_spec_ready`, `failed`.
- Opportunity run type in `base.sqlite`: `initial_research`, `build_spec`.
- Opportunity run status in `base.sqlite`: `queued`, `running`, `completed`, `failed`.
- Opportunity step result status in `base.sqlite`: `pending`, `completed`, `failed`.
- Codex launch request status: `draft`, `ready`, `launched`, `cancelled`.
- Codex launch mode: `manual_handoff`, `direct_codex`.
- Business posture: `unknown`, `grow`, `maintain`, `fix`, `harvest`, `pause`, `kill`.
- App health: `unknown`, `healthy`, `needs_next_action`, `repo_missing`, `repo_dirty`, `blocked`, `release_blocked`, `review`, `metrics_stale`, `maintenance_due`, `growth_review`, `archived`.
- Ticket status: `backlog`, `ready`, `active`, `review`, `blocked`, `done`, `dropped`.
- Harness packet state: `draft`, `ready`, `launched`, `observing`, `review`, `routed`, `superseded`.
- Codex session status: `detected`, `linked`, `running`, `waiting`, `stopped`, `reviewed`, `ignored`.
- Release target status: `draft`, `preparing`, `ready_for_review`, `submitted`, `live`, `blocked`, `cancelled`.
- Release check status: `pending`, `passed`, `failed`, `waived`, `not_applicable`.
- Repository scan status: `unknown`, `healthy`, `dirty`, `missing`, `not_git`, `error`.
- Growth experiment status: `idea`, `ready`, `running`, `review`, `won`, `lost`, `paused`, `dropped`.
- Maintenance obligation status: `open`, `due`, `blocked`, `done`, `dropped`.
- Maintenance category: `maintenance`, `compliance`, `release`, `support`, `dependency`, `privacy`, `analytics`.
