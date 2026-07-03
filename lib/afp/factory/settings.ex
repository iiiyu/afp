# @input  - Setting keys and jsonb-compatible values
# @output - Local settings persistence with audit events
# @pos    - Context boundary for operator-configurable local state (key/value)
defmodule Afp.Factory.Settings do
  alias Afp.Factory.Events
  alias Afp.Factory.Settings.Setting
  alias Afp.Repo

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
end
