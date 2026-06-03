# @input  - Repository root and Codex intake configuration form params
# @output - Settings LiveView for local operation
# @pos    - Operator configuration surface for repo roots, hook intake, and privacy defaults
defmodule AfpWeb.SettingsLive do
  use AfpWeb, :live_view

  alias Afp.Factory
  alias Afp.Factory.Events
  alias Afp.Factory.Settings

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:root_form, to_form(%{}, as: :root))
     |> load_settings()}
  end

  @impl true
  def handle_event("add_root", %{"root" => %{"path" => path}}, socket) do
    case Settings.add_repository_root(path) do
      {:ok, _setting} ->
        {:noreply, socket |> put_flash(:info, "Repository root added.") |> load_settings()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not add repository root.")}
    end
  end

  def handle_event("remove_root", %{"path" => path}, socket) do
    case Settings.remove_repository_root(path) do
      {:ok, _setting} ->
        {:noreply, socket |> put_flash(:info, "Repository root removed.") |> load_settings()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not remove repository root.")}
    end
  end

  def handle_event("update_intake", %{"intake" => params}, socket) do
    case Settings.update_intake_settings(params) do
      {:ok, _setting} ->
        {:noreply, socket |> put_flash(:info, "Intake settings saved.") |> load_settings()}

      {:error, :invalid_intake_mode} ->
        {:noreply, put_flash(socket, :error, "Invalid intake mode.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save intake settings.")}
    end
  end

  def handle_event("import_jsonl", _params, socket) do
    case Settings.import_jsonl_spool() do
      {:ok, result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Imported #{result.imported} JSONL hook events.")
         |> load_settings()}

      {:error, reason} ->
        {:noreply,
         socket |> put_flash(:error, "JSONL import failed: #{inspect(reason)}") |> load_settings()}
    end
  end

  def handle_event("enqueue_jsonl", _params, socket) do
    case Settings.enqueue_jsonl_import() do
      {:ok, _job} ->
        {:noreply, socket |> put_flash(:info, "JSONL import job enqueued.") |> load_settings()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not enqueue JSONL import.")}
    end
  end

  @impl true
  def handle_info({:factory_event, _event}, socket), do: {:noreply, load_settings(socket)}

  defp load_settings(socket) do
    intake = Settings.intake_settings()

    socket
    |> assign(:repository_roots, Settings.repository_roots())
    |> assign(:intake, intake)
    |> assign(:intake_form, to_form(intake, as: :intake))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="grid gap-4 xl:grid-cols-2">
        <.panel title="Repository Roots">
          <:subtitle>
            Roots make local app paths easier to audit and keep repository conventions visible.
          </:subtitle>
          <.form
            for={@root_form}
            id="repository-root-form"
            phx-submit="add_root"
            class="mb-4 flex gap-2"
          >
            <div class="flex-1">
              <.input field={@root_form[:path]} label="Path" placeholder="/Users/ewan/Developer/Apps" />
            </div>
            <div class="flex items-end">
              <.button type="submit" variant="primary">
                <.icon name="hero-plus" class="size-4" /> Add
              </.button>
            </div>
          </.form>

          <div :if={@repository_roots == []}>
            <.empty_state message="No repository roots configured." />
          </div>
          <div
            :for={root <- @repository_roots}
            class="mb-2 flex items-center justify-between gap-3 rounded border border-slate-200 p-3 text-sm dark:border-slate-800"
          >
            <div class="min-w-0">
              <div class="truncate font-medium">{root["path"]}</div>
              <div class="text-xs text-slate-500">
                {if root["valid"], do: "Readable", else: "Missing or unreadable"}
              </div>
            </div>
            <button
              type="button"
              phx-click="remove_root"
              phx-value-path={root["path"]}
              class="rounded border border-slate-300 px-2 py-1 text-xs font-medium hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800"
            >
              Remove
            </button>
          </div>
        </.panel>

        <.panel title="Codex Hook Intake">
          <:subtitle>
            HTTP receiver is local-only by default; JSONL import preserves raw payloads and uses offsets to avoid duplicate imports.
          </:subtitle>
          <.form for={@intake_form} id="intake-form" phx-submit="update_intake" class="space-y-2">
            <.input
              field={@intake_form[:intake_mode]}
              type="select"
              label="Intake mode"
              options={Factory.options(Factory.intake_modes())}
            />
            <.input field={@intake_form[:jsonl_spool_path]} label="JSONL spool path" />
            <.input
              field={@intake_form[:show_transcript_paths]}
              type="checkbox"
              label="Show transcript paths in UI"
            />
            <.input
              field={@intake_form[:evidence_storage_notes]}
              type="textarea"
              label="Evidence storage conventions"
              rows="3"
            />
            <.input
              field={@intake_form[:integration_notes]}
              type="textarea"
              label="Integration notes"
              rows="3"
            />
            <.button type="submit" variant="primary">Save intake settings</.button>
          </.form>

          <div class="mt-4 rounded border border-slate-200 bg-slate-50 p-3 text-sm dark:border-slate-800 dark:bg-slate-950">
            <div class="font-medium">HTTP receiver</div>
            <code class="mt-1 block text-xs text-slate-600 dark:text-slate-300">
              POST http://127.0.0.1:4000/api/codex/hooks
            </code>
            <div class="mt-1 text-xs text-slate-500">Loopback requests only.</div>
          </div>

          <div class="mt-4 flex gap-2">
            <button
              type="button"
              phx-click="import_jsonl"
              class="rounded border border-slate-300 px-3 py-2 text-sm font-medium hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800"
            >
              Import JSONL now
            </button>
            <button
              type="button"
              phx-click="enqueue_jsonl"
              class="rounded border border-slate-300 px-3 py-2 text-sm font-medium hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800"
            >
              Enqueue import job
            </button>
          </div>

          <div
            :if={@intake["intake_errors"] != []}
            class="mt-4 rounded border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200"
          >
            <div class="font-medium">Integration errors</div>
            <ul class="mt-2 list-disc pl-5">
              <li :for={error <- @intake["intake_errors"]}>{error}</li>
            </ul>
          </div>
        </.panel>
      </div>
    </Layouts.app>
    """
  end
end
