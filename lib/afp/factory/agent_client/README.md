<!-- If files in this folder change, update this document. -->

# AgentClient Seam Modules

## Architecture Summary

Shared modules behind the `Afp.Factory.AgentClient` behaviour (defined in
`../agent_client.ex` together with the `Request`/`Result`/`Error` structs).
Both transports — Codex app-server and the Claude Code CLI — consume these,
so policy changes land once and apply to both.

## File Inventory

- `approvals.ex` - Pure approval engine: `profile/1` derives launch bounds,
  `decide_command/2`, `decide_file_change/2`, and `decide_permissions/2`
  return `{decision, reason}` verdicts. Tested directly, no transport needed.
- `command_policy.ex` - The command-safety vocabulary (safe reads,
  destructive patterns) rendered per transport: Codex approval predicates
  and Claude Code `Bash(...)` allow/deny rules.
