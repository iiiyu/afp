# @input  - Factory domain statuses, labels, and compact UI content
# @output - Reusable Tailwind components for operational LiveViews
# @pos    - Presentation helper layer for the app-factory control plane
defmodule AfpWeb.FactoryComponents do
  use Phoenix.Component

  import AfpWeb.CoreComponents, only: [icon: 1]

  alias Afp.Factory

  attr :eyebrow, :string, default: nil
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :class, :any, default: nil
  slot :meta
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header class={[
      "w-full max-w-full rounded border border-slate-200 bg-white px-4 py-4 shadow-sm dark:border-slate-800 dark:bg-slate-900",
      @class
    ]}>
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div class="min-w-0">
          <div
            :if={@eyebrow}
            class="text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400"
          >
            {@eyebrow}
          </div>
          <h1 class="mt-1 text-xl font-semibold text-slate-950 dark:text-white">{@title}</h1>
          <p :if={@subtitle} class="mt-1 max-w-3xl text-sm text-slate-600 dark:text-slate-300">
            {@subtitle}
          </p>
          <div
            :if={@meta != []}
            class="mt-3 grid gap-2 sm:flex sm:flex-wrap sm:items-center"
          >
            {render_slot(@meta)}
          </div>
        </div>
        <div :if={@actions != []} class="flex shrink-0 flex-wrap items-center gap-2">
          {render_slot(@actions)}
        </div>
      </div>
    </header>
    """
  end

  attr :title, :string, required: true
  attr :class, :any, default: nil
  slot :subtitle
  slot :actions
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section class={[
      "w-full max-w-full rounded border border-slate-200 bg-white shadow-sm dark:border-slate-800 dark:bg-slate-900",
      @class
    ]}>
      <header class="flex items-start justify-between gap-4 border-b border-slate-100 px-4 py-3 dark:border-slate-800">
        <div class="min-w-0">
          <h2 class="truncate text-sm font-semibold text-slate-950 dark:text-white">{@title}</h2>
          <p :if={@subtitle != []} class="mt-0.5 text-xs text-slate-500 dark:text-slate-400">
            {render_slot(@subtitle)}
          </p>
        </div>
        <div :if={@actions != []} class="shrink-0">{render_slot(@actions)}</div>
      </header>
      <div class="p-4">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :open, :boolean, default: false
  attr :class, :any, default: nil
  slot :actions
  slot :inner_block, required: true

  def disclosure(assigns) do
    ~H"""
    <details
      open={@open}
      class={[
        "group border-t border-slate-200 py-3 first:border-t-0 dark:border-slate-800",
        @class
      ]}
    >
      <summary class="flex cursor-pointer list-none items-start justify-between gap-4">
        <div class="min-w-0">
          <h3 class="text-sm font-semibold text-slate-950 dark:text-white">{@title}</h3>
          <p :if={@subtitle} class="mt-0.5 text-xs text-slate-500 dark:text-slate-400">
            {@subtitle}
          </p>
        </div>
        <div class="flex shrink-0 items-center gap-2">
          <div :if={@actions != []}>{render_slot(@actions)}</div>
          <span class="rounded border border-slate-200 p-1 text-slate-500 group-open:hidden dark:border-slate-700">
            <.icon name="hero-chevron-down" class="size-3" />
          </span>
          <span class="hidden rounded border border-slate-200 p-1 text-slate-500 group-open:inline dark:border-slate-700">
            <.icon name="hero-chevron-up" class="size-3" />
          </span>
        </div>
      </summary>
      <div class="mt-3">
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :status, :string, default: nil
  attr :hint, :string, default: nil
  attr :navigate, :string, default: nil

  def summary_item(assigns) do
    ~H"""
    <.link
      :if={@navigate}
      navigate={@navigate}
      class="block min-w-0 rounded border border-slate-200 bg-white px-3 py-2 text-sm transition hover:border-slate-300 hover:bg-slate-50 dark:border-slate-800 dark:bg-slate-950 dark:hover:border-slate-700 dark:hover:bg-slate-900"
    >
      <.summary_item_content title={@title} value={@value} status={@status} hint={@hint} />
    </.link>
    <div
      :if={!@navigate}
      class="min-w-0 rounded border border-slate-200 bg-white px-3 py-2 text-sm dark:border-slate-800 dark:bg-slate-950"
    >
      <.summary_item_content title={@title} value={@value} status={@status} hint={@hint} />
    </div>
    """
  end

  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :status, :string, default: nil
  attr :hint, :string, default: nil

  defp summary_item_content(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-3">
      <div class="min-w-0">
        <div class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
          {@title}
        </div>
        <div class="mt-1 truncate font-semibold text-slate-950 dark:text-white">{@value}</div>
        <div :if={@hint} class="mt-0.5 truncate text-xs text-slate-500 dark:text-slate-400">
          {@hint}
        </div>
      </div>
      <.status_badge :if={@status} status={@status} />
    </div>
    """
  end

  attr :status, :string, required: true
  attr :class, :any, default: nil

  def status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded border px-2 py-0.5 text-xs font-medium",
      badge_class(@status),
      @class
    ]}>
      {Factory.labelize(@status)}
    </span>
    """
  end

  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, default: nil

  def stat(assigns) do
    ~H"""
    <div class="rounded border border-slate-200 bg-slate-50 px-3 py-2 dark:border-slate-800 dark:bg-slate-950">
      <div class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
        {@title}
      </div>
      <div class="mt-1 text-lg font-semibold text-slate-950 dark:text-white">{@value}</div>
      <div :if={@hint} class="text-xs text-slate-500 dark:text-slate-400">{@hint}</div>
    </div>
    """
  end

  attr :message, :string, required: true

  def empty_state(assigns) do
    ~H"""
    <div class="rounded border border-dashed border-slate-300 px-4 py-6 text-center text-sm text-slate-500 dark:border-slate-700 dark:text-slate-400">
      {@message}
    </div>
    """
  end

  def format_date(nil), do: "None"
  def format_date(%Date{} = date), do: Calendar.strftime(date, "%Y-%m-%d")

  def format_datetime(nil), do: "None"

  def format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end

  defp badge_class(status)
       when status in ["healthy", "passed", "done", "live", "reviewed", "ready_for_review"] do
    "border-emerald-200 bg-emerald-50 text-emerald-800 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-200"
  end

  defp badge_class(status)
       when status in [
              "blocked",
              "failed",
              "repo_missing",
              "not_git",
              "error",
              "needs_next_action",
              "release_blocked"
            ] do
    "border-red-200 bg-red-50 text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200"
  end

  defp badge_class(status)
       when status in [
              "review",
              "stopped",
              "waiting",
              "submitted",
              "waived",
              "metrics_stale",
              "repo_dirty",
              "dirty",
              "maintenance_due",
              "due",
              "growth_review"
            ] do
    "border-amber-200 bg-amber-50 text-amber-800 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-200"
  end

  defp badge_class(status)
       when status in ["running", "active", "in_build", "grow", "validation_sprint"] do
    "border-sky-200 bg-sky-50 text-sky-800 dark:border-sky-900 dark:bg-sky-950 dark:text-sky-200"
  end

  defp badge_class(_status) do
    "border-slate-200 bg-slate-50 text-slate-700 dark:border-slate-700 dark:bg-slate-900 dark:text-slate-200"
  end
end
