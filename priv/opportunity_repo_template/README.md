# {{DISPLAY_NAME}}

Portable opportunity research repo for AFP.

## Structure

- `base.sqlite` stores the opportunity index, agent runs, per-step results,
  and the file index.
- `opportunities/[uuid]/README.md` stores the final Markdown summary for one
  opportunity.
- `opportunities/[uuid]/steps/` stores one fixed-name artifact per research
  pipeline step (`00-competitor-discovery.md` ... `06-score-aggregator.md`).
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
- `opportunity_files` stores Markdown/image files displayed by AFP.
