---
name: opportunity-to-buildspec
description: Convert opportunity-research output (multi-step markdown research such as competitor discovery, demand proof, pain strength, incumbent weakness, wedge clarity, build/distribution feasibility, score aggregation) into a harness-engineering-ready product design spec package that an AI code agent can build to shippable quality without asking questions. Use this skill whenever the user wants to turn market/opportunity research, a validated product wedge, a "steps/" research folder, or a product idea with supporting evidence into a build spec, PRD, design package, agent brief, or development-ready requirements — even if they just say "把这个调研变成可以开发的 spec", "prepare this for the code agent", or "make this buildable".
---

# Opportunity Research → Agent-Ready Build Spec

## What this skill does

Take an opportunity-research folder (the input) and produce a **spec package** (the output): a directory of markdown files that together form a complete, verifiable contract for an AI code agent to build the product to shippable quality.

The governing principle is **harness engineering**: a code agent cannot ask the PM what they meant. Anything ambiguous will be guessed; anything unverifiable will drift. So every requirement in the package must answer two questions:

1. *What exactly is required?* (no interpretation needed)
2. *How will the agent know it's done correctly?* (an oracle: a test, a check, a measurable threshold, or an explicit "human review" flag)

The quality bar for the package is the **outsourcing test**: could a competent team that is *forbidden from asking questions* ship a store-quality product from these files alone? If not, the package is incomplete.

## Input format

Opportunity research typically arrives as a folder of step files, e.g.:

```
README.md                       — scores, route, normalized opportunity
steps/00-competitor-discovery.md (+ evidence subfolder)
steps/01-demand-proof.md
steps/02-pain-strength.md
steps/03-incumbent-weakness.md
steps/04-wedge-clarity.md       — wedge_segment, wedge_job, proposed_angle,
                                  smallest_complete_solution, non_goals
steps/05-build-distribution-feasibility.md — first version boundary, constraints
steps/06-score-aggregator.md
```

Field names and step counts vary. Do not depend on exact filenames — read everything in the folder and harvest by meaning, not by schema. If the input is a different shape (a single research doc, a memo, chat notes), harvest the same concepts from whatever is there.

## Workflow

### Step 1 — Harvest the research

Read the entire research folder, including evidence subfolders. Extract into working notes:

| Research concept | Feeds into |
|---|---|
| Wedge segment + wedge job ("the user hires this product to…") | goal.md, behavior spec |
| Smallest complete solution / MVP / first version boundary | goal.md scope, milestones |
| Non-goals, rejected wedges | goal.md non-goals (verbatim — these are hard-won) |
| Incumbent failures & complaint excerpts | behavior spec (what must NOT happen), copy tone |
| Trust/monetization constraints (e.g. "no trial mechanics, no analytics SDKs") | quality gates, data contract |
| Competitor profiles | UI contract references, quality bar |
| Pricing evidence | monetization decision in goal.md |
| Distribution constraints (ASO keywords, channels) | store listing copy, milestone 1 scope |
| Uncertainties & unproven assumptions | assumptions.md |
| Platform implied by the research (iOS? web? Android?) | platform gates throughout |

The research's *negative* knowledge is as valuable as the positive: rejected wedges, incumbent dark patterns to avoid, and explicit non-goals are the strongest defense against agent scope-drift. Carry them into the spec verbatim with their reasoning.

Determine the **target platform** from the research. If it cannot be inferred, ask the user — this is one of the few questions worth asking, because every quality gate depends on it.

### Step 2 — Gap analysis + supplemental research

Compare what you harvested against the package manifest (Step 3). Research output is strong on *why build* and *what wedge*, and almost always silent on: UI specifics, final copy, data schemas, pricing mechanics, platform review requirements, performance baselines.

For each gap, **research before assuming**:

- Competitor UI/UX patterns: fetch the competitor listings already cited in the research; note their screens, flows, paywall placement, review complaints about UX.
- Platform requirements: current store review guidelines, privacy-label rules, required disclosures for the app's category.
- Pricing: what the research's evidence supports (e.g. "users said they'd pay $2.99 once but not $36/yr" → one-time purchase).
- APIs/SDKs the product needs: confirm they exist, their pricing tier, and any policy constraints (e.g. privacy-preserving mode of a safety API).

What still can't be grounded after research becomes an **assumption** — written into `09-assumptions.md` with a risk level, never silently embedded in the spec as fact. The spec body states the decision; assumptions.md records that it was a guess and what evidence would change it.

