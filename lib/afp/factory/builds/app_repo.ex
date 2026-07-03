# @input  - App repo paths and their afp/manifest.json contract files
# @output - Manifest data plus a health verdict for launch preflight
# @pos    - Contract reader for afp-app-repo/v1 repos (docs/app-repo-contract.md)
defmodule Afp.Factory.Builds.AppRepo do
  alias Afp.Factory
  alias Afp.Factory.RepoSqlite

  @contract "afp-app-repo/v1"
  @manifest_path "afp/manifest.json"
  @default_state_db "afp/state.sqlite"
  @default_verify_entrypoint "Scripts/verify.sh"
  @default_verify_report "afp/artifacts/verify.json"
  @state_tables ~w(build_milestones build_evidence)

  def contract, do: @contract

  @doc """
  Inspects an app repo against the afp-app-repo/v1 contract.

  Returns `%{health_state, manifest, missing_paths, notes}`; `health_state`
  is one of `Factory.app_repo_health_states/0` and only `"healthy"` repos
  are launchable.
  """
  def inspect_repo(repo_path) do
    expanded = Factory.expand_path(repo_path)

    with :ok <- check_dir(expanded),
         :ok <- check_agents(expanded),
         {:ok, manifest} <- read_manifest(expanded),
         :ok <- check_verify_entrypoint(expanded, manifest),
         :ok <- check_state_db(expanded, manifest) do
      %{health_state: "healthy", manifest: manifest, missing_paths: [], notes: []}
    else
      {:unhealthy, state, missing, notes, manifest} ->
        %{health_state: state, manifest: manifest, missing_paths: missing, notes: notes}
    end
  end

  def verify_entrypoint(manifest) do
    get_in(manifest, ["verify", "entrypoint"]) || @default_verify_entrypoint
  end

  def verify_report_path(manifest) do
    get_in(manifest, ["verify", "report"]) || @default_verify_report
  end

  def state_db_path(manifest) do
    manifest["state_db"] || @default_state_db
  end

  defp check_dir(path) do
    if File.dir?(path) do
      :ok
    else
      {:unhealthy, "missing", [path], ["repo directory not found"], %{}}
    end
  end

  defp check_agents(path) do
    if File.regular?(Path.join(path, "AGENTS.md")) do
      :ok
    else
      {:unhealthy, "agents_missing", ["AGENTS.md"], ["AGENTS.md is required"], %{}}
    end
  end

  defp read_manifest(path) do
    manifest_file = Path.join(path, @manifest_path)

    with {:ok, raw} <- File.read(manifest_file),
         {:ok, manifest} when is_map(manifest) <- Jason.decode(raw) do
      if manifest["contract"] == @contract do
        {:ok, manifest}
      else
        {:unhealthy, "invalid_manifest", [],
         ["manifest contract is #{inspect(manifest["contract"])}, expected #{@contract}"],
         manifest}
      end
    else
      {:error, :enoent} ->
        {:unhealthy, "manifest_missing", [@manifest_path], ["#{@manifest_path} not found"], %{}}

      {:error, %Jason.DecodeError{} = error} ->
        {:unhealthy, "invalid_manifest", [],
         ["#{@manifest_path} is not valid JSON: #{Exception.message(error)}"], %{}}

      {:error, reason} ->
        {:unhealthy, "invalid_manifest", [], ["#{@manifest_path} unreadable: #{inspect(reason)}"],
         %{}}

      {:ok, _other} ->
        {:unhealthy, "invalid_manifest", [], ["#{@manifest_path} must be a JSON object"], %{}}
    end
  end

  defp check_verify_entrypoint(path, manifest) do
    entrypoint = verify_entrypoint(manifest)

    if File.regular?(Path.join(path, entrypoint)) do
      :ok
    else
      {:unhealthy, "verify_missing", [entrypoint], ["verify entrypoint not found"], manifest}
    end
  end

  defp check_state_db(path, manifest) do
    db_rel = state_db_path(manifest)
    db_path = Path.join(path, db_rel)

    cond do
      not File.regular?(db_path) ->
        {:unhealthy, "state_db_missing", [db_rel], ["state db not found"], manifest}

      true ->
        case RepoSqlite.query(
               db_path,
               "SELECT name FROM sqlite_master WHERE type = 'table';"
             ) do
          {:ok, rows} ->
            names = Enum.map(rows, & &1["name"])
            missing = Enum.reject(@state_tables, &(&1 in names))

            if missing == [] do
              :ok
            else
              {:unhealthy, "state_db_invalid", missing,
               ["state db is missing tables: #{Enum.join(missing, ", ")}"], manifest}
            end

          {:error, reason} ->
            {:unhealthy, "state_db_invalid", [db_rel],
             ["state db unreadable: #{inspect(reason)}"], manifest}
        end
    end
  end
end
