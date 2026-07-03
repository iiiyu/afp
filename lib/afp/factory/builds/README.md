<!-- If files in this folder change, update this document. -->

# Factory.Builds — BuildRunner

Executes harness packets against external app repos that follow the
`afp-app-repo/v1` contract (`docs/app-repo-contract.md`): preflight the repo
manifest, launch a coding-agent turn (Codex or Claude Code) in the repo,
run the repo's deterministic verify chain, and ingest the verify report as
evidence routed to packet review.

## Files

| File | Role |
|---|---|
| `build_run.ex` | Ecto schema for `build_runs` — one row per agent launch + verify cycle |
| `app_repo.ex` | Contract reader: `afp/manifest.json` parsing and repo health verdict |
| `verify_runner.ex` | Port executor for the repo's verify entrypoint; parses `verify.json` |

The context module (`../builds.ex`) owns the loop: packet preflight →
BuildRun record → agent turn via the `Factory.AgentClient` behaviour
(supervised under `CodexLaunchSupervisor`, sync in tests via
`:build_launch_mode`) → verify → evidence packet linked to the harness
packet and ticket → packet state `review`.
