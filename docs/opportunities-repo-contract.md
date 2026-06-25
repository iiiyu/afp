<!-- If files in this folder change, update this document. -->

# Opportunities Repo Contract

AFP's primary discovery surface is `/opportunities`. It points at one local,
portable opportunity repo and stores only the configured repo path in AFP's
PostgreSQL `settings` table. The repo itself owns opportunity state through
`base.sqlite` plus Markdown artifacts.

## Required Structure

```text
base.sqlite
opportunities/
  [uuid]/
    README.md
    steps/
      NN-<step>.md
      NN-<step>/        (optional per-step evidence materials)
    spec/               (post-research PRD/spec package)
AGENTS.md
CLAUDE.md
.skills/
  opportunity-research/SKILL.md
  competitor-discovery/SKILL.md
  demand-proof/SKILL.md
  pain-strength/SKILL.md
  incumbent-weakness/SKILL.md
  wedge-clarity/SKILL.md
  build-distribution-feasibility/SKILL.md
  score-aggregator/SKILL.md
  opportunity-to-buildspec/SKILL.md
```

`AGENTS.md` is the canonical entrypoint for the research agent (Codex or
Claude Code); `CLAUDE.md` only points to it so Claude Code picks it up
automatically. If an existing repo has a misspelled `AGENETS.md`, AFP reports
it in health notes and expects the file to be renamed before the repo can
become healthy.

All of these files are AFP-owned template files (template version 6). The
repo template source lives in `priv/opportunity_repo_template/`.

## Research Pipeline

Every opportunity is researched through seven ordered steps. Each step is its
own skill, produces one fixed-name artifact under the opportunity's `steps/`
directory, and records one row in `opportunity_step_results`:

| # | step_key | Artifact | Score |
|---|----------|----------|-------|
| 0 | `competitor_discovery` | `steps/00-competitor-discovery.md` | none |
| 1 | `demand_proof` | `steps/01-demand-proof.md` | 0-20 |
| 2 | `pain_strength` | `steps/02-pain-strength.md` | 0-20 |
| 3 | `incumbent_weakness` | `steps/03-incumbent-weakness.md` | 0-20 |
| 4 | `wedge_clarity` | `steps/04-wedge-clarity.md` | 0-20 |
| 5 | `build_distribution_feasibility` | `steps/05-build-distribution-feasibility.md` | 0-20 |
| 6 | `score_aggregator` | `steps/06-score-aggregator.md` | 0-100 total |

Step 0 rewrites the opportunity `title` with the normalized opportunity so
the list view reads like a product hypothesis instead of the raw input. Step
6 rewrites the opportunity `README.md` as the final summary and updates the
`opportunities` row with the final `title`, `total_score`, `route`, and
`latest_summary`. There is no `generated_other_files/` directory; every
artifact has a fixed name.

## Build Spec / PRD Package

Once the seven-step research run completes and the opportunity status is
`researched`, AFP can launch a separate `build_spec` run using the same selected
agent. That run follows `.skills/opportunity-to-buildspec/SKILL.md`, reads the
completed `README.md`, step artifacts, and evidence materials, and writes the
agent-ready product package under `opportunities/[uuid]/spec/`.

Build-spec runs do not rerun scoring, create app repositories, promote
opportunities, or modify the step result rows. A successful build-spec run moves
the opportunity to `build_spec_ready`; a failed build-spec run leaves the
opportunity `researched` so the operator can retry.

## Evidence Materials

Beyond its main artifact, each step may keep supporting evidence files —
competitor analyses, pros/cons notes, review excerpt compilations, and real
product screenshots — under its own `steps/NN-<step>/` directory. Selection
follows the 20-80 rule: only the most decision-relevant ~20% of encountered
materials, with a hard cap of 3 files per step, in Markdown or image formats
(the only formats AFP previews). Every kept file is linked from the step's
main artifact and registered in `opportunity_step_evidence` with a title, a
kind (`analysis` / `screenshot` / `source_excerpt`), why it matters, and its
source URL. Screenshots must be real; fabricated evidence is forbidden.

