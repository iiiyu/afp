# @input  - User-submitted params, dates, paths, and compact text fields
# @output - Shared factory constants and normalization helpers
# @pos    - Cross-context utility module for the one-person app factory domain
defmodule Afp.Factory do
  @lifecycle_stages ~w(idea validation_ready validation_sprint build_ready in_build release_ready submitted live iterating maintained paused archived)
  @business_postures ~w(unknown grow maintain fix harvest pause kill)
  @health_states ~w(unknown healthy needs_next_action repo_missing repo_dirty blocked archived)

  def lifecycle_stages, do: @lifecycle_stages
  def business_postures, do: @business_postures
  def health_states, do: @health_states

  def options(values), do: Enum.map(values, &{labelize(&1), &1})

  def now do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
  end

  def blank?(value), do: value in [nil, ""]
  def present?(value), do: not blank?(value)

  def trim_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def trim_nil(value), do: value

  def slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "app"
      slug -> slug
    end
  end

  def slugify(_value), do: "app"

  def normalize_platforms(platforms) when is_binary(platforms) do
    platforms
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  def normalize_platforms(platforms) when is_list(platforms) do
    platforms
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  def normalize_platforms(_platforms), do: []

  def lines_to_list(value) when is_binary(value) do
    value
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&blank?/1)
  end

  def lines_to_list(value) when is_list(value), do: value
  def lines_to_list(_value), do: []

  def labelize(value) when is_atom(value), do: value |> Atom.to_string() |> labelize()

  def labelize(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def labelize(value), do: to_string(value)

  def repo_path_matches?(nil, _cwd), do: false
  def repo_path_matches?("", _cwd), do: false
  def repo_path_matches?(_repo_path, nil), do: false
  def repo_path_matches?(_repo_path, ""), do: false

  def repo_path_matches?(repo_path, cwd) do
    repo = expand_path(repo_path)
    current = expand_path(cwd)

    current == repo or String.starts_with?(current, repo <> "/")
  end

  def expand_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> Path.expand()
    |> Path.join("")
    |> String.trim_trailing("/")
  end

  def expand_path(path), do: path
end
