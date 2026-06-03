# @input  - Local configuration keys and jsonb values
# @output - Durable settings rows
# @pos    - Settings schema for repository roots and Codex intake configuration
defmodule Afp.Factory.Settings.Setting do
  use Afp.Factory.Schema

  alias Afp.Factory.JsonData

  schema "settings" do
    field :key, :string
    field :value, JsonData, default: %{}

    timestamps()
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key, :value])
    |> unique_constraint(:key)
  end
end
