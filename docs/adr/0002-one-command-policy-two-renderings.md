# ADR 0002: One command-safety policy, rendered per transport

Date: 2026-07-04 · Status: accepted

## Context

The command-safety rules (safe read commands, destructive command patterns)
existed twice in different formats: Codex approval markers in
`CodexAppClient` and `Bash(...)` allow/deny rules in `ClaudeCodeClient`.
The two lists had drifted — `sudo` and `git push` were denied for Claude
but not for Codex.

## Decision

`AgentClient.CommandPolicy` is the single source of the vocabulary. Codex
consumes it as predicates (`destructive?/1`, `safe_read?/1`) inside the pure
`AgentClient.Approvals` engine; Claude Code consumes it rendered as CLI
permission rules (`claude_allow_rules/1`, `claude_deny_rules/0`). The
unification also closed the drift: `sudo` and `git push` are now denied on
both transports.

## Consequences

A policy change is one edit that applies to both agents, and the approval
engine is testable through its own interface (table-driven, no Port).
Per-launch extra allowances travel as `Request.extra_command_allow`.
