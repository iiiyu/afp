<!-- If files in this folder change, update this document. -->

# App Live Views

## Architecture Summary

App LiveViews own the portfolio scan and single-app cockpit. They use the
portfolio context for lifecycle/business state and call the adjacent work,
release, evidence, session, and metrics contexts only for app-scoped actions.

## File Inventory

- `index.ex` - Portfolio table with filters and app creation.
- `show.ex` - App detail cockpit and quick creation/actions for linked objects.
