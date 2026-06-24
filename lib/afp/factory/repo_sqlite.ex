# @input  - File paths to external repo-local SQLite databases and SQL strings
# @output - Decoded JSON rows for reads, :ok for writes, normalized error tuples
# @pos    - Single seam for shelling out to the sqlite3 CLI against external repos
defmodule Afp.Factory.RepoSqlite do
  @moduledoc """
  The one place AFP talks to an external repo's SQLite file via the `sqlite3` CLI.

  Callers compute the database path (each context owns its own file name) and pass
  it in. This module hides the CLI flags, the busy-timeout, JSON decoding, and error
  normalization so that fix-once-fixed-everywhere holds for all of them.

  ## Errors

  Every function returns `{:error, reason}` with one of:

    * `:sqlite3_unavailable` — the `sqlite3` binary is not on PATH
    * `{:sqlite_error, message}` — the CLI exited non-zero (trimmed stderr/stdout)
    * `{:unexpected_sqlite_json, _}` / `{:invalid_sqlite_json, message}` — read decode failed
  """

  # ponytail: writers share base.sqlite with the launched agent; wait for the lock
  # instead of failing instantly. Bump if launches still hit SQLITE_BUSY.
  @busy_timeout_ms 5000

  @doc """
  Run a read query and decode its JSON result rows.

  Opens the database `-readonly`, so it never blocks writers. An empty result is
  `{:ok, []}`.
  """
  @spec query(Path.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def query(_db_path, ""), do: {:ok, []}

  def query(db_path, sql) do
    case run(["-readonly", "-json", db_path, sql]) do
      {:ok, output} -> decode_json(output)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Run one or more write statements. Waits up to #{@busy_timeout_ms}ms for a lock.
  """
  @spec execute(Path.t(), String.t()) :: :ok | {:error, term()}
  def execute(_db_path, ""), do: :ok

  def execute(db_path, sql) do
    case run(["-cmd", "PRAGMA busy_timeout=#{@busy_timeout_ms}", db_path, sql]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Quote a value for inline interpolation into SQL.

  The `sqlite3` CLI takes no bind parameters, so callers build SQL by interpolation
  and this is the single injection boundary. If a real parameterized API is needed,
  swap the CLI for Exqlite behind this module — the interface stays the same.
  """
  @spec escape(term()) :: String.t()
  def escape(nil), do: "NULL"
  def escape(value) when is_integer(value), do: Integer.to_string(value)

  def escape(value) do
    escaped = value |> to_string() |> String.replace("'", "''")
    "'#{escaped}'"
  end

  defp run(args) do
    case System.cmd("sqlite3", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, {:sqlite_error, String.trim(output)}}
    end
  rescue
    error in ErlangError ->
      case error.original do
        :enoent -> {:error, :sqlite3_unavailable}
        _other -> {:error, {:sqlite_error, Exception.message(error)}}
      end
  end

  defp decode_json(output) do
    case String.trim(output) do
      "" ->
        {:ok, []}

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, rows} when is_list(rows) -> {:ok, rows}
          {:ok, other} -> {:error, {:unexpected_sqlite_json, other}}
          {:error, error} -> {:error, {:invalid_sqlite_json, Exception.message(error)}}
        end
    end
  end
end
