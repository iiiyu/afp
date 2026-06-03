# @input  - Ecto.Type callbacks and JSON-compatible Elixir terms
# @output - Flexible jsonb-backed type for maps, arrays, and primitive values
# @pos    - Persistence adapter for PRD fields that intentionally store structured jsonb
defmodule Afp.Factory.JsonData do
  use Ecto.Type

  @impl true
  def type, do: :map

  @impl true
  def cast(value) when is_map(value) or is_list(value), do: {:ok, value}
  def cast(value) when is_binary(value), do: decode_or_string(value)
  def cast(value) when is_boolean(value) or is_number(value) or is_nil(value), do: {:ok, value}
  def cast(_value), do: :error

  @impl true
  def dump(value) when is_map(value) or is_list(value), do: {:ok, value}

  def dump(value) when is_binary(value) or is_boolean(value) or is_number(value) or is_nil(value),
    do: {:ok, value}

  def dump(_value), do: :error

  @impl true
  def load(value), do: {:ok, value}

  defp decode_or_string(""), do: {:ok, %{}}

  defp decode_or_string(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _error} -> {:ok, value}
    end
  end
end
