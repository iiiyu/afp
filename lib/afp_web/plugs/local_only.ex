# @input  - Plug connections with remote IP metadata
# @output - Loopback-only access enforcement for local integration endpoints
# @pos    - Safety boundary for Codex hook receiver routes
defmodule AfpWeb.Plugs.LocalOnly do
  import Plug.Conn

  @loopback_v4 {127, 0, 0, 1}
  @loopback_v6 {0, 0, 0, 0, 0, 0, 0, 1}

  def init(opts), do: opts

  def call(%Plug.Conn{remote_ip: remote_ip} = conn, _opts)
      when remote_ip in [@loopback_v4, @loopback_v6] do
    conn
  end

  def call(conn, _opts) do
    conn
    |> send_resp(:forbidden, "local hook receiver only accepts loopback requests")
    |> halt()
  end
end
