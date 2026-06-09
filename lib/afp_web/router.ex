defmodule AfpWeb.Router do
  use AfpWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AfpWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AfpWeb do
    pipe_through :browser

    live "/", TodayLive
    live "/today", TodayLive
    live "/opportunities", OpportunitiesLive
    live "/opportunities/:id", OpportunitiesLive
    live "/demand", DemandLive
    live "/apps", AppLive.Index
    live "/apps/:id", AppLive.Show
    live "/board", BoardLive
    live "/sessions", SessionsLive
    live "/releases", ReleasesLive
    live "/evidence", EvidenceLive
    live "/metrics", MetricsLive
    live "/settings", SettingsLive
  end

  scope "/api", AfpWeb do
    pipe_through :api

    post "/codex/hooks", CodexHookController, :create
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:afp, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AfpWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
