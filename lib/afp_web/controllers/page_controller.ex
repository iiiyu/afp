defmodule AfpWeb.PageController do
  use AfpWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
