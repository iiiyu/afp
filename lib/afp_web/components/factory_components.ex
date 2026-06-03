# @input  - Factory domain statuses, labels, and compact UI content
# @output - Reusable Tailwind components for operational LiveViews
# @pos    - Presentation helper layer for the app-factory control plane
defmodule AfpWeb.FactoryComponents do
  use Phoenix.Component

  alias Afp.Factory

  attr :title, :string, required: true
  attr :class, :any, default: nil
  slot :subtitle
  slot :actions
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section class={[
      "rounded border border-slate-200 bg-white shadow-sm dark:border-slate-800 dark:bg-slate-900",
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
              "needs_next_action",
              "release_blocked"
            ] do
    "border-red-200 bg-red-50 text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200"
  end

  defp badge_class(status)
       when status in ["review", "stopped", "waiting", "submitted", "waived", "metrics_stale"] do
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
