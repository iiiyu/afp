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

`AGENTS.md` is the canonical entrypoint for the research agent (Codex or
Claude Code). If an existing repo has a misspelled `AGENETS.md`, AFP reports it
in health notes and expects the file to be renamed before the repo can become
healthy.

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

The repo-local SQLite database is intentionally portable and small
(schema version 2):

- `repo_metadata` - schema version, display name, and repo metadata.
- `opportunities` - one row per opportunity with raw input, title, source URL,
  launch agent (`codex` or `claude_code`), status, stage, route, total score,
  active run, agent session, latest summary, error, and timestamps.
- `opportunity_runs` - one row per agent launch/run with launch agent, prompt,
  status, stage, session/thread/turn metadata, transcript path, final answer,
  error, payload, and timestamps.
- `opportunity_files` - Markdown/image file index for AFP's detail browser,
  with repo-relative path, file type, size, and mtime.

Schema v1 repos (without the `agent` columns) are upgraded in place the next
time AFP inspects the repo; existing rows default to `codex`.

## Agent Launch Boundary

When AFP creates a new opportunity from a simple input, it:

1. Generates a UUID and creates `opportunities/[uuid]/README.md`.
2. Creates `opportunities/[uuid]/generated_other_files/`.
3. Inserts the opportunity and queued run into `base.sqlite` with the selected
   launch agent.
4. Starts the selected agent with the opportunity repo as `cwd`: either a Codex
   app-server turn (JSON-RPC over stdio) or a Claude Code headless run
   (`claude -p <prompt> --output-format stream-json`).
5. Restricts writes to `opportunities/`, `.skills/`, and `base.sqlite` — via
   the Codex sandbox policy or Claude Code permission allow/deny rules.
6. Updates `base.sqlite` as the agent reaches session, turn, completed, or
   failed states.

The repo-local `.skills/opportunity-research/SKILL.md` carries the evidence caps
and five-indicator scoring workflow used by the launch prompt.
