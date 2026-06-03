# @input  - Local JSON Codex hook POST payloads
# @output - Durable hook event/session intake responses
# @pos    - HTTP receiver for the Codex session bridge
defmodule AfpWeb.CodexHookController do
  use AfpWeb, :controller

  alias Afp.Factory.Sessions

  plug AfpWeb.Plugs.LocalOnly

  def create(conn, params) do
    case Sessions.receive_hook(params) do
      {:ok, hook_event, session} ->
        json(conn, %{
          ok: true,
          hook_event_id: hook_event.id,
          codex_session_id: session && session.id,
          status: session && session.status
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{ok: false, errors: format_errors(changeset)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{ok: false, error: inspect(reason)})
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
