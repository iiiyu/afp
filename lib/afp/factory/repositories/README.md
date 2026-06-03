<!-- If files in this folder change, update this document. -->

# Repository Scanner

## Architecture Summary

This folder stores local repository scan schemas. The `Afp.Factory.Repositories`
context owns filesystem/git scanning and translates scan results into portfolio
health signals without mutating external app repositories.

## File Inventory

- `repo_scan.ex` - Persisted snapshot of git status, branch, latest commit, platform hints, app match, and scan errors.
- `scan_repository_roots_worker.ex` - Oban worker for retryable repository root scans.
