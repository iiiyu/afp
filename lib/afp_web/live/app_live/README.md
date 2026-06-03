<!-- If files in this folder change, update this document. -->

# App Live Views

## Architecture Summary

App LiveViews own the portfolio scan and single-app cockpit. The index keeps the
portfolio table as the primary read model, while the show page layers execution,
operational context, business loops, and app actions. They use the portfolio
context for lifecycle/business state and call adjacent work, release, evidence,
session, and metrics contexts only for app-scoped actions.

## File Inventory

- `index.ex` - Portfolio table with lower-level filters and app creation actions.
- `show.ex` - App detail cockpit with execution, context, business-loop, and action layers.
