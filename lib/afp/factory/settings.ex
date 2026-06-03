# @input  - Repository root paths, intake mode params, and JSONL spool files
# @output - Local settings persistence, validation status, and import jobs
# @pos    - Context boundary for operator-configurable local operation
defmodule Afp.Factory.Settings do
  alias Afp.Factory
  alias Afp.Factory.Events
  alias Afp.Factory.Sessions
  alias Afp.Factory.Settings.ImportJsonlSpoolWorker
  alias Afp.Factory.Settings.Setting
  alias Afp.Repo

  @repository_roots_key "repository_roots"
  @intake_key "codex_intake"
  @jsonl_offsets_key "jsonl_spool_offsets"

  def get_setting(key, default \\ %{}) do
    case Repo.get_by(Setting, key: key) do
      nil -> default
      %Setting{value: value} -> value
    end
  end

  def put_setting(key, value) do
    existing = Repo.get_by(Setting, key: key) || %Setting{}

    existing
    |> Setting.changeset(%{key: key, value: value})
    |> Repo.insert_or_update()
    |> case do
      {:ok, setting} ->
        Events.record_event("setting", setting.id, "setting_updated", %{key: key})
        {:ok, setting}

      result ->
        result
    end
  end

  def repository_roots do
    get_setting(@repository_roots_key, [])
  end

  def add_repository_root(path) do
    root = %{
      "path" => path,
      "valid" => File.dir?(Factory.expand_path(path || "")),
      "added_at" => DateTime.to_iso8601(Factory.now())
    }

    roots =
      repository_roots()
      |> Enum.reject(&(&1["path"] == path))
      |> Kernel.++([root])

    put_setting(@repository_roots_key, roots)
  end

  def remove_repository_root(path) do
    roots = Enum.reject(repository_roots(), &(&1["path"] == path))
    put_setting(@repository_roots_key, roots)
  end

  def intake_settings do
    defaults = %{
      "intake_mode" => "neither",
      "jsonl_spool_path" => nil,
      "http_receiver_enabled" => false,
      "show_transcript_paths" => false,
      "evidence_storage_notes" => "",
      "integration_notes" => "",
      "intake_errors" => []
    }

    Map.merge(defaults, get_setting(@intake_key, %{}))
  end

  def update_intake_settings(attrs) do
    mode = Map.get(attrs, "intake_mode") || Map.get(attrs, :intake_mode) || "neither"
    path = Map.get(attrs, "jsonl_spool_path") || Map.get(attrs, :jsonl_spool_path)

    show_transcript_paths =
      truthy?(Map.get(attrs, "show_transcript_paths") || Map.get(attrs, :show_transcript_paths))

    evidence_storage_notes =
      Map.get(attrs, "evidence_storage_notes") || Map.get(attrs, :evidence_storage_notes) || ""

    integration_notes =
      Map.get(attrs, "integration_notes") || Map.get(attrs, :integration_notes) || ""

    cond do
      mode not in Factory.intake_modes() ->
        {:error, :invalid_intake_mode}

      true ->
        errors = validate_intake_errors(mode, path)

        put_setting(@intake_key, %{
          "intake_mode" => mode,
          "jsonl_spool_path" => Factory.trim_nil(path),
          "http_receiver_enabled" => mode in ["http", "both"],
          "show_transcript_paths" => show_transcript_paths,
          "evidence_storage_notes" => evidence_storage_notes,
          "integration_notes" => integration_notes,
          "intake_errors" => errors
        })
    end
  end

  def enqueue_jsonl_import(path \\ nil) do
    %{path: path}
    |> ImportJsonlSpoolWorker.new()
    |> Oban.insert()
  end

  def import_jsonl_spool(path \\ nil) do
    path = path || intake_settings()["jsonl_spool_path"]

    cond do
      Factory.blank?(path) ->
        {:error, :jsonl_spool_path_missing}

      not File.exists?(Factory.expand_path(path)) ->
        record_intake_error("JSONL spool path does not exist: #{path}")

      true ->
        do_import_jsonl_spool(Factory.expand_path(path))
    end
  end

  defp do_import_jsonl_spool(path) do
    content = File.read!(path)
    offsets = get_setting(@jsonl_offsets_key, %{})
    previous_offset = Map.get(offsets, path, 0)
    current_size = byte_size(content)
    offset = if previous_offset > current_size, do: 0, else: previous_offset
    new_content = binary_part(content, offset, current_size - offset)

    result =
      new_content
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{imported: 0, errors: []}, fn line, acc ->
        case Jason.decode(line) do
          {:ok, payload} ->
            case Sessions.receive_hook(payload) do
              {:ok, _hook_event, _session} -> %{acc | imported: acc.imported + 1}
              {:error, reason} -> %{acc | errors: [inspect(reason) | acc.errors]}
            end

          {:error, error} ->
            %{acc | errors: [Exception.message(error) | acc.errors]}
        end
      end)

    offsets
    |> Map.put(path, current_size)
    |> then(&put_setting(@jsonl_offsets_key, &1))

    if result.errors == [] do
      {:ok, result}
    else
      record_intake_error(
        "JSONL import completed with errors: #{Enum.join(Enum.reverse(result.errors), "; ")}"
      )
    end
  end

  defp record_intake_error(message) do
    settings = intake_settings()
    errors = [message | settings["intake_errors"] || []] |> Enum.take(10)
    put_setting(@intake_key, Map.put(settings, "intake_errors", errors))
    {:error, message}
  end

  defp validate_intake_errors(mode, path) when mode in ["jsonl", "both"] do
    cond do
      Factory.blank?(path) -> ["JSONL spool path is required for #{mode} intake."]
      not File.exists?(Factory.expand_path(path)) -> ["JSONL spool path does not exist."]
      not File.regular?(Factory.expand_path(path)) -> ["JSONL spool path is not a file."]
      true -> []
    end
  end

  defp validate_intake_errors(_mode, _path), do: []

  defp truthy?(value), do: value in [true, "true", "1", 1, "on"]
end
