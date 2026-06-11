# Build And Distribution Feasibility Harness (Step 5)

You are a Build And Distribution Feasibility Scoring Harness.

Task:
Score whether this opportunity can be built and distributed as a small first
app.

Inputs:
- Normalized opportunity: `steps/00-competitor-discovery.md`
- Wedge hypothesis: `steps/04-wedge-clarity.md`
- Competitors/substitutes: `steps/00-competitor-discovery.md`
- Known constraints: a one-person app factory; small, narrow first versions;
  any extra constraints stated in the launch prompt

Evidence to assess:
- MVP complexity
- platform/API difficulty
- regulatory risk
- trust burden
- dependency on network effects
- distribution channels
- App Store keyword/search entry
- community/SEO/GEO entry
- whether first version can complete one job

Output:
- score: 0-20
- evidence_strength
- build_feasibility
- distribution_feasibility
- hard_blockers
- first_version_boundary
- reasoning
- uncertainty
- next_route

Verification:
- Build score does not ignore distribution.
- High trust/legal/platform risk is flagged.
- A narrow first version is described.

## Artifact Contract

- Write the full output to `steps/05-build-distribution-feasibility.md` inside
  the opportunity directory.
- Record the step in `opportunity_step_results` using the upsert template in
  `AGENTS.md` -> Step Recording with:
  - `step_key = 'build_distribution_feasibility'`, `step_index = 5`
  - `score` = the 0-20 score
  - `evidence_strength` = missing / weak / medium / strong
  - `summary` = one-line feasibility conclusion
  - `artifact_path = 'steps/05-build-distribution-feasibility.md'`
  - `payload_json` = compact JSON with `score`, `evidence_strength`,
    `build_feasibility`, `distribution_feasibility`, `hard_blockers`,
    `first_version_boundary`, `reasoning`, `uncertainty`, `next_route`

## Evidence Materials (optional, max 3, 20-80 rule)

Worth keeping under `steps/05-build-distribution-feasibility/` (see
`AGENTS.md` -> Evidence Materials):

- a screenshot or note of app store / search results for the entry keywords
  (who currently ranks, how crowded)
- a note on the riskiest platform/API/regulatory dependency with its source

Keep only what changes the feasibility score or flags a hard blocker.
