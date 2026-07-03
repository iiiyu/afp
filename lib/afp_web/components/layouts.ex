defmodule AfpWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use AfpWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen lg:grid lg:grid-cols-[16rem_minmax(0,1fr)]">
      <aside class="sticky top-0 z-40 hidden h-screen flex-col border-r border-slate-200 bg-white/95 backdrop-blur dark:border-slate-800 dark:bg-slate-950/95 lg:flex">
        <div class="flex min-h-16 items-center border-b border-slate-100 px-3 dark:border-slate-900 lg:px-4">
          <.link
            navigate={~p"/opportunities"}
            class="flex min-w-0 items-center gap-3 text-sm font-semibold"
            title="App Factory"
          >
            <span class="flex size-8 items-center justify-center rounded bg-slate-950 text-white dark:bg-white dark:text-slate-950">
              AFP
            </span>
            <span class="hidden truncate lg:inline">App Factory</span>
          </.link>
        </div>

        <div class="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-2 py-4 lg:px-3">
          <nav class="flex flex-col gap-1 text-sm">
            <.nav_item
              navigate={~p"/opportunities"}
              icon="hero-magnifying-glass"
              label="Opportunities"
            />
            <.nav_item navigate={~p"/apps"} icon="hero-rectangle-stack" label="Apps" />
          </nav>
        </div>

        <div class="border-t border-slate-100 px-2 py-3 dark:border-slate-900 lg:px-3">
          <.theme_toggle class="mx-auto flex-col lg:flex-row" />
        </div>
      </aside>

      <main class="min-w-0 px-4 py-4 pb-20 sm:px-6 lg:px-8 lg:pb-4">
        <div class="mx-auto w-full min-w-0 max-w-[1800px] space-y-4">
          {render_slot(@inner_block)}
        </div>
      </main>

      <nav class="fixed inset-x-0 bottom-0 z-40 border-t border-slate-200 bg-white/95 px-2 py-2 backdrop-blur dark:border-slate-800 dark:bg-slate-950/95 lg:hidden">
        <div class="flex items-center justify-between gap-1">
          <.nav_icon_item
            navigate={~p"/opportunities"}
            icon="hero-magnifying-glass"
            label="Opportunities"
          />
          <.nav_icon_item navigate={~p"/apps"} icon="hero-rectangle-stack" label="Apps" />
        </div>
      </nav>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp nav_item(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      aria-label={@label}
      title={@label}
      class="flex min-h-10 items-center justify-center gap-3 rounded px-3 py-2 text-slate-600 transition hover:bg-slate-100 hover:text-slate-950 dark:text-slate-300 dark:hover:bg-slate-900 dark:hover:text-white lg:justify-start"
    >
      <.icon name={@icon} class="size-4" />
      <span class="hidden truncate lg:inline">{@label}</span>
    </.link>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp nav_icon_item(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      aria-label={@label}
      title={@label}
      class="flex size-9 items-center justify-center rounded text-slate-600 transition hover:bg-slate-100 hover:text-slate-950 dark:text-slate-300 dark:hover:bg-slate-900 dark:hover:text-white"
    >
      <.icon name={@icon} class="size-4" />
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  attr :class, :any, default: nil

  def theme_toggle(assigns) do
    ~H"""
    <div class={[
      "flex items-center rounded border border-slate-200 bg-white p-0.5 dark:border-slate-800 dark:bg-slate-900",
      @class
    ]}>
      <button
        class="rounded p-1.5 text-slate-500 transition hover:bg-slate-100 hover:text-slate-950 dark:text-slate-400 dark:hover:bg-slate-800 dark:hover:text-white"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        title="System theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="rounded p-1.5 text-slate-500 transition hover:bg-slate-100 hover:text-slate-950 dark:text-slate-400 dark:hover:bg-slate-800 dark:hover:text-white"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        title="Light theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="rounded p-1.5 text-slate-500 transition hover:bg-slate-100 hover:text-slate-950 dark:text-slate-400 dark:hover:bg-slate-800 dark:hover:text-white"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        title="Dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
