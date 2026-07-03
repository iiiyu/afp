<!-- If files in this folder change, update this document. -->

# Factory.Builds — BuildRunner v2

## Architecture Summary

The execution layer, designed in `docs/build-runner-v2-design.md` and
launched from each app's repo detail page. Work units are repo milestones
(plus an ad-hoc task fallback for retrofits); all build state lives
repo-locally in the app repo's `afp/state.sqlite`; AFP re-runs the verify
chain as the sole authority. The context module (`../builds.ex`) owns the
loop: preflight (health, per-app serial lock, hard review gate) → thin
prompt through the `Factory.AgentClient` seam → queued verify → repo-local
record + Events.

## File Inventory

- `records.ex` - Typed read models: `Milestone` (agent-owned rows) and
  `BuildRun` (AFP-owned rows, `verify_json` decoded once, `reviewed_at`
  carries the hard review gate).
- `storage.ex` - `afp/state.sqlite` DML behind the structs; `ensure_schema/1`
  creates the build tables idempotently so retrofits need no migration.
- `app_repo.ex` - `afp-app-repo/v1` contract reader: manifest parsing, health
  verdict, verify entrypoint/report/simulator accessors.
- `verify_runner.ex` - Port executor for the repo's verify entrypoint with
  `VERIFY_SIM` pinning and one automatic retry on infrastructure false-reds.
- `verify_queue.ex` - Global GenServer queue: one verify chain at a time
  across all apps (simulator-contention lock).
