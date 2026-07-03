# @input  - A neutral %Request{} describing one agent turn, plus launch opts
# @output - A typed %Result{} or %Error{}, and neutral progress events
# @pos    - The seam every agent transport (Codex app-server, Claude Code CLI) fills
defmodule Afp.Factory.AgentClient do
  @moduledoc """
  The contract a launch transport must satisfy to run one agent turn.

  Two real adapters implement it — `Afp.Factory.CodexAppClient` (Codex
  app-server JSON-RPC) and `Afp.Factory.Opportunities.ClaudeCodeClient`
  (headless `claude -p` stream-json) — plus `Afp.Factory.FakeAgentClient`
  in tests. Callers build a neutral `Request`; each adapter renders its own
  transport representation (sandbox policy JSON, CLI permission rules) from
  it and maps its transport output into `Result`/`Error` exactly once.

  ## `launch_new_turn(request, opts)`

  Runs a single turn synchronously and returns once it completes (or fails).

  `opts` is a keyword list. The one option both callers rely on:

    * `:on_launch_event` — a `(event, payload) -> :ok | {:ok, term} | {:error, term}`
      function invoked as the turn progresses. Events and their neutral payloads:
      `:thread_started` → `%{session_id, thread_id, transcript_path}`,
      `:turn_started` → `%{turn_id}`,
      `:activity` → `%{"kind" => ..., "text" => ..., "at" => ...}`.
      An `{:error, _}` return aborts the launch.
  """

  defmodule Request do
    @moduledoc """
    Neutral description of one agent turn. No transport detail: adapters
    derive their own sandbox/permission representation from `write_targets`,
    `source_repo_root`, `network_access`, and `extra_command_allow`.
    """

    @type t :: %__MODULE__{}

    @enforce_keys [:cwd, :input_text]
    defstruct [
      :cwd,
      :input_text,
      :model,
      :client_user_message_id,
      :source_repo_root,
      :sqlite_path,
      write_targets: %{},
      sqlite_allowed_operations: [],
      network_access: true,
      extra_command_allow: []
    ]
  end

  defmodule Result do
    @moduledoc """
    The launch envelope. Adapters map their transport output into these
    fields once; `raw` keeps the transport-shaped diagnostics for logging.
    """

    @type t :: %__MODULE__{}

    defstruct [
      :session_id,
      :thread_id,
      :turn_id,
      :turn_status,
      :final_answer,
      :transcript_path,
      raw: %{}
    ]
  end

  defmodule Error do
    @moduledoc "One error shape at the seam: match on `reason`, never on tuple arity."

    @type t :: %__MODULE__{}

    defstruct [:reason, :detail, diagnostics: %{}]

    def wrap(%__MODULE__{} = error), do: error

    def wrap({reason, detail, diagnostics}) when is_atom(reason) and is_map(diagnostics),
      do: %__MODULE__{reason: reason, detail: detail, diagnostics: diagnostics}

    def wrap({reason, detail}) when is_atom(reason),
      do: %__MODULE__{reason: reason, detail: detail}

    def wrap(reason) when is_atom(reason), do: %__MODULE__{reason: reason}
    def wrap(other), do: %__MODULE__{reason: :agent_launch_failed, detail: other}
  end

  @callback launch_new_turn(request :: Request.t() | map(), opts :: keyword()) ::
              {:ok, Result.t()} | {:error, Error.t()}
end
