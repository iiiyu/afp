<!-- If files in this folder change, update this document. -->

# Opportunities LiveView Components

## Architecture Summary

Render layer for the opportunities console. The LiveView module
(`../opportunities_live.ex`) keeps mount/params/handlers and imports these
function components; markup and presentation helpers live here. Components
receive typed read-model structs (`%Opportunity{}`, `%Run{}`, …) and never
string-index database columns.

## File Inventory

- `components.ex` - Header, repo setup, and opportunity index components plus
  shared presentation helpers (`format_value/1`, `format_score/1`,
  `format_timestamp/1`).
- `detail_components.ex` - The selected-opportunity detail surface: header
  panel, research steps, file browser, agent session with live activity, and
  run history.
