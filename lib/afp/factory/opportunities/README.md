<!-- If files in this folder change, update this document. -->

# Opportunities Helpers

## Architecture Summary

This folder holds helper modules for the `Afp.Factory.Opportunities` context.
The context keeps AFP's configured opportunity repo path in settings while the
portable opportunity index, run state, per-step results, and file inventory
live in the external repo's `base.sqlite`. Opportunity research runs launch
through one of two agents: the Codex app-server client (in `../demand/`) or
the Claude Code CLI client in this folder. The agent executes the seven-step
research pipeline declared by the repo template, whose source files live in
`priv/opportunity_repo_template/` (scaffolded for new repos and automatically
rewritten in place for outdated repos).

## File Inventory

- `../opportunities.ex` - Opportunity repo scaffold from the priv template,
  health inspection with automatic in-place upgrades, `base.sqlite`
  reads/writes (opportunities, runs, step results), and bounded agent launch
  progress for Codex and Claude Code.
- `files.ex` - File-browser concern for opportunity repos: walks the repo for
  Markdown/image files, classifies them, refreshes the `opportunity_files`
  index in `base.sqlite`, and reads a single file (text or base64 image) with a
  path-escape guard.
- `claude_code_client.ex` - Port-based adapter that runs
  `claude -p <prompt> --output-format stream-json` headlessly inside the
  opportunity repo, maps the init/result stream events onto the shared launch
  envelope, emits live `:activity` launch events (assistant text, tool calls,
  tool errors) for the detail-page feed, and bounds writes with Claude Code
  permission allow/deny rules.
