<!-- If files in this folder change, update this document. -->

# Live Views

## Architecture Summary

This folder contains Phoenix LiveViews for the local-first one-person app
factory control plane, reduced to the two core surfaces (Opportunities and
Apps). Screens stay thin: they render compact operational UI, call
`Afp.Factory.*` contexts for domain rules, and reload their read model when
the factory event log broadcasts updates.

## File Inventory

- `opportunities_live.ex` - Primary opportunity repo console with first-run
  setup, repo health, research launches, opportunity table, detail run state,
  and Markdown/image file browser. Also the root route.
- `app_live/index.ex` - App portfolio table, filters, and app creation.
- `app_live/show.ex` - App detail: overview, next action, lifecycle/posture
  transitions, and per-app event history.
