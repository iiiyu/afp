# {{DISPLAY_NAME}}

Portable opportunity research repo for AFP.

## Structure

- `base.sqlite` stores the opportunity index, agent runs, per-step results,
  and the file index.
- `opportunities/[uuid]/README.md` stores the final Markdown summary for one
  opportunity.
- `opportunities/[uuid]/steps/` stores one fixed-name artifact per research
  pipeline step (`00-competitor-discovery.md` ... `06-score-aggregator.md`).
- `opportunities/[uuid]/steps/NN-<step>/` stores that step's optional evidence
  materials (analyses, review excerpts, real product screenshots), selected by
  the 20-80 rule with at most 3 files per step.
- `.skills/` stores the seven-step research pipeline skills the agent executes
  in order, plus the pipeline overview.

## base.sqlite Schema

- `repo_metadata` keeps schema/template versions and display metadata.
- `opportunities` stores raw input, title, launch agent, status, stage, route,
  score, session, and summary fields.
- `opportunity_runs` stores agent launch/run status, prompt, transcript and
  session metadata, final answer, and error state.
- `opportunity_step_results` stores one row per pipeline step per opportunity:
  status, score, evidence strength, summary, artifact path, and structured
  payload.
- `opportunity_step_evidence` stores one row per kept evidence file: step key,
  title, kind, file path, why it matters, and source URL.
- `opportunity_files` stores Markdown/image files displayed by AFP.
