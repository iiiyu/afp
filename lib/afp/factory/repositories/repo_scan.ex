# @input  - Repository scanner output, app matches, and filesystem metadata
# @output - Persisted repository scan records for portfolio health decisions
# @pos    - Schema for local repository scan snapshots in the operating loop
defmodule Afp.Factory.Repositories.RepoScan do
  use Afp.Factory.Schema

  alias Afp.Factory
  alias Afp.Factory.JsonData

  schema "repo_scans" do
    field :root_path, :string
    field :repository_path, :string
    field :name, :string
    field :status, :string, default: "unknown"
    field :branch, :string
    field :dirty, :boolean, default: false
    field :changed_count, :integer, default: 0
    field :untracked_count, :integer, default: 0
    field :latest_commit_sha, :string
    field :latest_commit_subject, :string
    field :latest_commit_at, :utc_datetime_usec
    field :platform_hints, {:array, :string}, default: []
    field :scan_reason, :string
    field :error, :string
    field :payload, JsonData, default: %{}
    field :scanned_at, :utc_datetime_usec

    belongs_to :app, Afp.Factory.Portfolio.App

    timestamps()
  end

  def changeset(scan, attrs) do
    attrs = normalize_attrs(attrs)

    scan
    |> cast(attrs, [
      :app_id,
      :root_path,
      :repository_path,
      :name,
      :status,
      :branch,
      :dirty,
      :changed_count,
      :untracked_count,
      :latest_commit_sha,
      :latest_commit_subject,
      :latest_commit_at,
      :platform_hints,
      :scan_reason,
      :error,
      :payload,
      :scanned_at
    ])
    |> normalize_text_fields([
      :root_path,
      :repository_path,
      :name,
      :status,
      :branch,
      :latest_commit_sha,
      :latest_commit_subject,
      :scan_reason,
      :error
    ])
    |> put_default(:status, "unknown")
    |> put_default(:dirty, false)
    |> put_default(:changed_count, 0)
    |> put_default(:untracked_count, 0)
    |> put_default(:scanned_at, Factory.now())
    |> validate_required([:repository_path, :status, :dirty, :scanned_at])
    |> validate_inclusion(:status, Factory.repo_scan_statuses())
    |> validate_number(:changed_count, greater_than_or_equal_to: 0)
    |> validate_number(:untracked_count, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:app_id)
    |> unique_constraint(:repository_path)
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    attrs
    |> normalize_platform_hints()
    |> normalize_path(:root_path)
    |> normalize_path(:repository_path)
  end

  defp normalize_attrs(attrs), do: attrs

  defp normalize_platform_hints(attrs) do
    value = Map.get(attrs, "platform_hints") || Map.get(attrs, :platform_hints)

    put_existing(attrs, :platform_hints, Factory.normalize_platforms(value))
  end

  defp normalize_path(attrs, field) do
    value = Map.get(attrs, Atom.to_string(field)) || Map.get(attrs, field)

    if is_binary(value) and Factory.present?(value) do
      put_existing(attrs, field, Factory.expand_path(value))
    else
      attrs
    end
  end

  defp normalize_text_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      value = get_change(acc, field)

      if is_binary(value) do
        put_change(acc, field, Factory.trim_nil(value))
      else
        acc
      end
    end)
  end

  defp put_default(changeset, field, default) do
    if Factory.blank?(get_field(changeset, field)) do
      put_change(changeset, field, default)
    else
      changeset
    end
  end

  defp put_existing(attrs, field, value) do
    string_key = Atom.to_string(field)

    cond do
      Map.has_key?(attrs, string_key) -> Map.put(attrs, string_key, value)
      Map.has_key?(attrs, field) -> Map.put(attrs, field, value)
      true -> attrs
    end
  end
end
