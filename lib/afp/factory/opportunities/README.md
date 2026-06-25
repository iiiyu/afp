<!-- If files in this folder change, update this document. -->

# Opportunities Helpers

## Architecture Summary

This folder holds helper modules for the `Afp.Factory.Opportunities` context.
The context keeps AFP's configured opportunity repo path in settings while the
portable opportunity index, run state, per-step results, and file inventory
live in the external repo's `base.sqlite`. Repo setup/health and all
`base.sqlite` SQL sit behind internal modules so the context, file browser, and
agent-run launcher do not each own table details. Opportunity research runs
launch through one of two agents: the Codex app-server client (in `../demand/`)
or the Claude Code CLI client in this folder. The agent executes the seven-step
research pipeline declared by the repo template, whose source files live in
`priv/opportunity_repo_template/` (scaffolded for new repos and automatically
rewritten in place for outdated repos).

## File Inventory

- `../opportunities.ex` - Public context interface for configured repo
  selection, opportunity creation/relaunch, file reads, and research-step reads.
- `repo_contract.ex` - Portable repo scaffold, health inspection, automatic
  in-place upgrade, and AFP-owned template file refresh.
- `storage.ex` - Single storage interface for `base.sqlite` reads/writes:
  opportunities, runs, step results, step evidence, file index rows, and
  agent-run state transitions.
- `storage_schema.ex` - Schema creation, schema inspection, metadata, and
  versioned table-upgrade SQL for `base.sqlite`.
- `files.ex` - File-browser concern for opportunity repos: walks the repo for
  Markdown/image files, classifies them, delegates `opportunity_files` index
  writes to storage, and reads a single file (text or base64 image) with a
  path-escape guard.
- `agent_run.ex` - Agent-run launch orchestration: runs a queued research turn
  through Codex or the Claude Code client, synchronously or under a
  Task.Supervisor, delegates run/opportunity state transitions (started,
  progress, success, failure) to storage, and emits factory events.
- `claude_code_client.ex` - Port-based adapter that runs
  `claude -p <prompt> --output-format stream-json` headlessly inside the
  opportunity repo, maps the init/result stream events onto the shared launch
  envelope, emits live `:activity` launch events (assistant text, tool calls,
  tool errors) for the detail-page feed, and bounds writes with Claude Code
  permission allow/deny rules.