## Health Rules

AFP marks a configured repo `healthy` when:

- `base.sqlite` exists and contains the required tables (including
  `opportunity_step_results`).
- `opportunities/` exists.
- `AGENTS.md` exists.
- `.skills/` exists.

Missing `base.sqlite` is reported as `sqlite_missing`. Missing `AGENTS.md` is
reported as `agents_missing`. Other missing structural paths are reported as
`invalid_structure`. A repo without `.git/` can still be used, but new repos
initialized from AFP run `git init`.

## Automatic In-Place Upgrade

When AFP inspects a configured repo whose `base.sqlite` holds the core tables,
it automatically and non-destructively upgrades the repo:

- adds the v2 `agent` columns when missing,
- creates the v3 `opportunity_step_results` and v4 `opportunity_step_evidence`
  tables when missing,
- when `repo_metadata.template_version` is missing or older than the current
  template, overwrites all AFP-owned template files (`AGENTS.md`, `CLAUDE.md`,
  `README.md`, `.gitignore`, everything under `.skills/`) and records the new
  `schema_version`/`template_version`.

Opportunity folders under `opportunities/` are never touched by upgrades.

## base.sqlite

The repo-local SQLite database is intentionally portable and small
(schema version 4):

- `repo_metadata` - schema version, template version, display name, and repo
  metadata.
- `opportunities` - one row per opportunity with raw input, title, source URL,
  launch agent (`codex` or `claude_code`), status, stage, route, total score,
  active run, agent session, latest summary, error, and timestamps.
- `opportunity_runs` - one row per agent launch/run with launch agent, prompt,
  run type (`initial_research` or `build_spec`), status, stage,
  session/thread/turn metadata, transcript path, final answer, error, payload,
  and timestamps.
- `opportunity_step_results` - one row per pipeline step per opportunity
  (UNIQUE on opportunity_id + step_key): run id, step key/index, status
  (`pending` / `completed` / `failed`), score, evidence strength, one-line
  summary, artifact path (relative to the opportunity dir), structured
  payload, and timestamps. AFP pre-seeds all seven rows as `pending` at
  launch; the agent upserts each row as it completes a step.
- `opportunity_step_evidence` - one row per kept evidence file (UNIQUE on
  opportunity_id + file_path): run id, step key, title, kind, file path
  (relative to the opportunity dir), why it matters, source URL, and
  timestamps.
- `opportunity_files` - Markdown/image file index for AFP's detail browser,
  with repo-relative path, file type, size, and mtime.

## Agent Launch Boundary

When AFP creates a new opportunity from a simple input, it:

1. Generates a UUID and creates `opportunities/[uuid]/README.md` plus an empty
   `opportunities/[uuid]/steps/` directory.
2. Inserts the opportunity, a queued run, and seven pending step rows into
   `base.sqlite` with the selected launch agent.
3. Starts the selected agent with the opportunity repo as `cwd`: either a Codex
   app-server turn (JSON-RPC over stdio) or a Claude Code headless run
   (`claude -p <prompt> --output-format stream-json`).
4. Restricts writes to `opportunities/`, `.skills/`, and `base.sqlite` — via
   the Codex sandbox policy or Claude Code permission allow/deny rules.
5. Updates `base.sqlite` as the agent reaches session, turn, completed, or
   failed states; the agent itself records per-step progress in
   `opportunity_step_results` and kept evidence files in
   `opportunity_step_evidence`.

When AFP launches build-spec generation for a researched opportunity, it creates
a fresh `opportunity_runs` row with `run_type = 'build_spec'`, starts the same
Codex/Claude Code launch machinery with a prompt that names the build-spec
skill, and expects generated files only under `opportunities/[uuid]/spec/`.
