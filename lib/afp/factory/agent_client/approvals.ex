# @input  - A launch-derived %Profile{} and approval request params maps
# @output - Pure {decision, reason} verdicts for command/file/permission requests
# @pos    - The safety-critical approval engine, testable without a Port
defmodule Afp.Factory.AgentClient.Approvals do
  @moduledoc """
  Pure approval decisions for agent server-requests. `profile/1` derives the
  bounds from a launch request once; `decide_command/2`, `decide_file_change/2`,
  and `decide_permissions/2` are pure functions of (profile, request params) —
  the interface tests exercise directly, no transport required.
  """

  alias Afp.Factory.AgentClient.CommandPolicy

  @sqlite_write_operations [
    "upsert_research_run",
    "upsert_candidate",
    "upsert_source",
    "upsert_sources",
    "upsert_score",
    "upsert_scores",
    "link_artifact",
    "upsert_opportunity",
    "upsert_run",
    "upsert_step_result",
    "upsert_evidence",
    "link_file"
  ]

  defmodule Profile do
    @moduledoc "Launch bounds the approval decisions are made against."
    defstruct [
      :cwd,
      :source_root,
      :sqlite_path,
      write_roots: [],
      sqlite_allowed_operations: [],
      network_access: true
    ]
  end

  @doc "Derives the approval bounds from a launch request (struct or map)."
  def profile(request) do
    cwd = request |> Map.fetch!(:cwd) |> Path.expand()
    source_root = request |> Map.get(:source_repo_root) |> Kernel.||(cwd) |> Path.expand(cwd)

    %Profile{
      cwd: cwd,
      source_root: source_root,
      write_roots: write_roots(source_root, request),
      sqlite_path: sqlite_path(source_root, request),
      sqlite_allowed_operations: Map.get(request, :sqlite_allowed_operations) || [],
      network_access: Map.get(request, :network_access, true)
    }
  end

  @doc "Verdict for a file-change / grant-root approval request."
  def decide_file_change(%Profile{} = profile, params) when is_map(params) do
    grant_root = Map.get(params, "grantRoot")

    cond do
      blank?(grant_root) ->
        {"accept", "No extra grant root requested; turn sandbox and source repo contract apply."}

      path_within_any?(grant_root, profile.write_roots) ->
        {"accept", "Requested grant root is inside manifest-declared write targets."}

      sqlite_path?(profile, grant_root) ->
        {"accept", "Requested grant root matches the manifest-declared SQLite path."}

      true ->
        {"decline", "Requested grant root is outside manifest-declared write targets."}
    end
  end

  @doc "Verdict for a command-execution approval request."
  def decide_command(%Profile{} = profile, params) when is_map(params) do
    cwd = params["cwd"] || profile.cwd
    command = params["command"]
    command_actions = params["commandActions"]

    cond do
      not path_within?(cwd, profile.source_root) ->
        {"decline", "Command cwd is outside the source repo."}

      network_approval?(params) and profile.network_access ->
        {"accept", "Network access is enabled for this bounded research turn."}

      command_actions_outside_source?(command_actions, profile) ->
        {"decline", "Command action path is outside the source repo."}

      CommandPolicy.destructive?(command) ->
        {"decline", "Command matches a blocked destructive or out-of-band pattern."}

      read_only_command_actions?(command_actions) ->
        {"accept", "Command actions are read-only and source-repo bounded."}

      sqlite_command_allowed?(command, profile) ->
        {"accept",
         "Command targets the manifest-declared SQLite database with allowed operations."}

      CommandPolicy.safe_read?(command) ->
        {"accept", "Command appears read-only and source-repo bounded."}

      true ->
        {"decline", "Command is not recognized as safe or manifest-bounded."}
    end
  end

  @doc "Granted permissions map plus reason for a permissions approval request."
  def decide_permissions(%Profile{} = profile, params) when is_map(params) do
    requested = Map.get(params, "permissions") || %{}
    network = requested["network"] || %{}

    permissions =
      if network["enabled"] == true and profile.network_access do
        %{"network" => %{"enabled" => true}}
      else
        %{}
      end

    reason =
      cond do
        permissions != %{} ->
          "Granted requested network permission; filesystem permissions remain bounded by sandbox."

        get_in(requested, ["network", "enabled"]) == true and not profile.network_access ->
          "Network permission was requested but network access is disabled for this launch."

        true ->
          "No additional permissions granted; filesystem writes stay inside the turn sandbox."
      end

    {permissions, reason}
  end

  defp write_roots(source_root, request) do
    write_targets =
      request
      |> Map.get(:write_targets)
      |> write_target_paths()
      |> Enum.map(&expand_source_path(source_root, &1))

    if write_targets == [] do
      [source_root]
    else
      write_targets
    end
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp write_target_paths(write_targets) when is_map(write_targets) do
    write_targets
    |> Map.values()
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&blank?/1)
  end

  defp write_target_paths(_write_targets), do: []

  defp sqlite_path(source_root, request) do
    case Map.get(request, :sqlite_path) do
      path when is_binary(path) and path != "" -> expand_source_path(source_root, path)
      _path -> nil
    end
  end

  defp sqlite_path?(%Profile{sqlite_path: nil}, _path), do: false

  defp sqlite_path?(%Profile{sqlite_path: sqlite_path}, path) do
    expanded_path = Path.expand(path)
    expanded_path == sqlite_path or String.starts_with?(expanded_path, sqlite_path <> "-")
  end

  defp expand_source_path(source_root, path) do
    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      Path.expand(path, source_root)
    end
  end

  defp path_within?(nil, _root), do: false

  defp path_within?(path, root) when is_binary(path) and is_binary(root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)

    expanded_path == expanded_root or String.starts_with?(expanded_path, expanded_root <> "/")
  end

  defp path_within?(_path, _root), do: false

  defp path_within_any?(path, roots) when is_binary(path) do
    Enum.any?(roots, &path_within?(path, &1))
  end

  defp path_within_any?(_path, _roots), do: false

  defp network_approval?(params) do
    match?(%{}, params["networkApprovalContext"])
  end

  defp command_actions_outside_source?(actions, profile) when is_list(actions) do
    Enum.any?(actions, fn action ->
      case Map.get(action, "path") do
        path when is_binary(path) -> not path_within?(path, profile.source_root)
        _path -> false
      end
    end)
  end

  defp command_actions_outside_source?(_actions, _profile), do: false

  defp read_only_command_actions?(actions) when is_list(actions) and actions != [] do
    Enum.all?(actions, fn action ->
      Map.get(action, "type") in ["read", "listFiles", "search"]
    end)
  end

  defp read_only_command_actions?(_actions), do: false

  defp sqlite_command_allowed?(command, %Profile{sqlite_path: sqlite_path} = profile)
       when is_binary(command) and is_binary(sqlite_path) do
    sqlite_requested? =
      String.contains?(command, "sqlite3") and
        (String.contains?(command, sqlite_path) ||
           String.contains?(command, Path.basename(sqlite_path)))

    sqlite_write_allowed? =
      Enum.any?(profile.sqlite_allowed_operations || [], &(&1 in @sqlite_write_operations))

    sqlite_requested? and sqlite_write_allowed?
  end

  defp sqlite_command_allowed?(_command, _profile), do: false

  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")
end
