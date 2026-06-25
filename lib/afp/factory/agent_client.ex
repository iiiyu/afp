# @input  - Launch attrs (cwd, input_text, sandbox/contract bounds) and opts
# @output - The shared launch-result envelope, or an error tuple
# @pos    - The seam every agent transport (Codex app-server, Claude Code CLI) fills
defmodule Afp.Factory.AgentClient do
  @moduledoc """
  The contract a launch transport must satisfy to run one agent turn.

  Two real adapters implement it — `Afp.Factory.Demand.CodexAppClient`
  (Codex app-server JSON-RPC) and `Afp.Factory.Opportunities.ClaudeCodeClient`
  (headless `claude -p` stream-json) — and the test fakes implement the same
  contract, so launches are testable without spawning a CLI.

  ## `launch_new_turn(attrs, opts)`

  Runs a single turn synchronously and returns once it completes (or fails).

  `attrs` is a map describing the turn: at minimum `:cwd` and `:input_text`,
  plus the sandbox/contract bounds the adapter enforces (`:sandbox_policy`,
  `:write_targets`, `:sqlite_path`, `:sqlite_allowed_operations`, …) and the
  identifiers echoed back into progress events (`:client_user_message_id` and
  the caller's run/opportunity ids).

  `opts` is a keyword list. The one option both callers rely on:

    * `:on_launch_event` — a `(event, payload) -> :ok | {:ok, term} | {:error, term}`
      function the adapter invokes as the turn progresses, with `event` one of
      `:thread_started`, `:turn_started`, or `:activity`. Persistence/broadcast
      happens in that callback; an `{:error, _}` it returns aborts the launch.

  ## Return value

  On success, `{:ok, result}` where `result` is the shared launch envelope:

    * `:thread_response` / `:turn_response` — the JSON-RPC-shaped maps the
      session/turn ids are read from
    * `:turn_completed` — the completed-turn notification
    * `:final_answer` — the agent's final text
    * `:notifications` — the raw event list (Codex) for diagnostics

  On failure, `{:error, reason}` — adapters tag the reason
  (`:claude_run_failed`, `:codex_turn_aborted`, …) and may attach a diagnostics
  map as the last element.
  """

  @callback launch_new_turn(attrs :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
end
