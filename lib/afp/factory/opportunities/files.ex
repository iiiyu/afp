# @input  - A configured opportunity repo map and opportunity id / relative path
# @output - Markdown/image file listings, single-file reads, and the file index
# @pos    - File-browser concern for opportunity repos: walk, classify, index, read
defmodule Afp.Factory.Opportunities.Files do
  @moduledoc """
  Walks an opportunity's files under the repo, classifies Markdown/image files,
  reads a single file safely (path-escape guarded), and refreshes the
  `opportunity_files` index in the repo-local SQLite. Callers resolve the repo
  (via the context's health check) and pass it in.
  """

  alias Afp.Factory.Opportunities.Storage

  @opportunities_path "opportunities"
  @image_extensions ~w(.png .jpg .jpeg .gif .webp)
  @markdown_extensions ~w(.md .markdown)

  @doc "Sorted Markdown/image files for an opportunity (README first)."
  def list(repo, opportunity_id) do
    with {:ok, root} <- opportunity_root(repo, opportunity_id) do
      files =
        root
        |> supported_files()
        |> Enum.map(&file_info(root, &1))
        |> Enum.sort_by(&file_sort_key/1)

      {:ok, files}
    end
  end

  @doc "Read one Markdown (text) or image (base64) file, guarding against path escape."
  def read(repo, opportunity_id, relative_path) do
    with {:ok, root} <- opportunity_root(repo, opportunity_id),
         {:ok, full_path} <- safe_child_path(root, relative_path),
         :ok <- ensure_supported_file(full_path),
         {:ok, type} <- file_type(full_path) do
      case type do
        "markdown" ->
          case File.read(full_path) do
            {:ok, content} -> {:ok, %{type: type, relative_path: relative_path, content: content}}
            {:error, reason} -> {:error, {:file_read_failed, reason}}
          end

        "image" ->
          case File.read(full_path) do
            {:ok, content} ->
              {:ok,
               %{
                 type: type,
                 relative_path: relative_path,
                 mime_type: mime_type(full_path),
                 data: Base.encode64(content)
               }}

            {:error, reason} ->
              {:error, {:file_read_failed, reason}}
          end
      end
    end
  end

  @doc "Upsert the opportunity_files index from the current on-disk files."
  def refresh_index(repo, opportunity_id) do
    with {:ok, files} <- list_opportunity_files_from_repo(repo, opportunity_id) do
      Storage.upsert_files(repo, opportunity_id, files)
    end
  end

  defp list_opportunity_files_from_repo(repo, opportunity_id) do
    with {:ok, root} <- opportunity_root(repo, opportunity_id) do
      files =
        root
        |> supported_files()
        |> Enum.map(&file_info(root, &1))

      {:ok, files}
    end
  end

  defp opportunity_root(%{"repo_path" => repo_path}, opportunity_id) do
    root = Path.join([repo_path, @opportunities_path, opportunity_id])

    if File.dir?(root) do
      {:ok, root}
    else
      {:error, :opportunity_files_missing}
    end
  end

  defp supported_files(root) do
    root
    |> walk_files()
    |> Enum.filter(&supported_file?/1)
  end

  defp walk_files(root) do
    case File.ls(root) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(root, entry)

          cond do
            File.dir?(path) -> walk_files(path)
            File.regular?(path) -> [path]
            true -> []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp supported_file?(path) do
    extension = path |> Path.extname() |> String.downcase()
    extension in @markdown_extensions or extension in @image_extensions
  end

  defp file_info(root, path) do
    stat = File.stat!(path, time: :posix)

    %{
      relative_path: path |> Path.relative_to(root) |> Path.split() |> Path.join(),
      type: elem(file_type(path), 1),
      size_bytes: stat.size,
      mtime: stat.mtime |> DateTime.from_unix!() |> DateTime.to_iso8601()
    }
  end

  defp file_sort_key(%{relative_path: "README.md"}), do: {0, "README.md"}
  defp file_sort_key(%{relative_path: path}), do: {1, path}

  defp safe_child_path(root, relative_path) do
    full_path = Path.expand(relative_path, root)
    expanded_root = Path.expand(root)

    if full_path == expanded_root or String.starts_with?(full_path, expanded_root <> "/") do
      {:ok, full_path}
    else
      {:error, :path_outside_opportunity}
    end
  end

  defp ensure_supported_file(path) do
    cond do
      not File.regular?(path) -> {:error, :file_missing}
      supported_file?(path) -> :ok
      true -> {:error, :unsupported_file_type}
    end
  end

  defp file_type(path) do
    extension = path |> Path.extname() |> String.downcase()

    cond do
      extension in @markdown_extensions -> {:ok, "markdown"}
      extension in @image_extensions -> {:ok, "image"}
      true -> {:error, :unsupported_file_type}
    end
  end

  defp mime_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      _extension -> "image/png"
    end
  end
end
