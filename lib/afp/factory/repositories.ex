# @input  - Repository roots, app repository paths, and local git metadata
# @output - Repository scan snapshots and app health signals
# @pos    - Context boundary for local repo scanning in the dogfood operating loop
defmodule Afp.Factory.Repositories do
  import Ecto.Query

  alias Afp.Factory
  alias Afp.Factory.Events
  alias Afp.Factory.Portfolio
  alias Afp.Factory.Repositories.RepoScan
  alias Afp.Factory.Repositories.ScanRepositoryRootsWorker
  alias Afp.Repo

  @platform_files [
    {"ios", ["*.xcodeproj", "*.xcworkspace", "Package.swift"]},
    {"android", ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]},
    {"flutter", ["pubspec.yaml"]},
    {"phoenix", ["mix.exs"]},
    {"web", ["package.json", "vite.config.js", "next.config.js"]},
    {"godot", ["project.godot"]}
  ]

  def list_repo_scans(params \\ %{}) do
    RepoScan
    |> preload(:app)
    |> apply_filter(:app_id, Map.get(params, "app_id") || Map.get(params, :app_id))
    |> apply_filter(:status, Map.get(params, "status") || Map.get(params, :status))
    |> order_by([scan], desc: scan.scanned_at)
    |> Repo.all()
  end

  def latest_scan_for_app(app_id) do
    RepoScan
    |> where([scan], scan.app_id == ^app_id)
    |> order_by([scan], desc: scan.scanned_at)
    |> limit(1)
    |> Repo.one()
  end

  def list_repo_attention_scans do
    RepoScan
    |> where([scan], scan.status in ["dirty", "missing", "not_git", "error"])
    |> preload(:app)
    |> order_by([scan], asc: scan.status, desc: scan.scanned_at)
    |> Repo.all()
  end

  def scan_app(app, reason \\ "manual_app_scan") do
    if Factory.blank?(app.repo_path) do
      {:error, :repo_path_missing}
    else
      scan_repository(app.repo_path, root_path: nil, app: app, reason: reason)
    end
  end

  def scan_repository_roots(root_entries, opts \\ []) when is_list(root_entries) do
    root_entries
    |> Enum.flat_map(&repositories_for_root/1)
    |> Enum.uniq_by(& &1.repository_path)
    |> Enum.map(fn repo ->
      scan_repository(repo.repository_path,
        root_path: repo.root_path,
        reason: Keyword.get(opts, :reason, "root_scan")
      )
    end)
    |> summarize_results()
  end

  def enqueue_repository_root_scan(reason \\ "manual_enqueue") do
    %{"reason" => reason}
    |> ScanRepositoryRootsWorker.new()
    |> Oban.insert()
  end

  def scan_repository(path, opts \\ []) do
    attrs = scan_attrs(path, opts)
    app = Keyword.get(opts, :app) || Portfolio.match_app_by_cwd(attrs.repository_path)
    attrs = Map.put(attrs, :app_id, app && app.id)

    Repo.transaction(fn ->
      scan = upsert_scan!(attrs)
      maybe_update_app_health(app, scan)

      Events.record_event("repo_scan", scan.id, "repo_scanned", %{
        app_id: scan.app_id,
        repository_path: scan.repository_path,
        status: scan.status,
        dirty: scan.dirty
      })

      scan
    end)
    |> case do
      {:ok, scan} -> {:ok, Repo.preload(scan, :app)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp repositories_for_root(%{"path" => path}), do: repositories_for_root(path)
  defp repositories_for_root(%{path: path}), do: repositories_for_root(path)
  defp repositories_for_root(path) when not is_binary(path), do: []

  defp repositories_for_root(path) do
    root_path = Factory.expand_path(path)

    cond do
      not File.dir?(root_path) ->
        []

      git_repo?(root_path) ->
        [%{root_path: root_path, repository_path: root_path}]

      true ->
        root_path
        |> File.ls!()
        |> Enum.map(&Path.join(root_path, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.filter(&git_repo?/1)
        |> Enum.map(&%{root_path: root_path, repository_path: Factory.expand_path(&1)})
    end
  rescue
    _error -> []
  end

  defp scan_attrs(path, opts) do
    repository_path = Factory.expand_path(path)
    now = Factory.now()
    root_path = Keyword.get(opts, :root_path)
    reason = Keyword.get(opts, :reason, "manual_scan")

    base = %{
      repository_path: repository_path,
      root_path: root_path,
      name: Path.basename(repository_path),
      scan_reason: reason,
      scanned_at: now,
      platform_hints: platform_hints(repository_path)
    }

    cond do
      not File.dir?(repository_path) ->
        Map.merge(base, %{status: "missing", error: "Repository path does not exist."})

      not git_repo?(repository_path) ->
        Map.merge(base, %{status: "not_git", error: "Path is not a git repository."})

      true ->
        Map.merge(base, git_attrs(repository_path))
    end
  end

  defp git_attrs(path) do
    status_lines = git_lines(path, ["status", "--porcelain"])
    changed_count = Enum.count(status_lines, &(not String.starts_with?(&1, "??")))
    untracked_count = Enum.count(status_lines, &String.starts_with?(&1, "??"))
    dirty = changed_count + untracked_count > 0

    %{
      status: if(dirty, do: "dirty", else: "healthy"),
      dirty: dirty,
      changed_count: changed_count,
      untracked_count: untracked_count,
      branch: git_value(path, ["rev-parse", "--abbrev-ref", "HEAD"]),
      latest_commit_sha: latest_commit_field(path, 0),
      latest_commit_at: latest_commit_at(path),
      latest_commit_subject: latest_commit_field(path, 2),
      payload: %{
        "status_lines" => Enum.take(status_lines, 50)
      }
    }
  rescue
    error ->
      %{
        status: "error",
        error: Exception.message(error),
        payload: %{}
      }
  end

  defp latest_commit_field(path, index) do
    path
    |> latest_commit_parts()
    |> Enum.at(index)
    |> Factory.trim_nil()
  end

  defp latest_commit_at(path) do
    case latest_commit_field(path, 1) do
      nil ->
        nil

      seconds ->
        seconds
        |> String.to_integer()
        |> DateTime.from_unix!()
        |> DateTime.truncate(:microsecond)
    end
  rescue
    _error -> nil
  end

  defp latest_commit_parts(path) do
    path
    |> git_value(["log", "-1", "--format=%H%x00%ct%x00%s"])
    |> case do
      nil -> []
      value -> String.split(value, <<0>>)
    end
  end

  defp git_repo?(path), do: File.dir?(Path.join(path, ".git"))

  defp git_lines(path, args) do
    path
    |> git_value(args)
    |> case do
      nil -> []
      "" -> []
      value -> String.split(value, "\n", trim: true)
    end
  end

  defp git_value(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {_output, _status} -> nil
    end
  end

  defp platform_hints(path) do
    @platform_files
    |> Enum.flat_map(fn {platform, patterns} ->
      if Enum.any?(patterns, &path_matches?(path, &1)), do: [platform], else: []
    end)
    |> Enum.uniq()
  end

  defp path_matches?(path, pattern) do
    path
    |> Path.join(pattern)
    |> Path.wildcard()
    |> Enum.any?()
  end

  defp upsert_scan!(attrs) do
    case Repo.get_by(RepoScan, repository_path: attrs.repository_path) do
      nil ->
        %RepoScan{}
        |> RepoScan.changeset(attrs)
        |> Repo.insert!()

      scan ->
        scan
        |> RepoScan.changeset(attrs)
        |> Repo.update!()
    end
  end

  defp maybe_update_app_health(nil, _scan), do: :ok

  defp maybe_update_app_health(app, scan) do
    health_state =
      case scan.status do
        "missing" -> "repo_missing"
        "not_git" -> "repo_missing"
        "error" -> "blocked"
        "dirty" -> "repo_dirty"
        _status -> nil
      end

    if health_state do
      Portfolio.set_health_state(app, health_state, "Repository scan: #{scan.status}")
    else
      :ok
    end
  end

  defp summarize_results(results) do
    summary =
      Enum.reduce(results, %{scanned: 0, healthy: 0, attention: 0, errors: 0, scans: []}, fn
        {:ok, scan}, acc ->
          attention = scan.status in ["dirty", "missing", "not_git", "error"]

          %{
            acc
            | scanned: acc.scanned + 1,
              healthy: acc.healthy + if(scan.status == "healthy", do: 1, else: 0),
              attention: acc.attention + if(attention, do: 1, else: 0),
              scans: [scan | acc.scans]
          }

        {:error, _reason}, acc ->
          %{acc | errors: acc.errors + 1}
      end)

    {:ok, %{summary | scans: Enum.reverse(summary.scans)}}
  end

  defp apply_filter(query, _field, value) when value in [nil, ""], do: query

  defp apply_filter(query, field, value),
    do: where(query, [record], field(record, ^field) == ^value)
end
