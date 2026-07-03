<!-- If files in this folder change, update this document. -->

# Live Views

## Architecture Summary

This folder contains Phoenix LiveViews for the local-first one-person app
factory control plane, reduced to the two core surfaces (Opportunities and
Apps). Screens stay thin: they render compact operational UI, call
`Afp.Factory.*` contexts for domain rules, and reload their read model when
the factory event log broadcasts updates.

## File Inventory

- `opportunities_live.ex` - Handlers-only LiveView for the opportunity repo
  console (mount/params/events); markup lives in `opportunities_live/`
  (see its README). Also the root route.
- `opportunities_live/` - Function components for the opportunities surface.
- `app_live/index.ex` - App portfolio table, filters, and app creation.
- `app_live/show.ex` - App repo detail: overview, the BuildRunner v2 build
  surface (milestones, runs, review gate, reports — components in
  `app_live/build_components.ex`), next action, lifecycle/posture
  transitions, and per-app event history.
