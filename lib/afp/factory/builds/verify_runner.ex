# @input  - App repo paths, manifest-declared verify entrypoints, pinned simulators
# @output - Executed gate chains with parsed verify.json, infra false-reds retried once
# @pos    - Deterministic oracle executor for build runs (Port, no agent)
defmodule Afp.Factory.Builds.VerifyRunner do
  require Logger

  alias Afp.Factory.Builds.AppRepo

  @output_tail_bytes 4_000

  # Signatures of simulator/test-runner infrastructure failures that produce
  # false-red gates (the first real supervised run hit "Simulator Busy").
  @infra_failure_signatures [
    ~r/Failed to install or launch the test runner/i,
    ~r/Application failed preflight checks/i,
    ~r/Simulator device failed to launch/i,
    ~r/Unable to boot the Simulator/i
  ]

  @doc """
  Runs the repo's verify entrypoint and reads the report back. When the
  chain fails with an infrastructure false-red signature, it retries the
  whole chain once (decision 4 of docs/build-runner-v2-design.md).
  """
  def run(repo_path, manifest, opts \\ []) do
    case run_once(repo_path, manifest, opts) do
      {:ok, report} ->
        if report["pass"] != true and infra_false_red?(repo_path, report) and
             not Keyword.get(opts, :retried?, false) do
          Logger.warning("Verify chain hit an infrastructure false-red; retrying once",
            repo_path: repo_path
          )

          run(repo_path, manifest, Keyword.put(opts, :retried?, true))
          |> mark_retried()
        else
          {:ok, report}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mark_retried({:ok, report}), do: {:ok, Map.put(report, "retried_infra_false_red", true)}
  defp mark_retried(other), do: other

  defp run_once(repo_path, manifest, opts) do
    entrypoint = AppRepo.verify_entrypoint(manifest)
    report_rel = AppRepo.verify_report_path(manifest)
    timeout_ms = Keyword.get(opts, :timeout_ms, default_timeout_ms())

    with {:ok, exit_status, output} <-
           run_entrypoint(repo_path, entrypoint, AppRepo.verify_simulator(manifest), timeout_ms),
         {:ok, report} <- read_report(repo_path, report_rel) do
      {:ok,
       report
       |> Map.put("exit_status", exit_status)
       |> Map.put("output_tail", tail(output))}
    end
  end

  defp run_entrypoint(repo_path, entrypoint, simulator, timeout_ms) do
    script = Path.join(repo_path, entrypoint)

    env =
      case simulator do
        sim when is_binary(sim) and sim != "" -> [{~c"VERIFY_SIM", String.to_charlist(sim)}]
        _sim -> []
      end

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, repo_path},
        {:env, env},
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

  # A false-red is a failed gate whose distilled log matches an infrastructure
  # signature — the tests never actually ran.
  defp infra_false_red?(repo_path, report) do
    report
    |> Map.get("gates", [])
    |> Enum.filter(&(&1["status"] == "fail"))
    |> Enum.any?(fn gate -> gate_log_matches_signature?(repo_path, gate) end) or
      output_matches_signature?(report["output_tail"])
  end

  defp gate_log_matches_signature?(repo_path, %{"log" => log}) when is_binary(log) do
    case File.read(Path.join(repo_path, log)) do
      {:ok, content} -> output_matches_signature?(content)
      _error -> false
    end
  end

  defp gate_log_matches_signature?(_repo_path, _gate), do: false

  defp output_matches_signature?(text) when is_binary(text) do
    Enum.any?(@infra_failure_signatures, &Regex.match?(&1, text))
  end

  defp output_matches_signature?(_text), do: false

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