Only escalate to the user for decisions that materially change the product and that research cannot settle (e.g. monetization model when evidence is ambiguous). Batch such questions; don't drip them.

### Step 3 — Generate the spec package

Create the package in a `spec/` directory (or where the user designates). The manifest:

```
spec/
├── AGENT_BRIEF.md            ← entry point; the code agent reads this first
├── 00-goal.md                ← product goal, DoD, non-goals, invariants
├── 01-positioning.md         ← wedge, segment, anti-patterns, competitor read
├── 02-behavior-spec.md       ← flows as scenarios + full edge-state matrix
├── 03-ui-contract.md         ← tokens, screens, components, references
├── 04-copy.md                ← ALL final copy, incl. store listing
├── 05-data-contract.md       ← schemas, API contracts, fixtures, privacy data map
├── 06-quality-gates.md       ← measurable NFR gates + platform release checklist
├── 07-verification-matrix.md ← requirement → oracle mapping (the harness core)
├── 08-milestones.md          ← phased goals, each with its own DoD
├── 09-assumptions.md         ← every guess, its risk, and its kill-test
└── prototype.html            ← clickable single-file HTML prototype of the whole app
```

Write the package in English (code agents and tooling work best in it) unless the user asks otherwise. Per-file requirements are in `references/spec-package-template.md` — **read it before writing the package**; it defines the required sections, formats, and worked examples for each file.

Build order matters: write `00-goal.md` and `02-behavior-spec.md` first, then derive `07-verification-matrix.md` from them, then fill the rest. The verification matrix is derived, not invented — if a requirement exists that you can't write an oracle for, either sharpen the requirement until it's checkable or explicitly mark it `human-review` with a rubric.

Build `prototype.html` last, after 02/03/04 are final, because it is their executable cross-check: a clickable, single-file HTML simulation of the whole app — every screen, fake data, working navigation, no real functionality. Building it forces latent contradictions to surface (a flow that doesn't connect, copy that doesn't fit the layout, a missing state); fix those in the spec files, not just in the prototype. See the template reference for its requirements.

### Step 4 — Self-check before delivering

Run the package through this checklist; fix failures rather than shipping them:

- **Outsourcing test**: no file says "TBD", "as appropriate", "etc.", or delegates a product decision to the implementer.
- **Oracle coverage**: every functional requirement and every quality gate appears in the verification matrix with a concrete oracle. Count them; report the coverage ratio.
- **Edge-state coverage**: every screen/flow in the behavior spec has its empty, loading, error, offline, permission-denied, and extreme-data states specified (or explicitly marked not-applicable with a reason).
- **Copy completeness**: every user-visible string in the behavior spec exists in copy.md. No lorem ipsum, no "[error message here]".
- **Prototype fidelity**: prototype.html opens standalone in a browser; every screen in 03's inventory is reachable by clicking; all visible strings match 04 verbatim; edge states are viewable (state switcher); styling uses 03's tokens.
- **Negative-space integrity**: every non-goal and constraint from the research survived into 00-goal.md.
- **Assumption honesty**: spot-check 3 specific claims in the spec body (a price, a threshold, a flow detail) — each is either traceable to research/supplemental evidence or listed in assumptions.md.
- **Traceability**: spec decisions that came from research evidence cite the source step file.

Deliver with a short summary: platform, milestone count, oracle coverage ratio, the top 3 highest-risk assumptions, and any questions deferred to the user.

## Judgment notes

- **Depth follows the research's route/score.** A "build now" opportunity deserves the full package. If the research routed the idea to a backup pool or flagged unresolved kill-risks, say so and confirm the user wants a build spec anyway — then write `09-assumptions.md` extra carefully, since the spec inherits unvalidated bets.
- **Don't pad.** A one-screen utility doesn't need a 40-page behavior spec. Completeness means covering the manifest and the edge matrix, not maximizing word count. Every sentence an agent must read but doesn't need is harness noise.
- **Final copy means final.** Writing real microcopy forces real product decisions (what *does* the error say when the safety API is down?). If you can't write the string, you haven't finished designing the behavior — go back to the behavior spec.
- **Milestones are independently shippable verification units**, not a work breakdown. Each milestone's DoD references specific verification-matrix rows that must pass. Milestone 1 should be the smallest thing a human could judge end-to-end.
