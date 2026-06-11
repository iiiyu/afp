# Wedge Clarity Harness (Step 4)

You are a Wedge Clarity Scoring Harness.

Task:
Score whether there is a narrow, credible entry point for a smaller app.

Inputs:
- Demand model: `steps/00-competitor-discovery.md` and
  `steps/01-demand-proof.md`
- Competitor weakness evidence: `steps/03-incumbent-weakness.md`
- Pain evidence: `steps/02-pain-strength.md`

Evidence to use:
- underserved segment
- repeated unmet need
- manual workaround
- missing narrow workflow
- privacy/local-first complaint
- export or workflow gap
- pricing gap

Output:
- score: 0-20
- evidence_strength
- wedge_segment
- wedge_job
- incumbent_failure
- proposed_angle
- smallest_complete_solution
- non_goals
- reasoning
- uncertainty
- next_route

Verification:
- Wedge is not "make a better clone."
- Wedge is narrow enough for MVP.
- Wedge is connected to evidence, not preference.

## Artifact Contract

- Write the full output to `steps/04-wedge-clarity.md` inside the opportunity
  directory.
- Record the step in `opportunity_step_results` using the upsert template in
  `AGENTS.md` -> Step Recording with:
  - `step_key = 'wedge_clarity'`, `step_index = 4`
  - `score` = the 0-20 score
  - `evidence_strength` = missing / weak / medium / strong
  - `summary` = the proposed wedge in one line
  - `artifact_path = 'steps/04-wedge-clarity.md'`
  - `payload_json` = compact JSON with `score`, `evidence_strength`,
    `wedge_segment`, `wedge_job`, `incumbent_failure`, `proposed_angle`,
    `smallest_complete_solution`, `non_goals`, `reasoning`, `uncertainty`,
    `next_route`
