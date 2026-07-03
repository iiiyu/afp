<!-- If files in this folder change, update this document. -->

# App Repo Contract (afp-app-repo/v1)

AFP's build surface points at local app repos that carry their own build
state, the same way `/opportunities` points at the opportunity repo. AFP
stores only repo paths (Portfolio app records reference a `repository_path`);
the app repo owns build state through `afp/state.sqlite`, fixed-name reports,
and a machine-readable manifest.

Two kinds of app repos satisfy the contract:

- **Template-born** — instantiated from `afp-app-template`
  (`~/Developer/Websites/afp-app-template`), the golden Apple-native template.
  Layout, scripts, and skills all come from the template.
- **Retrofit** — an existing app that adopts the contract additively
  (`afp/` directory + `Scripts/verify.sh` + `Scripts/xcresult-summary.sh`).
  Reference example: `~/Developer/Apps/LumaSpark`. The contract deliberately
  does not require the template layout — only the manifest, the gate
  vocabulary, verify.json, and the state db.

## Manifest

`afp/manifest.json` is the repo's self-description and the only file AFP must
read to integrate a repo:

```json
{
  "contract": "afp-app-repo/v1",
  "template": { "name": "afp-app-template", "version": "0.1.0" },
  "app": { "display_name": "...", "bundle_id": "...", "platforms": ["ios"] },
  "state_db": "afp/state.sqlite",
  "artifacts_dir": "afp/artifacts",
  "reports_dir": "afp/reports",
  "spec_dir": "spec",
  "verify": {
    "entrypoint": "Scripts/verify.sh",
    "report": "afp/artifacts/verify.json",
    "gates": [ { "id": "build_ios", "active": true, "oracle": "..." } ]
  },
  "release": { "archive": "...", "publish": "...", "screenshots": "...",
               "human_gates": ["app_record_creation", "first_submission",
                               "pricing", "kill_decision"] }
}
```

Health checks mirror the opportunities pattern: manifest present and
`contract == "afp-app-repo/v1"`, state db present with the expected tables,
verify entrypoint executable, `AGENTS.md` present.

## Gate Vocabulary

Fixed gate ids shared by spec packages, app repos, and AFP harness packets:

| Gate id | Oracle |
|---------|--------|
| `gen` | project regenerates cleanly from `project.yml` (template repos) |
| `format` | `swift format lint --strict` finds nothing |
| `build_ios` | simulator build-for-testing succeeds, warnings as errors |
| `unit_tests` | all Swift Testing unit tests pass |
| `ui_smoke` | smoke UI test class passes on simulator |
| `store_lint` | store metadata present and within App Store limits |

A repo's manifest declares which gates are active (retrofits may mark gates
inactive with a reason). `Scripts/verify.sh` runs the active chain and writes
`afp/artifacts/verify.json`:

```json
{ "contract": "afp-app-repo/v1", "pass": true,
  "gates": [ { "id": "build_ios", "status": "pass", "duration_s": 41,
               "log": "afp/artifacts/logs/build_ios.log" } ] }
```

Gate statuses: `pass` / `fail` / `skip`. The chain exits non-zero unless all
non-skipped gates pass. Failed test gates also produce
`afp/artifacts/results/<gate>-summary.json` (distilled by
`Scripts/xcresult-summary.sh`) — this is what gets fed back to agents in the
self-repair loop, never raw logs.

The verification matrix in a spec package (`spec/07-verification-matrix.md`)
and the `verification_plan` in AFP harness packets reference these gate ids,
giving a machine-traceable chain: requirement → oracle → execution → evidence.

## State Database

`afp/state.sqlite` (schema in the template's `afp/schema.sql`):

- `build_milestones` — one row per milestone from `spec/08-milestones.md`
  (`milestone_key`, `milestone_index`, `title`, `status`
  pending/in_progress/completed/failed/blocked, `summary`, `artifact_path`,
  `verify_json`, `attempts`). AFP pre-seeds `pending` rows at launch;
  agents upsert on completion.
- `build_evidence` — durable evidence registry (reports, screenshots,
  reviews) keyed by `(milestone_key, file_path)`.

All AFP access goes through the existing `Factory.RepoSqlite` seam.

## Build Pipeline Skills

Skills ship inside the repo under `.skills/` and version with the template —
app repos never edit skills locally. First-party skills (template version
0.1.0): `scaffold-from-spec`, `implement-milestone` (the core loop, one fresh
session per milestone), `cross-review` (second agent, opposite vendor),
`ui-polish-pass`, `store-assets`, `capture-screenshots`, `release-train`
(stops before submission). `.skills/vendor/asc/` vendors the asc CLI's skill
pack, pinned by `VERSION`.

Every skill has a fixed artifact under `afp/reports/` plus a state-db row —
the same recording discipline as the seven-step research pipeline.

## Human Gates

Permanent, regardless of automation level: ASC app record creation + first
submission, pricing, kill decisions — plus spec approval upstream. Release
scripts are human/CI lanes; agents never run `archive`/`release` entrypoints
and never touch signing material (`Config/Signing.xcconfig` is gitignored;
only `.example` is committed).

## AFP Integration Status

Implemented (BuildRunner v0, `Afp.Factory.Builds`):

- `Builds.inspect_app_repo/1` — manifest reading + health verdict
  (`Factory.app_repo_health_states/0`); only `healthy` repos launch.
- `Builds.launch_packet/2` — takes a `ready` harness packet with a
  `repository_path`, records a `build_runs` row, marks the packet
  `launched`/`supervised`, runs the agent turn via the `Factory.AgentClient`
  behaviour (Codex or Claude Code, supervised under `CodexLaunchSupervisor`,
  `:build_launch_mode` sync/async), then executes `verify.entrypoint` via an
  Elixir Port (`Builds.VerifyRunner`), parses `verify.json`, ingests it as an
  evidence packet linked to the harness packet and ticket, and moves the
  packet to `review`.
- Board UI: a "Run agent" button on ready packets with a repository path.

Not yet implemented (next slices):

1. Settings registration of the app-template repo path + "new app from
   template" deterministic clone-and-scaffold action.
2. Live run activity display and a build-runs surface in the UI.
3. Stale-run reconciliation for build runs (mirror
   `reconcile_stale_running_research_runs`).
4. `afp/reports/*` per-milestone ingestion (today only `verify.json` lands as
   evidence).
