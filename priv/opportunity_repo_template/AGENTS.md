# {{DISPLAY_NAME}} Agent Instructions

This repository is an AFP opportunities repo. AFP owns the control-plane UI and
launches research agent runs (Codex or Claude Code). This repo owns portable
opportunity evidence, fixed-name step artifacts, and the repo-local
`base.sqlite` index.

## Required Structure

- `base.sqlite` - repo-local SQLite index for opportunities, runs, step
  results, and files
- `opportunities/[uuid]/README.md` - final opportunity summary
- `opportunities/[uuid]/steps/` - one fixed-name artifact per pipeline step
- `.skills/` - the research pipeline skills listed below

## Read Order

1. `AGENTS.md` (this file)
2. `.skills/opportunity-research/SKILL.md` (pipeline overview)
3. The target `opportunities/[uuid]/README.md`
4. Each step skill, in pipeline order, as you execute it

## Research Pipeline

Execute the seven steps below in order for every opportunity. Each step has its
own skill, its own fixed-name artifact, and its own row in
`opportunity_step_results`. Never skip a step and never reorder steps.

| # | Skill | Artifact (relative to opportunity dir) | step_key | Score |
|---|-------|----------------------------------------|----------|-------|
| 0 | `.skills/competitor-discovery/SKILL.md` | `steps/00-competitor-discovery.md` | `competitor_discovery` | none |
| 1 | `.skills/demand-proof/SKILL.md` | `steps/01-demand-proof.md` | `demand_proof` | 0-20 |
| 2 | `.skills/pain-strength/SKILL.md` | `steps/02-pain-strength.md` | `pain_strength` | 0-20 |
| 3 | `.skills/incumbent-weakness/SKILL.md` | `steps/03-incumbent-weakness.md` | `incumbent_weakness` | 0-20 |
| 4 | `.skills/wedge-clarity/SKILL.md` | `steps/04-wedge-clarity.md` | `wedge_clarity` | 0-20 |
| 5 | `.skills/build-distribution-feasibility/SKILL.md` | `steps/05-build-distribution-feasibility.md` | `build_distribution_feasibility` | 0-20 |
| 6 | `.skills/score-aggregator/SKILL.md` | `steps/06-score-aggregator.md` | `score_aggregator` | 0-100 total |

Every step MUST:

1. Write its artifact to the fixed path above. The artifact is the full
   structured output of the step, in Markdown.
2. Record its result in `opportunity_step_results` using the Step Recording
   contract below, immediately after the artifact is written.

## Step Recording

AFP pre-seeds one `pending` row per step when it launches the run. After each
step, upsert that row (replace the placeholders; keep `score` as `NULL` for
step 0):

```bash
sqlite3 base.sqlite "INSERT INTO opportunity_step_results
  (id, opportunity_id, run_id, step_key, step_index, status, score,
   evidence_strength, summary, artifact_path, payload_json, created_at, updated_at)
VALUES
  (lower(hex(randomblob(16))), '<OPPORTUNITY_ID>', '<RUN_ID>', '<step_key>',
   <step_index>, 'completed', <score-or-NULL>, '<missing|weak|medium|strong>',
   '<one-line summary>', '<artifact path>', '<compact JSON output>',
   strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'))
ON CONFLICT(opportunity_id, step_key) DO UPDATE SET
  run_id = excluded.run_id,
  status = excluded.status,
  score = excluded.score,
  evidence_strength = excluded.evidence_strength,
  summary = excluded.summary,
  artifact_path = excluded.artifact_path,
  payload_json = excluded.payload_json,
  updated_at = excluded.updated_at;"
```

If a step cannot be completed, record it with `status = 'failed'` and explain
why in `summary`, then stop the pipeline.

## Core Rules

- Work only inside the target opportunity directory and `base.sqlite` unless
  AFP explicitly asks for repo-wide edits.
- Keep `validation-ready`, `validation-sprint`, `build-ready`, backup, and
  reject decisions distinct.
- Evidence caps apply to every score: no evidence means a maximum of 5/20,
  weak evidence means a maximum of 10/20, medium evidence means a maximum of
  15/20, strong evidence can reach 20/20.
- If evidence is missing, mark it unknown instead of guessing.
- Do not turn a demand signal into a broad clone. Narrow to one credible
  wedge, packet, artifact, workflow, or first version.
- When updating `base.sqlite`, use the existing schema and keep paths relative
  to the repo root (artifact paths are relative to the opportunity dir).
