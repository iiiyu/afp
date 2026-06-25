# Spec Package Template — per-file requirements

Each section below defines one file of the package: its purpose, required sections, and format notes with short examples. Examples use a hypothetical "safety-first QR scanner" product; adapt freely — the *structure* is the contract, not the example content.

## AGENT_BRIEF.md

The code agent's entry point — what a CLAUDE.md/AGENTS.md would say about this project before any code exists. Keep it under one page.

Required content:

- One-paragraph product statement (from 00-goal.md).
- Reading order for the package and what each file governs.
- The three operating rules for the implementing agent:
  1. The verification matrix (07) is the definition of done — a milestone is complete only when its referenced rows pass.
  2. Non-goals and invariants in 00 are hard constraints — never implement around them, never "improve" past them.
  3. When the spec is silent, check 09-assumptions.md; if still silent, choose the simplest behavior consistent with 01-positioning.md and record the decision in a DECISIONS.md file rather than asking or guessing silently.
- Tech constraints that bound implementation choices (platform, minimum OS version, forbidden dependencies such as analytics/ad SDKs, API budget).

## 00-goal.md

Required sections:

### Goal
One sentence: segment + job + differentiator. Derived from wedge_segment + wedge_job.

### Definition of Done (release-level)
Measurable, binary conditions. Each becomes a verification-matrix row.

> - All Milestone 1–3 verification rows pass.
> - Cold start to scan-ready camera < 1.5s on the oldest supported device.
> - Zero third-party analytics or advertising SDKs in the dependency tree.
> - App Store review passed; privacy nutrition label shows "Data Not Collected".

### Non-Goals
Verbatim from the research, with the reasoning, plus any new exclusions. Format: `- **No X** — because Y (source: steps/04).` Non-goals without reasons get "improved" away by agents.

### Invariants
Things that must remain true through every milestone and refactor (e.g. "no network call before the user sees the verdict-pending state", "history never leaves the device"). Invariants differ from DoD: DoD is checked at release; invariants are checked continuously and belong in CI where possible.

## 01-positioning.md

Required sections: **Wedge** (segment, job, angle — condensed from research); **Competitor read** (table: competitor → what they do well → the failure we exploit → what we must NOT copy); **Anti-patterns** (the incumbent behaviors the research documented as user pain — each phrased as a testable prohibition, e.g. "no paywall before first successful core action"); **Quality bar** (named reference apps and which specific aspect of each is the bar, e.g. "settings screen simplicity: match Things 3").

This file exists so the agent makes *on-positioning* micro-decisions without asking. Every anti-pattern here should also appear as a row in 07.

## 02-behavior-spec.md

The largest file. Two parts:

### Part A — Flows as scenarios

Every user flow written as Given/When/Then scenarios, grouped by flow. Name scenarios with stable IDs (`F1-S3`) so the verification matrix and tests can reference them.

> **F1: Scan → verdict → open**
> - F1-S1 Given camera permission granted, when a QR encoding an https URL enters the frame, then decode within 500ms and show the verdict-pending card.
> - F1-S2 Given the safety API responds "safe" within 2s, then show the Safe verdict card with the final post-redirect URL and an Open button.
> - F1-S3 Given the safety API is unreachable, then show the Unverified verdict (copy: see 04 §errors.api_down), never a silent pass-through open.

Include the *prohibited* behaviors as scenarios too ("then the app must NOT…") — these encode the anti-patterns.

### Part B — Edge-state matrix

One table per screen. Columns: state (empty / loading / error / offline / permission-denied / extreme data) → specified behavior → copy reference. Every cell is either specified or `n/a + reason`. This matrix is mandatory: it is the single biggest gap between agent-default output and shippable quality.

## 03-ui-contract.md

Required sections:

- **Design tokens** as a code block (color roles incl. dark mode, type scale, spacing scale, radius, motion durations). Tokens are decisions, not suggestions; pick real values.
- **Screen inventory**: every screen with layout described structurally (regions, components, hierarchy) — precise enough to build without a mockup. If reference screenshots/mockups exist, link them as visual-regression baselines.
- **Component sources**: platform-native components by default; list each custom component with the reason native can't do it.
- **Interaction standards**: touch-target minimums, haptics, animation policy, accessibility behaviors (Dynamic Type, VoiceOver labels per screen).

## 04-copy.md

