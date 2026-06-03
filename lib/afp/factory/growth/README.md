<!-- If files in this folder change, update this document. -->

# Growth Experiments

## Architecture Summary

This folder stores manual growth experiment schemas. The `Afp.Factory.Growth`
context keeps post-launch business experiments separate from tickets while still
feeding Today when review dates are due.

## File Inventory

- `growth_experiment.ex` - Persisted growth experiment with hypothesis, metric, priority, status, review due date, and outcome note.
