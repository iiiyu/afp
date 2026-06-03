<!-- If files in this folder change, update this document. -->

# Database Schema

The MVP uses PostgreSQL as the application source of truth. Core domain tables
use UUID primary keys, `utc_datetime_usec` timestamps, text-backed controlled
states validated in Ecto, and jsonb for flexible packet/payload fields.

## Tables

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
- `events` - Append-only audit log for state changes, intake, and operator decisions.
- `settings` - jsonb-backed local configuration, including repository roots, Codex intake settings, transcript privacy, and JSONL spool offsets.
- `oban_jobs` and related Oban database objects - Background job storage for retryable/local intake tasks.

## Important Constraints

- `apps.slug` is unique.
- `apps.repo_path` is unique when present, preventing duplicate repository-backed app records.
- `codex_sessions.external_session_id` is unique, so duplicate hook events update the same session rather than creating duplicate sessions.
- `ticket_session_links.ticket_id, codex_session_id` is unique.
- Release checklist readiness is enforced in `Afp.Factory.Releases` before a release target can move to `ready_for_review`.
- Ticket `done` and `blocked` review requirements are enforced in `Afp.Factory.Work`.

## State Fields

Controlled states are stored as text to keep MVP iteration simple and are
validated in Ecto changesets:

- App lifecycle: `idea`, `validation_ready`, `validation_sprint`, `build_ready`, `in_build`, `release_ready`, `submitted`, `live`, `iterating`, `maintained`, `paused`, `archived`.
- Business posture: `unknown`, `grow`, `maintain`, `fix`, `harvest`, `pause`, `kill`.
- Ticket status: `backlog`, `ready`, `active`, `review`, `blocked`, `done`, `dropped`.
- Harness packet state: `draft`, `ready`, `launched`, `observing`, `review`, `routed`, `superseded`.
- Codex session status: `detected`, `linked`, `running`, `waiting`, `stopped`, `reviewed`, `ignored`.
- Release target status: `draft`, `preparing`, `ready_for_review`, `submitted`, `live`, `blocked`, `cancelled`.
- Release check status: `pending`, `passed`, `failed`, `waived`, `not_applicable`.
