# @input  - Verify jobs (zero-arity funs) from concurrent build runs
# @output - Serially executed verify chains
# @pos    - The global simulator-contention lock: one verify chain at a time
defmodule Afp.Factory.Builds.VerifyQueue do
  @moduledoc """
  Cross-app build runs may execute in parallel, but AFP-run verify chains
  share the simulator fleet — so they queue here and run one at a time
  (decision 7 of docs/build-runner-v2-design.md). GenServer call semantics
  give FIFO ordering for free.
  """

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Runs `fun` when the queue reaches it; blocks the caller until done."
  def run(fun) when is_function(fun, 0) do
    GenServer.call(__MODULE__, {:run, fun}, :infinity)
  end

  @impl GenServer
  def init(:ok), do: {:ok, :ok}

  @impl GenServer
  def handle_call({:run, fun}, _from, state) do
    {:reply, fun.(), state}
  end
end
