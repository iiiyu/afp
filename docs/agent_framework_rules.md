# Agent Framework Rules

## Purpose

This document holds the detailed Elixir, Phoenix, Ecto, and HEEx implementation guidance that was previously in `AGENTS.md`.
Read this file before making changes in server-side Elixir code, router/controller code, schema/query code, or HEEx templates.

## Phoenix v1.8 project rules

- Always begin LiveView templates with `<Layouts.app flash={@flash} ...>` and pass `current_scope` when required.
- `AfpWeb.Layouts` is already aliased through `afp_web.ex`.
- If you hit a missing `current_scope` assign error:
  - move the route into the correct authenticated `live_session`
  - pass `current_scope` into `<Layouts.app>`
- Phoenix v1.8 moved `<.flash_group>` into `layouts.ex`. Never call `<.flash_group>` outside `layouts.ex`.
- Use the imported `<.icon>` component for icons.
- Use the imported `<.input>` component for form fields when available.
- If you override `<.input>` classes, you must fully restyle the input because defaults are not inherited.

## Elixir rules

- Never use list access syntax like `mylist[i]`. Use `Enum.at/2`, `List`, or pattern matching.
- Elixir variables are immutable. Rebind the result of `if`, `case`, `cond`, and similar expressions outside the block.
- Never nest multiple modules in the same file.
- Never use map-style access like `changeset[:field]` on structs. Use direct field access or the proper API such as `Ecto.Changeset.get_field/2`.
- Prefer Elixir standard library date/time modules. Do not add dependencies for date/time handling unless explicitly needed for parsing.
- Never use `String.to_atom/1` on user input.
- Prefer pattern matching, function heads, and `case` for data-shape branching. Use `if/else` only for plain boolean predicates.
- Predicate functions should end with `?` and should not start with `is_` unless they are guards.
- OTP primitives such as `DynamicSupervisor` and `Registry` should be started with explicit names in child specs.
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure. In most cases, pass `timeout: :infinity`.

## Mix rules

- Read task docs before using unfamiliar mix tasks: `mix help task_name`
- For test debugging, prefer `mix test path/to/test.exs` or `mix test --failed`
- Avoid `mix deps.clean --all` unless there is a clear reason.

## Test rules

- Use `start_supervised!/1` to start processes in tests so they are cleaned up between tests.
- Avoid `Process.sleep/1` and `Process.alive?/1` in tests.
- To wait for a process to finish, use `Process.monitor/1` and assert on the `:DOWN` message.
- To synchronize before the next call, prefer `_ = :sys.get_state(pid)` over sleeping.

## Phoenix router and controller rules

- Remember that router `scope` blocks may already alias modules. Avoid duplicate module prefixes.
- Do not add extra `alias` lines for route definitions when the `scope` already provides the namespace.
- Do not use `Phoenix.View`.

Example:

```elixir
scope "/admin", AfpWeb.Admin do
  pipe_through :browser

  live "/users", UserLive, :index
end
```

The `UserLive` route points to `AfpWeb.Admin.UserLive`.

## Ecto rules

- Always preload associations that templates will access.
- Import `Ecto.Query` and supporting modules in `seeds.exs` when needed.
- Use `:string` in Ecto schemas even when the database column is `text`.
- `Ecto.Changeset.validate_number/2` does not need `:allow_nil`.
- Use `Ecto.Changeset.get_field/2` to read changeset fields.
- Programmatically set fields such as `user_id` must not be accepted through `cast`.
- Always run `mix ecto.gen.migration migration_name_using_underscores` when generating migrations.

## HEEx rules

- Use `~H` or `.html.heex`, never `~E`.
- Use `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1`, never the old `Phoenix.HTML.*` form helpers.
- Always build forms from `to_form/2`, assign them in the LiveView, and reference fields via `@form[:field]`.
- Always add stable DOM IDs to key elements such as forms and primary buttons.
- For app-wide template imports, add imports/aliases in the `afp_web.ex` `html_helpers` block.
- Do not use `else if` or `elseif` in Elixir templates. Use `cond` or `case`.
- Use `phx-no-curly-interpolation` when showing literal `{` or `}` inside code blocks.
- HEEx class attributes with multiple values must use list syntax: `class={[...]}`
- Do not use `<% Enum.each %>` for rendering template lists. Use `<%= for ... do %>`.
- Use `<%!-- ... --%>` for HEEx comments.
- Use `{...}` for attribute interpolation and inline values. Use `<%= ... %>` only for block constructs in tag bodies.

## HEEx examples

Valid conditional rebinding:

```elixir
socket =
  if connected?(socket) do
    assign(socket, :val, val)
  else
    socket
  end
```

Valid HEEx form usage:

```heex
<.form for={@form} id="user-form" phx-submit="save">
  <.input field={@form[:email]} type="email" />
</.form>
```

Valid HEEx conditional rendering:

```heex
<div id={@id}>
  {@message}
  <%= if @show_details do %>
    {@details}
  <% end %>
</div>
```
