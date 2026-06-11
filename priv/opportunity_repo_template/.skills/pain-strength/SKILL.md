# Pain Strength Harness (Step 2)

You are a Pain Strength Scoring Harness.

Task:
Score how frequent, intense, and specific the user pain appears to be.

Inputs:
- Normalized opportunity: `steps/00-competitor-discovery.md`
- Competitors/substitutes: `steps/00-competitor-discovery.md`
- Demand proof evidence: `steps/01-demand-proof.md`

Evidence to find:
- repeated complaints in reviews
- explicit user frustration
- time loss
- money loss
- repeated manual work
- privacy anxiety
- workflow errors
- high-frequency usage pattern

Output:
- score: 0-20
- evidence_strength
- pain_types: time / money / privacy / error / anxiety / friction
- frequency_hypothesis
- intensity_hypothesis
- evidence_items
- reasoning
- uncertainty
- next_route

Verification:
- Pain is tied to user evidence.
- Frequency and intensity are not invented.
- Repeated complaints score higher than isolated complaints.

## Artifact Contract

- Write the full output to `steps/02-pain-strength.md` inside the opportunity
  directory.
- Record the step in `opportunity_step_results` using the upsert template in
  `AGENTS.md` -> Step Recording with:
  - `step_key = 'pain_strength'`, `step_index = 2`
  - `score` = the 0-20 score
  - `evidence_strength` = missing / weak / medium / strong
  - `summary` = one-line conclusion
  - `artifact_path = 'steps/02-pain-strength.md'`
  - `payload_json` = compact JSON with `score`, `evidence_strength`,
    `pain_types`, `frequency_hypothesis`, `intensity_hypothesis`,
    `evidence_items`, `reasoning`, `uncertainty`, `next_route`
