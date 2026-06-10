<!-- If files in this folder change, update this document. -->

# Opportunities Helpers

## Architecture Summary

This folder holds helper modules for the `Afp.Factory.Opportunities` context.
The context keeps AFP's configured opportunity repo path in settings while the
portable opportunity index, run state, and file inventory live in the external
repo's `base.sqlite`. Opportunity research runs launch through one of two
agents: the Codex app-server client (in `../demand/`) or the Claude Code CLI
client in this folder.

## File Inventory

- `../opportunities.ex` - Opportunity repo scaffold, health inspection,
  `base.sqlite` reads/writes, Markdown/image file previews, and bounded agent
  launch progress for Codex and Claude Code.
- `claude_code_client.ex` - Port-based adapter that runs
  `claude -p <prompt> --output-format stream-json` headlessly inside the
  opportunity repo, maps the init/result stream events onto the shared launch
  envelope, and bounds writes with Claude Code permission allow/deny rules.
