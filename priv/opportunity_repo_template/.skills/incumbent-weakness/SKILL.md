# Incumbent Weakness Harness (Step 3)

You are an Incumbent Weakness Scoring Harness.

Task:
Score whether existing solutions have clear weaknesses that create an opening.

Inputs:
- Competitors/substitutes: `steps/00-competitor-discovery.md`
- Review or source evidence: `steps/01-demand-proof.md` and
  `steps/02-pain-strength.md`

Evidence to find:
- pricing complaints
- subscription complaints
- bloated workflow
- poor UX
- missing export
- cloud dependency
- privacy concerns
- unreliable performance
- low rating with high usage
- underserved user segment

Output:
- score: 0-20
- evidence_strength
- weaknesses_by_competitor:
  - competitor
  - weakness
  - source
  - evidence summary
- cross_competitor_pattern
- reasoning
- uncertainty
- next_route

Verification:
- Weaknesses are evidence-backed.
- At least one weakness is tied to multiple users or competitors.
- Do not score high just because a competitor exists.

## Artifact Contract

- Write the full output to `steps/03-incumbent-weakness.md` inside the
  opportunity directory.
- Record the step in `opportunity_step_results` using the upsert template in
  `AGENTS.md` -> Step Recording with:
  - `step_key = 'incumbent_weakness'`, `step_index = 3`
  - `score` = the 0-20 score
  - `evidence_strength` = missing / weak / medium / strong
  - `summary` = one-line conclusion
  - `artifact_path = 'steps/03-incumbent-weakness.md'`
  - `payload_json` = compact JSON with `score`, `evidence_strength`,
    `weaknesses_by_competitor`, `cross_competitor_pattern`, `reasoning`,
    `uncertainty`, `next_route`

## Evidence Materials (optional, max 3, 20-80 rule)

Worth keeping under `steps/03-incumbent-weakness/` (see `AGENTS.md` ->
Evidence Materials):

- a per-competitor weakness note with quoted negative review excerpts
- a real screenshot showing the weakness in the product (bloated UX, missing
  export, paywall complaints on the listing)

Keep the evidence that ties one weakness to multiple users or competitors.
