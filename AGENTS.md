This is a web application written using the Phoenix web framework.

## Core project rules

- Use `mix precommit` when you are done and fix any issues it reports.
- Use the included `Req` client for HTTP requests. Do not introduce `:httpoison`, `:tesla`, or `:httpc`.
- **Do not opportunistically fix unrelated behavior while working on the current request.** If you notice unrelated bugs, cleanup opportunities, or behavior mismatches, leave them unchanged unless the user explicitly asks for them.
- Prefer small, working changes that match existing project patterns.
- After completing a feature-sized milestone that passes validation, run `git add`, `git commit`, and `git push` for the task-related changes. Do not include unrelated dirty work unless the user explicitly asks for full-tree staging.

## Production API compatibility

- Existing public or app-facing API contracts are backward-compatible by default.
- When changing an existing endpoint, preserve behavior expected by older app versions, including request shape, response shape, status codes, authentication semantics, and meaningful side effects.
- If a change would break existing clients, create a new endpoint, version, or opt-in behavior instead of changing the existing contract in place.
- Treat all API upgrades as compatibility work: document or test the compatibility path when the change affects existing clients.

## Planning and scope

- For complex work, break the task into 3 to 5 stages in `IMPLEMENTATION_PLAN.md`.
- Update stage status as you progress.
- Remove `IMPLEMENTATION_PLAN.md` when all stages are complete.

## Documentation and file hygiene

- After functionality, architecture, or coding-pattern changes, update the relevant docs before finishing.
- Keep the root `README.md` and any existing directory `README.md` files aligned with code changes.
- When adding a durable source directory, include a minimal `README.md` with:
  - the header comment `<!-- If files in this folder change, update this document. -->`
  - a short architecture summary
  - a file inventory with role and purpose
- New source files, and modified source files that already use this convention, must keep the 3-line header block:

```elixir
# @input  - External dependencies this file relies on
# @output - What this file provides to the system
# @pos    - This file's role in the local architecture
```

- If the database changes in any way, update `docs/database_schema.md`.

## Hard Phoenix project constraints

- Always begin LiveView templates with `<Layouts.app flash={@flash} ...>`.
- If `current_scope` is required, fix it through the proper authenticated `live_session` and pass it into `<Layouts.app>`.
- Never call `<.flash_group>` outside `layouts.ex`.
- Use the imported `<.icon>` component for icons.
- Use the imported `<.input>` component for form inputs when available.
- Keep the Tailwind v4 import syntax in `assets/css/app.css`.
- Never use `@apply`.
- Never write inline `<script>` tags in HEEx templates.
- Do not add daisyUI.

## Task-specific reference docs

Read the relevant file before making changes in that area:

- Elixir, Phoenix, Ecto, router, controller, schema, or HEEx work:
  [`docs/agent_framework_rules.md`](docs/agent_framework_rules.md)
- LiveView implementation, streams, LiveView tests, or form handling:
  [`docs/agent_liveview_rules.md`](docs/agent_liveview_rules.md)
- CSS, JS hooks, and UI presentation work:
  [`docs/agent_ui_rules.md`](docs/agent_ui_rules.md)
