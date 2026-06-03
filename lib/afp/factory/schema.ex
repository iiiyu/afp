# @input  - Ecto.Schema and repository-wide persistence conventions
# @output - Shared schema defaults for factory data models
# @pos    - Local architecture helper for UUID primary keys and microsecond timestamps
defmodule Afp.Factory.Schema do
  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      import Ecto.Changeset

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end
end
