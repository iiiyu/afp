<!-- If files in this folder change, update this document. -->

# Opportunities Helpers

## Architecture Summary

This folder holds helper documentation for the `Afp.Factory.Opportunities`
context. The context keeps AFP's configured opportunity repo path in settings
while the portable opportunity index, run state, and file inventory live in the
external repo's `base.sqlite`.

## File Inventory

- `../opportunities.ex` - Opportunity repo scaffold, health inspection,
  `base.sqlite` reads/writes, Markdown/image file previews, and bounded Codex
  launch progress.
