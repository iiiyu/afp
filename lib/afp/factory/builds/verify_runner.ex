# @input  - App repo paths and manifest-declared verify entrypoints
# @output - Executed gate chains with parsed verify.json results
# @pos    - Deterministic oracle executor for the BuildRunner (Port, no agent)
defmodule Afp.Factory.Builds.VerifyRunner do
  alias Afp.Factory.Builds.AppRepo

  @output_tail_bytes 4_000

  @doc """
  Runs the repo's verify entrypoint and reads back the verify report.

  Returns `{:ok, result}` whenever the chain ran and produced a report —
  `result["pass"]` carries the verdict — or `{:error, reason}` when the
  chain could not run or produced no report.
  """
  def run(repo_path, manifest, opts \\ []) do
    entrypoint = AppRepo.verify_entrypoint(manifest)
    report_rel = AppRepo.verify_report_path(manifest)
    timeout_ms = Keyword.get(opts, :timeout_ms, default_timeout_ms())

    with {:ok, exit_status, output} <- run_entrypoint(repo_path, entrypoint, timeout_ms),
         {:ok, report} <- read_report(repo_path, report_rel) do
      {:ok,
       report
       |> Map.put("exit_status", exit_status)
       |> Map.put("report_path", report_rel)
       |> Map.put("output_tail", tail(output))}
    end
  end

  defp run_entrypoint(repo_path, entrypoint, timeout_ms) do
    script = Path.join(repo_path, entrypoint)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, repo_path},
        args: ["-c", "exec #{sh_quote(script)}"]
      ])

    collect(port, "", System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp collect(port, output, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      close_port(port)
      {:error, {:verify_timeout, tail(output)}}
    else
      receive do
        {^port, {:data, chunk}} -> collect(port, output <> chunk, deadline)
        {^port, {:exit_status, status}} -> {:ok, status, output}
      after
        remaining ->
          close_port(port)
          {:error, {:verify_timeout, tail(output)}}
      end
    end
  end

  defp read_report(repo_path, report_rel) do
    path = Path.join(repo_path, report_rel)

    with {:ok, raw} <- File.read(path),
         {:ok, report} when is_map(report) <- Jason.decode(raw) do
      {:ok, report}
    else
      {:error, :enoent} -> {:error, {:verify_report_missing, report_rel}}
      {:error, reason} -> {:error, {:verify_report_invalid, reason}}
      {:ok, _other} -> {:error, {:verify_report_invalid, :not_a_map}}
    end
  end

  defp tail(output) when byte_size(output) <= @output_tail_bytes, do: output

  defp tail(output),
    do: binary_part(output, byte_size(output) - @output_tail_bytes, @output_tail_bytes)

  defp sh_quote(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp default_timeout_ms do
    Application.get_env(:afp, :build_verify_timeout_ms, 1_800_000)
  end
end
