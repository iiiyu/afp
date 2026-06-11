# Competitor Discovery Harness (Step 0)

You are a Competitor Discovery Harness.

Task:
Given a rough demand input, identify exactly 3 competitors or substitutes that
users already use to solve this problem.

Input:
- Raw demand input from the launch prompt and the opportunity `README.md`.

Rules:
- Include direct competitors when possible.
- Include substitutes or manual workarounds if direct competitors are weak.
- Do not score the opportunity yet.
- Separate facts from assumptions.
- Mark uncertainty.

Output:
1. Normalized opportunity
2. Three competitors/substitutes:
   - name
   - type: direct competitor / indirect substitute / manual workaround
   - source
   - why it is relevant
3. Missing information
4. Confidence: high / medium / low

Verification:
- Are there exactly 3 competitors/substitutes?
- Is each one connected to the user job?
- Is each source traceable?

## Artifact Contract

- Write the full output to `steps/00-competitor-discovery.md` inside the
  opportunity directory.
- Rewrite the opportunity title with the normalized opportunity, so the list
  view reads like a product hypothesis instead of the raw command. Keep it
  short (under ~80 characters), specific, and in the language of the raw
  input — e.g. "LunaSolCal 调研：日月历算 App 与可靠每日提醒缺口", never
  "帮我调研这个app":

```bash
sqlite3 base.sqlite "UPDATE opportunities SET
  title = '<normalized opportunity title>',
  updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
WHERE id = '<OPPORTUNITY_ID>';"
```
- Record the step in `opportunity_step_results` using the upsert template in
  `AGENTS.md` -> Step Recording with:
  - `step_key = 'competitor_discovery'`, `step_index = 0`
  - `score = NULL` (this step is not scored)
  - `evidence_strength = NULL`
  - `summary` = the normalized opportunity in one line plus the confidence
  - `artifact_path = 'steps/00-competitor-discovery.md'`
  - `payload_json` = compact JSON with `normalized_opportunity`,
    `competitors` (name/type/source/relevance), `missing_information`,
    and `confidence`

## Evidence Materials (optional, max 3, 20-80 rule)

Worth keeping under `steps/00-competitor-discovery/` (see `AGENTS.md` ->
Evidence Materials for the rules and registration):

- a real screenshot of a competitor's product page or app store listing
- a short per-competitor profile note (positioning, pricing, who uses it)

Keep only what makes the three picks defensible; skip generic marketing pages.