ALL user-visible strings, keyed, grouped by screen/flow, referenced from 02 and 03. Includes: onboarding, buttons, verdict/result cards, every error and empty state, permission-priming dialogs, paywall/purchase copy, settings, and the **store listing** (app name ≤30 chars, subtitle ≤30 chars, keyword field, description, what's-new) plus review-prompt policy. Write in the product's voice (define it in 3 adjectives at the top). No placeholders.

## 05-data-contract.md

Required sections: **Entities & schemas** (local models with field types); **External APIs** (per API: endpoint/SDK, auth, request/response examples, rate limits, cost tier, failure modes, timeout policy); **Fixtures** (test data the agent can use: sample QR payloads incl. malicious-pattern examples, mock API responses for each verdict class); **Privacy data map** (every datum collected/processed → where it goes → retention → which store-privacy-label entry it implies). The privacy map must be consistent with 00's invariants.

## 06-quality-gates.md

Each gate: metric, threshold, measurement method. Group: **Performance** (launch time, interaction latency, memory, binary size), **Reliability** (crash-free target, core-action success rate), **Accessibility** (e.g. all text passes WCAG AA contrast, full VoiceOver pass), **Privacy/Trust** (dependency audit: zero analytics SDKs; network audit: no calls except listed APIs), **Platform release checklist** (the store's current review requirements relevant to this category — researched, not remembered). Every gate is a verification-matrix row.

## 07-verification-matrix.md

The harness core. One table:

| ID | Requirement (source) | Oracle type | Oracle |
|----|----------------------|-------------|--------|
| V1 | F1-S2 safe verdict flow (02) | UI test | XCUITest: mock API "safe" → verdict card visible, Open enabled |
| V9 | No network before consent (00 invariant) | automated audit | proxy capture during onboarding shows zero requests |
| V14 | Verdict card visual quality (03) | human-review | rubric: matches token spec; screenshot review checklist §3 |

Rules: oracle types are `unit`, `UI test`, `automated audit`, `manual script` (exact human steps), or `human-review` (with rubric). Every scenario ID from 02, every gate from 06, every invariant and anti-pattern must appear. End the file with the coverage tally (e.g. "41 requirements / 41 oracles; 6 human-review").

## 08-milestones.md

3–5 milestones. Per milestone: **Goal** (one sentence), **Scope** (in/out), **DoD** (list of verification-matrix IDs that must pass), **Demo script** (what a human does to judge it end-to-end in under 5 minutes). Milestone 1 = thinnest end-to-end slice of the core job. Last milestone = release hardening (the 06 gates + store checklist).

## 09-assumptions.md

One table: assumption → where used → risk (high/med/low) → kill-test (the cheapest check that would confirm or refute it). High-risk assumptions that touch monetization or the core wedge get called out in the delivery summary.

> | Price point $4.99 one-time | 04 paywall copy, 08 M3 | high | landing-page test from research's next-action plan |

## prototype.html

A clickable simulation of the entire app in ONE self-contained HTML file — the executable rendering of 02 + 03 + 04. It is a behavioral mockup, not an implementation: fake data and screen navigation only, zero real functionality (no network calls, no persistence beyond in-memory JS, no real auth/payment/API).

Requirements:

- **Self-contained**: inline CSS + vanilla JS, opens from a double-click with no server, no build step, no external dependencies (a CDN font is the only exception allowed).
- **Complete screen coverage**: every screen in 03's inventory exists and is reachable by clicking through the app the way a user would. Screens are sections/`div`s toggled by JS, styled with 03's design tokens as CSS variables. If the product is mobile, render inside a phone-frame container.
- **Verbatim copy**: every visible string comes from 04 by key — the prototype is where copy-vs-layout collisions are discovered. Don't paraphrase.
- **Fake data from fixtures**: seed the UI with 05's fixtures (realistic names, amounts, payloads — including one extreme-data example, e.g. the longest plausible string).
- **Edge states demonstrable**: a small floating dev panel (clearly styled as non-product chrome) lets the reviewer switch the current screen between its states from 02's edge matrix — empty / loading / error / offline / etc. Every specified state must be viewable; this makes the edge matrix reviewable by humans in minutes.
- **Simulated waits**: where the spec defines latency-dependent behavior (loading → verdict, send → confirmation), simulate with `setTimeout` using the thresholds from 06 so the pacing feels real.
- **Honest seams**: actions the real app performs but the prototype can't (open external URL, send email, charge money) end in a clearly-labeled simulated result (e.g. a toast "would open https://… here"), never a dead button.

Role in the harness: the prototype is the human-reviewable oracle for UX decisions — reference it from 07 rows of type `human-review` ("matches prototype.html screen X in state Y") and use it as the demo vehicle for 08's milestone demo scripts before real builds exist. Where prototype and spec text disagree, the spec files win; fix the prototype.
