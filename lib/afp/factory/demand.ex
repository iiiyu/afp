# @input  - Demand source, candidate, run, template, launch, and promotion params
# @output - Demand control-plane queries, source indexing, launch handoffs, and promotion
# @pos    - Context boundary for upstream demand repos and human-confirmed Codex work
defmodule Afp.Factory.Demand do
  import Ecto.Query

  alias Afp.Factory
  alias Afp.Factory.Demand.Candidate
  alias Afp.Factory.Demand.Candidates
  alias Afp.Factory.Demand.CodexLaunch
  alias Afp.Factory.Demand.CodexLaunchRequest
  alias Afp.Factory.Demand.DemandItem
  alias Afp.Factory.Demand.Items
  alias Afp.Factory.Demand.LaunchWorkflow
  alias Afp.Factory.Demand.MessageTemplate
  alias Afp.Factory.Demand.ResearchRun
  alias Afp.Factory.Demand.ScheduleResearchWorker
  alias Afp.Factory.Demand.SourceManifest
  alias Afp.Factory.Demand.SourceRepo
  alias Afp.Factory.Demand.SourceRepoAdapter
  alias Afp.Factory.Demand.SourceRepoScaffold
  alias Afp.Factory.Events
  alias Afp.Factory.Sessions.CodexSession
  alias Afp.Repo

  @filter_attr_atoms %{
    "status" => :status,
    "confidence" => :confidence,
    "source" => :source,
    "risk_level" => :risk_level,
    "health_state" => :health_state,
    "lane" => :lane,
    "source_status" => :source_status,
    "afp_status" => :afp_status,
    "demand_source_repo_id" => :demand_source_repo_id,
    "run_type" => :run_type,
    "active" => :active
  }

  @general_attr_atoms %{
    "repo_path" => :repo_path,
    "manifest_path" => :manifest_path,
    "display_name" => :display_name,
    "edited_body" => :edited_body,
    "status" => :status,
    "title" => :title,
    "objective" => :objective,
    "risk_level" => :risk_level,
    "launch_mode" => :launch_mode,
    "confirmation" => :confirmation,
    "demand_status" => :demand_status,
    "run_type" => :run_type,
    "lane" => :lane,
    "input_text" => :input_text,
    "input_url" => :input_url,
    "review_note" => :review_note,
    "schedule_enabled" => :schedule_enabled,
    "schedule_interval_hours" => :schedule_interval_hours
  }

  def list_source_repos(params \\ %{}) do
    SourceRepo
    |> apply_filter(:health_state, filter_value(params, "health_state"))
    |> order_by([source], asc: source.display_name)
    |> Repo.all()
    |> Repo.preload([:candidates, :research_runs])
  end

  def get_source_repo!(id) do
    SourceRepo
    |> Repo.get!(id)
    |> Repo.preload([:candidates, :research_runs])
  end

  def change_source_repo(%SourceRepo{} = source_repo, attrs \\ %{}) do
    SourceRepo.changeset(source_repo, attrs)
  end

  def create_source_repo(attrs) do
    attrs =
      attrs
      |> source_repo_inspection_attrs()
      |> Map.put_new("schedule_enabled", false)

    %SourceRepo{}
    |> SourceRepo.changeset(attrs)
    |> Repo.insert()
    |> after_source_repo_write("demand_source_created")
  end

  def create_source_repo_from_template(attrs) do
    with {:ok, scaffold_attrs} <- SourceRepoScaffold.create(attrs) do
      create_source_repo(scaffold_attrs)
    end
  end

  def update_source_repo(%SourceRepo{} = source_repo, attrs) do
    source_repo
    |> SourceRepo.changeset(attrs)
    |> Repo.update()
    |> after_source_repo_write("demand_source_updated")
  end

  def refresh_source_repo(%SourceRepo{} = source_repo) do
    source_repo
    |> update_source_repo(source_repo_inspection_attrs(source_repo))
  end

  def refresh_source_repo_index(%SourceRepo{} = source_repo) do
    with {:ok, refreshed_source_repo} <- refresh_source_repo(source_repo),
         :ok <- ensure_source_indexable(refreshed_source_repo),
         {:ok, candidate_attrs} <- SourceRepoAdapter.read_candidates(refreshed_source_repo) do
      Repo.transaction(fn ->
        indexed_candidates =
          Enum.map(candidate_attrs, fn attrs ->
            case Candidates.index_candidate(refreshed_source_repo, attrs) do
              {:ok, candidate} -> candidate
              {:error, changeset} -> Repo.rollback(changeset)
            end
          end)

        latest_index_at = Factory.now()

        source_repo =
          refreshed_source_repo
          |> SourceRepo.changeset(%{
            "latest_index_at" => latest_index_at,
            "payload" =>
              Map.merge(refreshed_source_repo.payload || %{}, %{
                "latest_index" => %{
                  "candidate_count" => length(indexed_candidates),
                  "indexed_at" => DateTime.to_iso8601(latest_index_at)
                }
              })
          })
          |> Repo.update!()

        {:ok, research_run} =
          LaunchWorkflow.create_research_run(%{
            "demand_source_repo_id" => source_repo.id,
            "run_type" => "repo_audit",
            "objective" => "Refresh AFP index from repo-local SQLite candidates.",
            "output_paths" => [source_repo.sqlite_path || "demand.sqlite3"],
            "status" => "completed",
            "completed_at" => latest_index_at,
            "payload" => %{
              "adapter" => "sqlite3",
              "candidate_count" => length(indexed_candidates)
            }
          })

        %{
          source_repo: Repo.preload(source_repo, [:candidates, :research_runs]),
          candidates:
            Enum.map(indexed_candidates, &Repo.preload(&1, [:source_repo, :demand_item])),
          research_run: research_run
        }
      end)
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def list_due_scheduled_source_repos(opts \\ []) do
    force? = Keyword.get(opts, :force, false)
    now = Keyword.get(opts, :now, Factory.now())

    SourceRepo
    |> where([source], source.schedule_enabled == true and source.health_state == "healthy")
    |> order_by([source], asc: source.last_run_at, asc: source.display_name)
    |> Repo.all()
    |> Enum.filter(&scheduled_source_due?(&1, now, force?))
  end

  def enqueue_scheduled_research(reason \\ "manual_enqueue") do
    %{"reason" => reason}
    |> ScheduleResearchWorker.new()
    |> Oban.insert()
  end

  def run_scheduled_research(opts \\ []) do
    sources = list_due_scheduled_source_repos(force: Keyword.get(opts, :force, false))
    template = ensure_scheduled_scan_template!()

    results =
      Enum.map(sources, fn source_repo ->
        create_source_launch_request(source_repo, template, %{
          "run_type" => "scheduled_scan",
          "lane" => List.first(source_repo.lanes || ["app"]) || "app",
          "input_text" => "Scheduled demand scan",
          "objective" => "Run scheduled market scan for #{source_repo.display_name}.",
          "risk_level" => "normal",
          "status" => "draft"
        })
      end)

    summary = %{
      considered: length(sources),
      created: Enum.count(results, &match?({:ok, _records}, &1)),
      errors: Enum.count(results, &match?({:error, _reason}, &1)),
      results: results
    }

    {:ok, summary}
  end

  def source_repo_inspection_attrs(%SourceRepo{} = source_repo) do
    source_repo
    |> Map.from_struct()
    |> Map.take([
      :repo_path,
      :display_name,
      :manifest_path,
      :schedule_enabled,
      :schedule_interval_hours
    ])
    |> source_repo_inspection_attrs()
  end

  def source_repo_inspection_attrs(attrs) when is_map(attrs) do
    repo_path = attrs |> attr_value_or_atom("repo_path") |> normalize_repo_path()

    manifest_path =
      Factory.trim_nil(attr_value_or_atom(attrs, "manifest_path")) || "afp-demand-source.json"

    now = Factory.now()

    base =
      %{
        "repo_path" => repo_path,
        "display_name" =>
          Factory.trim_nil(attr_value_or_atom(attrs, "display_name")) ||
            display_name_from_repo_path(repo_path),
        "manifest_path" => manifest_path,
        "latest_scan_at" => now
      }
      |> copy_existing_attr(attrs, "schedule_enabled")
      |> copy_existing_attr(attrs, "schedule_interval_hours")

    cond do
      Factory.blank?(repo_path) ->
        Map.merge(base, %{
          "health_state" => "missing",
          "health_summary" => "Repository path is required.",
          "missing_paths" => []
        })

      not File.dir?(repo_path) ->
        Map.merge(base, %{
          "health_state" => "missing",
          "health_summary" => "Repository path does not exist.",
          "missing_paths" => [repo_path]
        })

      true ->
        SourceManifest.inspect_repo(base, repo_path, manifest_path)
    end
  end

  def source_repo_inspection_attrs(_attrs), do: source_repo_inspection_attrs(%{})

  def list_candidates(params \\ %{}), do: Candidates.list_candidates(params)

  def list_pickup_candidates, do: Candidates.list_pickup_candidates()

  def list_package_candidates, do: Candidates.list_package_candidates()

  def list_handoff_candidates, do: Candidates.list_handoff_candidates()

  def get_candidate!(id), do: Candidates.get_candidate!(id)

  def change_candidate(%Candidate{} = candidate, attrs \\ %{}) do
    Candidates.change_candidate(candidate, attrs)
  end

  def index_candidate(%SourceRepo{} = source_repo, attrs),
    do: Candidates.index_candidate(source_repo, attrs)

  def update_candidate(%Candidate{} = candidate, attrs),
    do: Candidates.update_candidate(candidate, attrs)

  def transition_candidate(%Candidate{} = candidate, afp_status, attrs \\ %{}),
    do: Candidates.transition_candidate(candidate, afp_status, attrs)

  def pick_up_candidate(%Candidate{} = candidate, attrs \\ %{}),
    do: Candidates.pick_up_candidate(candidate, attrs)

  def approve_candidate_package(%Candidate{} = candidate, attrs \\ %{}),
    do: Candidates.approve_candidate_package(candidate, attrs)

  def inspect_candidate_package(%Candidate{} = candidate),
    do: Candidates.inspect_candidate_package(candidate)

  def verify_candidate_package(%Candidate{} = candidate, attrs \\ %{}),
    do: Candidates.verify_candidate_package(candidate, attrs)

  def mark_candidate_handoff_ready(%Candidate{} = candidate, attrs \\ %{}),
    do: Candidates.mark_candidate_handoff_ready(candidate, attrs)

  def list_research_runs(params \\ %{}) do
    ResearchRun
    |> apply_filter(:demand_source_repo_id, filter_value(params, "demand_source_repo_id"))
    |> apply_filter(:run_type, filter_value(params, "run_type"))
    |> apply_filter(:status, filter_value(params, "status"))
    |> order_by([run], desc: run.updated_at)
    |> Repo.all()
    |> Repo.preload([
      :source_repo,
      :candidate,
      :message_template,
      :launch_request,
      :codex_session
    ])
  end

  def reconcile_stale_running_research_runs(opts \\ []),
    do: CodexLaunch.reconcile_stale_running_research_runs(opts)

  def get_research_run!(id) do
    ResearchRun
    |> Repo.get!(id)
    |> Repo.preload([
      :source_repo,
      :candidate,
      :message_template,
      :launch_request,
      :codex_session
    ])
  end

  def change_research_run(%ResearchRun{} = research_run, attrs \\ %{}) do
    ResearchRun.changeset(research_run, attrs)
  end

  def create_research_run(attrs), do: LaunchWorkflow.create_research_run(attrs)

  def list_message_templates(params \\ %{}) do
    MessageTemplate
    |> apply_active_filter(filter_value(params, "active"))
    |> order_by([template], asc: template.name)
    |> Repo.all()
  end

  def get_message_template!(id), do: Repo.get!(MessageTemplate, id)

  def change_message_template(%MessageTemplate{} = template, attrs \\ %{}) do
    MessageTemplate.changeset(template, attrs)
  end

  def create_message_template(attrs) do
    %MessageTemplate{}
    |> MessageTemplate.changeset(attrs)
    |> Repo.insert()
    |> after_message_template_write("demand_message_template_created")
  end

  def render_message_template(%MessageTemplate{} = template, variables) when is_map(variables),
    do: LaunchWorkflow.render_message_template(template, variables)

  def create_source_launch_request(
        %SourceRepo{} = source_repo,
        %MessageTemplate{} = template,
        attrs
      ),
      do: LaunchWorkflow.create_source_launch_request(source_repo, template, attrs)

  def create_candidate_launch_request(
        %Candidate{} = candidate,
        %MessageTemplate{} = template,
        attrs
      ),
      do: LaunchWorkflow.create_candidate_launch_request(candidate, template, attrs)

  def create_session_followup(
        %ResearchRun{} = research_run,
        %CodexSession{} = codex_session,
        %MessageTemplate{} = template,
        attrs
      ),
      do: LaunchWorkflow.create_session_followup(research_run, codex_session, template, attrs)

  def list_demand_items(params \\ %{}), do: Items.list_demand_items(params)

  def list_active_demand_items, do: Items.list_active_demand_items()

  def get_demand_item!(id), do: Items.get_demand_item!(id)

  def change_demand_item(%DemandItem{} = demand_item, attrs \\ %{}) do
    Items.change_demand_item(demand_item, attrs)
  end

  def create_demand_item(attrs), do: Items.create_demand_item(attrs)

  def update_demand_item(%DemandItem{} = demand_item, attrs),
    do: Items.update_demand_item(demand_item, attrs)

  def transition_demand(%DemandItem{} = demand_item, status, attrs \\ %{}),
    do: Items.transition_demand(demand_item, status, attrs)

  def promote_to_app(%DemandItem{} = demand_item, app_attrs),
    do: Items.promote_to_app(demand_item, app_attrs)

  def list_launch_requests(params \\ %{}) do
    CodexLaunchRequest
    |> apply_filter(:status, filter_value(params, "status"))
    |> apply_filter(:risk_level, filter_value(params, "risk_level"))
    |> order_by([request], desc: request.updated_at)
    |> Repo.all()
    |> Repo.preload([:demand_item, :app, :ticket, :release_target])
  end

  def get_launch_request!(id) do
    CodexLaunchRequest
    |> Repo.get!(id)
    |> Repo.preload([:demand_item, :app, :ticket, :release_target])
  end

  def change_launch_request(%CodexLaunchRequest{} = launch_request, attrs \\ %{}) do
    CodexLaunchRequest.changeset(launch_request, attrs)
  end

  def create_launch_request(attrs), do: LaunchWorkflow.create_launch_request(attrs)

  def create_launch_request_from_demand(%DemandItem{} = demand_item, attrs),
    do: LaunchWorkflow.create_launch_request_from_demand(demand_item, attrs)

  def update_launch_request(%CodexLaunchRequest{} = launch_request, attrs),
    do: LaunchWorkflow.update_launch_request(launch_request, attrs)

  def mark_launch_request_launched(%CodexLaunchRequest{} = launch_request) do
    LaunchWorkflow.mark_launch_request_launched(launch_request)
  end

  def launch_handoff_text(%CodexLaunchRequest{} = launch_request),
    do: LaunchWorkflow.launch_handoff_text(launch_request)

  def launch_research_request_with_codex(%CodexLaunchRequest{} = launch_request, opts \\ []),
    do: CodexLaunch.launch_research_request_with_codex(launch_request, opts)

  def start_research_request_with_codex(%CodexLaunchRequest{} = launch_request, opts \\ []),
    do: CodexLaunch.start_research_request_with_codex(launch_request, opts)

  def complete_codex_launch(launch_request_id, opts \\ []),
    do: CodexLaunch.complete_codex_launch(launch_request_id, opts)

  defp ensure_source_indexable(%SourceRepo{health_state: "healthy"}), do: :ok

  defp ensure_source_indexable(%SourceRepo{} = source_repo),
    do: {:error, {:source_unhealthy, source_repo.health_state}}

  defp scheduled_source_due?(_source_repo, _now, true), do: true

  defp scheduled_source_due?(%SourceRepo{last_run_at: nil}, _now, _force?), do: true

  defp scheduled_source_due?(%SourceRepo{} = source_repo, now, _force?) do
    due_after_seconds = source_repo.schedule_interval_hours * 60 * 60
    DateTime.diff(now, source_repo.last_run_at, :second) >= due_after_seconds
  end

  defp ensure_scheduled_scan_template! do
    case Repo.get_by(MessageTemplate, name: "Scheduled Demand Scan") do
      nil ->
        %MessageTemplate{}
        |> MessageTemplate.changeset(%{
          "name" => "Scheduled Demand Scan",
          "purpose" => "Run scheduled demand discovery and refresh repo artifacts.",
          "default_run_type" => "scheduled_scan",
          "default_lane" => "app",
          "default_target" => "manual_handoff",
          "required_variables" => ["repo_path", "agent_entrypoint", "lane"],
          "body" => scheduled_scan_template_body(),
          "safety_notes" =>
            "Do not create project repositories, promote candidates, or launch implementation without operator approval.",
          "expected_output_paths" => ["runs", "candidates", "evidence", "reports"]
        })
        |> Repo.insert!()

      template ->
        template
    end
  end

  defp scheduled_scan_template_body do
    """
    Follow {{agent_entrypoint}} in {{repo_path}}.

    Run a bounded scheduled_scan for lane {{lane}}.
    Write artifacts only inside the source repo's configured write targets.
    Update repo-local SQLite only through declared operations.
    Summarize durable decisions back to Markdown.
    Do not create app/game project repositories, promote candidates, or start implementation work.
    """
    |> String.trim()
  end

  defp after_source_repo_write({:ok, %SourceRepo{} = source_repo}, event_type) do
    Events.record_event("demand_source_repo", source_repo.id, event_type, %{
      display_name: source_repo.display_name,
      repo_path: source_repo.repo_path,
      health_state: source_repo.health_state
    })

    {:ok, Repo.preload(source_repo, [:candidates, :research_runs])}
  end

  defp after_source_repo_write(result, _event_type), do: result

  defp after_message_template_write({:ok, %MessageTemplate{} = template}, event_type) do
    Events.record_event("demand_message_template", template.id, event_type, %{
      name: template.name,
      default_run_type: template.default_run_type,
      default_lane: template.default_lane
    })

    {:ok, template}
  end

  defp after_message_template_write(result, _event_type), do: result

  defp apply_active_filter(query, value) when value in [nil, ""], do: query

  defp apply_active_filter(query, value) when value in [true, "true"],
    do: where(query, [r], r.active)

  defp apply_active_filter(query, value) when value in [false, "false"],
    do: where(query, [r], r.active == false)

  defp apply_active_filter(query, _value), do: query

  defp display_name_from_repo_path(path) when is_binary(path) do
    path
    |> Path.basename()
    |> Factory.labelize()
  end

  defp display_name_from_repo_path(_path), do: "Demand Source"

  defp normalize_repo_path(path) when is_binary(path), do: Factory.expand_path(path)
  defp normalize_repo_path(_path), do: nil

  defp copy_existing_attr(target, attrs, key) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, key) ->
        Map.put(target, key, Map.fetch!(attrs, key))

      Map.has_key?(attrs, Map.get(@general_attr_atoms, key)) ->
        Map.put(target, key, Map.fetch!(attrs, Map.get(@general_attr_atoms, key)))

      true ->
        target
    end
  end

  defp copy_existing_attr(target, _attrs, _key), do: target

  defp attr_value_or_atom(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, Map.get(@general_attr_atoms, key))
  end

  defp attr_value_or_atom(_attrs, _key), do: nil

  defp apply_filter(query, _field, value) when value in [nil, ""], do: query

  defp apply_filter(query, field, value),
    do: where(query, [record], field(record, ^field) == ^value)

  defp filter_value(params, key) when is_map(params),
    do: Map.get(params, key) || Map.get(params, Map.fetch!(@filter_attr_atoms, key))

  defp filter_value(_params, _key), do: nil
end
