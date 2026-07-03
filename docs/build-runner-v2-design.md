<!-- If files in this folder change, update this document. -->

# BuildRunner v2 Design (grilled 2026-07-04)

Decisions from the grilling session on rebuilding the execution layer from
the Apps surface. Each decision lists its rationale; two are provisional
(operator was away — marked ⏳, confirm before implementing that part).

## Decisions

1. **Work unit = repo milestone.** AFP reads `build_milestones` from the app
   repo's `afp/state.sqlite` (mirroring how Opportunities reads
   `base.sqlite`) and launches against a milestone. A free-text ad-hoc task
   is the fallback for retrofit repos without a spec package.

2. **Run records are repo-local.** The `afp-app-repo` contract gains a
   `build_runs` table in `afp/state.sqlite` (small contract version bump for
   the template and LumaSpark). No Postgres build tables: the repo stays
   portable and carries its full build history; AFP reads through
   `Factory.RepoSqlite` with typed read-model structs (same pattern as
   `Opportunities.Records`).

3. **Thin prompt; the repo owns the instructions.** AFP injects only
   identity (milestone key, run id) and the entrypoint pointer (AGENTS.md +
   `.skills/implement-milestone`). Lessons like the one-turn contract live
   in the template, not in AFP code. Retrofits use a slightly thicker
   generic variant.

4. **AFP re-runs verify and is the sole authority.** After the turn, AFP
   executes `verify.entrypoint` via a Port and reads `verify.json` back;
   agent-produced verify output is never trusted as the gate. The
   VerifyRunner auto-retries a gate once on infrastructure false-reds
   (0 tests ran + install/launch failure signature).

5. **Evidence = repo files + Events; no Evidence tables.** The App detail
   page lists milestones/runs from the state db and previews
   `afp/reports/*` and `verify.json` (generalized opportunities file
   browser). Audit trail via `Factory.Events`.

6. **Hard review gate.** A completed run must be marked reviewed
   (`reviewed_at` on the run row) before the next milestone can launch for
   that app. Operator chose the strict form over a soft warning — quality
   over throughput, consistent with the account-risk posture. Diffs are
   reviewed in the IDE; reports reference commit hashes.

7. **Per-app serial, cross-app parallel.** One active run per app; different
   apps may run concurrently. Simulator contention is handled by (a) a
   global serial queue for AFP-run verify chains and (b) an optional
   `verify.simulator` manifest field so each app pins a distinct simulator
   (`VERIFY_SIM`), isolating agent-turn builds too.

8. ⏳ **Failure/stale handling (provisional — recommended, unconfirmed):**
   on turn failure AFP marks the run `failed` and resets a lying
   `in_progress` milestone back to `pending`; a startup/page-load
   reconciler fails `running` runs past a grace window with no session
   metadata; the detail page offers a force-fail button for hung runs.

9. **No lifecycle coupling.** Settled by the standing rule (AGENTS.md:
   lifecycle is manual): run completion records Events only; it never
   advances `lifecycle_stage` or health.

## Out of scope for v2

- Diff viewing inside AFP (IDE is the diff surface).
- Cross-app aggregate build dashboards.
- Simulator pools / parallelism beyond per-app.
- "New app from template" scaffold action (separate slice; prerequisite for
  greenfield apps but not for the LumaSpark-driven v2 bring-up).

## Implementation order (suggested)

1. Contract bump: `build_runs` table + `verify.simulator` in the template's
   `afp/schema.sql` + `manifest.json`; apply to LumaSpark.
2. `Factory.Builds` context v2: repo records (structs), launch
   (AgentClient.Request, thin prompt), per-app lock + verify queue,
   VerifyRunner with false-red retry, reconciler.
3. App detail page: milestones panel, runs panel with hard review gate,
   report/verify file preview.
