# Agent LiveView Rules

## Purpose

This document holds the detailed LiveView, stream, testing, JavaScript interop, and form-handling guidance that was previously in `AGENTS.md`.
Read this file before changing LiveViews, LiveView tests, JavaScript hooks, or LiveView-driven forms.

## LiveView rules

- Never use deprecated `live_redirect` or `live_patch`. Use `<.link navigate={...}>`, `<.link patch={...}>`, `push_navigate`, and `push_patch`.
- Avoid LiveComponents unless there is a strong reason.
- LiveViews should use the `...Live` suffix, for example `AfpWeb.WeatherLive`.
- In the default `:browser` scope, the router is already aliased with `AfpWeb`, so route with `live "/weather", WeatherLive`.
- If a `phx-hook` manages its own DOM, also set `phx-update="ignore"`.
- Every `phx-hook` must have a stable DOM ID.
- Never write raw inline `<script>` tags in HEEx.

## LiveView stream rules

- Use streams for dynamic collections instead of assigning large lists directly.
- Typical operations:
  - append: `stream(socket, :messages, [new_msg])`
  - reset: `stream(socket, :messages, messages, reset: true)`
  - prepend: `stream(socket, :messages, [new_msg], at: -1)`
  - delete: `stream_delete(socket, :messages, msg)`
- Stream containers must:
  - set `phx-update="stream"`
  - have a stable DOM ID
  - render items from `@streams.stream_name`
  - use each stream item ID as the child DOM ID
- Streams are not enumerable. Do not use `Enum.filter/2` or `Enum.reject/2` directly on them.
- For filtered stream views, re-fetch data and re-stream with `reset: true`.
- Streams do not track counts or empty states for you. Keep count in a separate assign. Use a sibling empty-state block if needed.
- When an assign changes content inside streamed items, re-stream the affected items so the template updates.
- Never use deprecated `phx-update="append"` or `phx-update="prepend"`.

Example stream markup:

```heex
<div id="messages" phx-update="stream">
  <div :for={{id, message} <- @streams.messages} id={id}>
    {message.text}
  </div>
</div>
```

## LiveView JavaScript interop

- External hooks must live in `assets/js/` and be passed to the `LiveSocket` constructor in `assets/js/app.js`.
- Colocated hooks must use `:type={Phoenix.LiveView.ColocatedHook}` and hook names must start with `.`.
- Use `push_event/3` when the server needs to push data to a hook.
- Always return or rebind the socket returned by `push_event/3`.

Example:

```elixir
def handle_event("some_event", _params, socket) do
  {:noreply, push_event(socket, "client_event", %{ok: true})}
end
```

## LiveView test rules

- Use `Phoenix.LiveViewTest` and `LazyHTML`.
- Drive form tests with `render_submit/2` and `render_change/2`.
- Prefer stable element IDs and selectors over raw HTML string assertions.
- Do not test against raw HTML when a semantic selector can verify behavior.
- Prefer outcome-oriented assertions over implementation details.
- If a selector fails unexpectedly, inspect a narrowed HTML fragment with `LazyHTML`.

Example debugging pattern:

```elixir
html = render(view)
document = LazyHTML.from_fragment(html)
matches = LazyHTML.filter(document, "#complex-selector")
IO.inspect(matches, label: "Matches")
```

## LiveView form rules

### Building forms from params

```elixir
def handle_event("submitted", %{"user" => user_params}, socket) do
  {:noreply, assign(socket, form: to_form(user_params, as: :user))}
end
```

### Building forms from changesets

```elixir
form =
  %Afp.Users.User{}
  |> Ecto.Changeset.change()
  |> to_form()
```

### Template usage

- Always render forms from `@form`.
- Always use `<.input field={@form[:field]}>`.
- Always give forms explicit DOM IDs.
- Never drive the template directly from a changeset.
- Never use `<.form let={f} ...>` in this project.

Valid:

```heex
<.form for={@form} id="my-form">
  <.input field={@form[:field]} type="text" />
</.form>
```

Invalid:

```heex
<.form for={@changeset} id="my-form">
  <.input field={@changeset[:field]} type="text" />
</.form>
```
