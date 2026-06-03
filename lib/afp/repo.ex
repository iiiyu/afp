defmodule Afp.Repo do
  use Ecto.Repo,
    otp_app: :afp,
    adapter: Ecto.Adapters.Postgres
end
