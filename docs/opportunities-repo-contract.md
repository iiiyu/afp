<!-- If files in this folder change, update this document. -->

# Opportunities Repo Contract

AFP's primary discovery surface is `/opportunities`. It points at one local,
portable opportunity repo and stores only the configured repo path in AFP's
PostgreSQL `settings` table. The repo itself owns opportunity state through
`base.sqlite` plus Markdown/image files.

## Required Structure

```text
base.sqlite
opportunities/
  [uuid]/
    README.md
    generated_other_files/
AGENTS.md
.skills/
  opportunity-research/
    SKILL.md
```

`AGENTS.md` is the canonical Codex entrypoint. If an existing repo has a
misspelled `AGENETS.md`, AFP reports it in health notes and expects the file to
be renamed before the repo can become healthy.

## Health Rules

AFP marks a configured repo `healthy` when:

- `base.sqlite` exists and contains the required tables.
- `opportunities/` exists.
- `AGENTS.md` exists.
- `.skills/` exists.

Missing `base.sqlite` is reported as `sqlite_missing`. Missing `AGENTS.md` is
reported as `agents_missing`. Other missing structural paths are reported as
`invalid_structure`. A repo without `.git/` can still be used, but new repos
initialized from AFP run `git init`.

## base.sqlite

The repo-local SQLite database is intentionally portable and small:

- `repo_metadata` - schema version, display name, and repo metadata.
- `opportunities` - one row per opportunity with raw input, title, source URL,
  status, stage, route, total score, active run, Codex session, latest summary,
  error, and timestamps.
- `opportunity_runs` - one row per Codex launch/run with prompt, status, stage,
  session/thread/turn metadata, transcript path, final answer, error, payload,
  and timestamps.
- `opportunity_files` - Markdown/image file index for AFP's detail browser,
  with repo-relative path, file type, size, and mtime.

## Codex Launch Boundary

When AFP creates a new opportunity from a simple input, it:

1. Generates a UUID and creates `opportunities/[uuid]/README.md`.
2. Creates `opportunities/[uuid]/generated_other_files/`.
3. Inserts the opportunity and queued run into `base.sqlite`.
4. Starts a Codex app-server turn with the opportunity repo as `cwd`.
5. Restricts writes to `opportunities/`, `.skills/`, and `base.sqlite`.
6. Updates `base.sqlite` as Codex reaches thread, turn, completed, or failed states.

The repo-local `.skills/opportunity-research/SKILL.md` carries the evidence caps
and five-indicator scoring workflow used by the launch prompt.
