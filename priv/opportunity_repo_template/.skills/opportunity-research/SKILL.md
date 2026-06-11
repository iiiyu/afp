# Opportunity Research Pipeline

Use this skill when AFP gives a simple demand input, idea, need, or URL and
asks the research agent to create or update one opportunity folder.

## Workflow

Execute the seven step skills in order. Each step reads the artifacts of the
earlier steps, writes its own fixed-name artifact under the opportunity's
`steps/` directory, and records its row in `opportunity_step_results` (see
`AGENTS.md` -> Step Recording).

```
Simple Input
-> 0. Competitor Discovery        (.skills/competitor-discovery)
-> 1. Demand Proof                (.skills/demand-proof)
-> 2. Pain Strength               (.skills/pain-strength)
-> 3. Incumbent Weakness          (.skills/incumbent-weakness)
-> 4. Wedge Clarity               (.skills/wedge-clarity)
-> 5. Build & Distribution        (.skills/build-distribution-feasibility)
-> 6. Score Aggregator / Route    (.skills/score-aggregator)
```

## Input Flow Between Steps

- Step 0 consumes the raw demand input from the launch prompt and the
  opportunity `README.md`.
- Steps 1-5 consume the raw input plus the artifacts of the earlier steps;
  each step skill lists exactly which earlier artifacts it reads.
- Step 6 consumes the five scored artifacts (steps 1-5), writes the final
  route, updates the opportunity `README.md`, and updates the `opportunities`
  row in `base.sqlite`.

## Unified Scoring Caps

- No evidence = max 5/20
- Weak evidence = max 10/20
- Medium evidence = max 15/20
- Strong evidence = max 20/20

If evidence is missing, do not guess. Mark unknown.

## Hard Rules

- Never skip, merge, or reorder steps.
- Every step writes its artifact before its sqlite row.
- Separate facts from assumptions in every artifact.
- Stop the pipeline and record `status = 'failed'` for a step you cannot
  complete honestly.
