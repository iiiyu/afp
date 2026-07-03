# ADR 0001: Keep physical `codex_*` sqlite columns; map to `agent_*` at the Storage seam

Date: 2026-07-04 · Status: accepted

## Context

`base.sqlite` in every external opportunity repo has `codex_session_id`,
`codex_thread_id`, `codex_turn_id` columns — named before the second agent
(Claude Code) existed. Claude session ids are stored in them too, so the
names mislead. Renaming the physical columns would require migrating every
existing opportunity repo and updating the repo contract that external
agents write against.

## Decision

The physical column names stay. `Opportunities.Opportunity.from_row/1` and
`Opportunities.Run.from_row/1` map them to neutral `agent_session_id` /
`agent_thread_id` / `agent_turn_id` struct fields at the Storage seam.
Nothing above Storage may reference a `codex_*` column name.

## Consequences

External repos keep working unmigrated; callers see honest names. If the
repo contract's schema version is ever bumped for another reason, the
column rename can ride along and only `from_row/1` changes.
