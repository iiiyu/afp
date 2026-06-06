# @input  - Demand source, candidate, run, template, launch, and promotion params
# @output - Demand control-plane queries, source indexing, launch handoffs, and promotion
# @pos    - Context boundary for upstream demand repos and human-confirmed Codex work
defmodule Afp.Factory.Demand do
  import Ecto.Query

  alias Ecto.Changeset

  alias Afp.Factory
  alias Afp.Factory.Demand.Candidate
  alias Afp.Factory.Demand.CodexLaunchRequest
  alias Afp.Factory.Demand.DemandItem
  alias Afp.Factory.Demand.MessageTemplate
  alias Afp.Factory.Demand.ResearchRun
  alias Afp.Factory.Demand.SentMessage
  alias Afp.Factory.Demand.SourceRepo
  alias Afp.Factory.Events
  alias Afp.Factory.Portfolio
  alias Afp.Repo

  @launch_attr_atoms %{
    "source_type" => :source_type,
    "source_id" => :source_id,
    "title" => :title,
    "objective" => :objective,
    "context" => :context,
    "risk_level" => :risk_level,
    "launch_mode" => :launch_mode,
    "status" => :status,
    "confirmation" => :confirmation,
    "handoff_text" => :handoff_text
  }

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
    "demand_status" => :demand_status
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
    manifest_path = attr_value_or_atom(attrs, "manifest_path") || "afp-demand-source.json"
    now = Factory.now()

    base = %{
      "repo_path" => repo_path,
      "display_name" =>
        attr_value_or_atom(attrs, "display_name") || display_name_from_repo_path(repo_path),
      "manifest_path" => manifest_path,
      "latest_scan_at" => now
    }

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
        inspect_existing_source_repo(base, repo_path, manifest_path)
    end
  end

  def source_repo_inspection_attrs(_attrs), do: source_repo_inspection_attrs(%{})

  def list_candidates(params \\ %{}) do
    Candidate
    |> apply_filter(:demand_source_repo_id, filter_value(params, "demand_source_repo_id"))
    |> apply_filter(:lane, filter_value(params, "lane"))
    |> apply_filter(:source_status, filter_value(params, "source_status"))
    |> apply_filter(:afp_status, filter_value(params, "afp_status"))
    |> order_by([candidate],
      desc: candidate.score,
      desc: candidate.observed_at,
      desc: candidate.updated_at
    )
    |> Repo.all()
    |> Repo.preload([:source_repo, :demand_item, :research_runs])
  end

  def list_pickup_candidates do
    list_candidates(%{})
    |> Enum.filter(&(&1.afp_status in ["not_picked_up", "pickup_recommended"]))
  end

  def list_package_candidates do
    list_candidates(%{})
    |> Enum.filter(&(&1.afp_status in ["picked_up", "package_requested", "package_ready"]))
  end

  def list_handoff_candidates do
    list_candidates(%{})
    |> Enum.filter(&(&1.afp_status in ["package_ready", "handoff_ready"]))
  end

  def get_candidate!(id) do
    Candidate
    |> Repo.get!(id)
    |> Repo.preload([:source_repo, :demand_item, :research_runs])
  end

  def change_candidate(%Candidate{} = candidate, attrs \\ %{}) do
    Candidate.changeset(candidate, attrs)
  end

  def index_candidate(%SourceRepo{} = source_repo, attrs) do
    attrs = Map.put(attrs, "demand_source_repo_id", source_repo.id)
    key_changeset = Candidate.changeset(%Candidate{}, attrs)

    if key_changeset.valid? do
      lane = Changeset.get_field(key_changeset, :lane)
      external_id = Changeset.get_field(key_changeset, :external_id)

      existing =
        Repo.get_by(Candidate,
          demand_source_repo_id: source_repo.id,
          lane: lane,
          external_id: external_id
        )

      (existing || %Candidate{})
      |> Candidate.changeset(attrs)
      |> upsert_candidate(existing)
      |> after_candidate_write("demand_candidate_indexed")
    else
      {:error, key_changeset}
    end
  end

  def update_candidate(%Candidate{} = candidate, attrs) do
    candidate
    |> Candidate.changeset(attrs)
    |> Repo.update()
    |> after_candidate_write("demand_candidate_updated")
  end

  def transition_candidate(%Candidate{} = candidate, afp_status, attrs \\ %{}) do
    attrs
    |> Map.put("afp_status", afp_status)
    |> put_candidate_timestamp(afp_status)
    |> then(&update_candidate(candidate, &1))
  end

  def pick_up_candidate(%Candidate{} = candidate, attrs \\ %{}) do
    candidate = Repo.preload(candidate, [:source_repo, :demand_item])

    Repo.transaction(fn ->
      demand_item =
        candidate.demand_item ||
          create_demand_item_from_candidate!(candidate, attrs)

      picked_up_attrs =
        attrs
        |> Map.drop(["demand_status"])
        |> Map.put("demand_item_id", demand_item.id)
        |> Map.put("afp_status", "picked_up")
        |> Map.put("picked_up_at", Factory.now())

      case candidate |> Candidate.changeset(picked_up_attrs) |> Repo.update() do
        {:ok, picked_up_candidate} ->
          Events.record_event("demand_candidate", candidate.id, "demand_candidate_picked_up", %{
            demand_item_id: demand_item.id,
            title: candidate.title
          })

          %{
            candidate: Repo.preload(picked_up_candidate, [:source_repo, :demand_item]),
            demand_item: demand_item
          }

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, %{candidate: picked_up_candidate, demand_item: demand_item}} ->
        {:ok, picked_up_candidate, demand_item}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def approve_candidate_package(%Candidate{} = candidate, attrs \\ %{}) do
    transition_candidate(candidate, "package_requested", attrs)
  end

  def mark_candidate_handoff_ready(%Candidate{} = candidate, attrs \\ %{}) do
    transition_candidate(candidate, "handoff_ready", attrs)
  end

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

  def change_research_run(%ResearchRun{} = research_run, attrs \\ %{}) do
    ResearchRun.changeset(research_run, attrs)
  end

  def create_research_run(attrs) do
    %ResearchRun{}
    |> ResearchRun.changeset(attrs)
    |> Repo.insert()
    |> after_research_run_write("demand_research_run_created")
  end

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

  def render_message_template(%MessageTemplate{} = template, variables) when is_map(variables) do
    variables = normalize_template_variables(variables)

    missing_variables =
      template.required_variables
      |> Enum.map(&to_string/1)
      |> Enum.reject(&Factory.present?(Map.get(variables, &1)))

    if missing_variables == [] do
      rendered =
        Regex.replace(~r/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/, template.body, fn _match, key ->
          Map.get(variables, key, "")
        end)

      {:ok, rendered}
    else
      {:error, {:missing_variables, missing_variables}}
    end
  end

  def create_candidate_launch_request(
        %Candidate{} = candidate,
        %MessageTemplate{} = template,
        attrs
      ) do
    candidate = Repo.preload(candidate, [:source_repo, :demand_item])

    with {:ok, rendered_message} <-
           render_message_template(template, candidate_template_variables(candidate)) do
      edited_body = Factory.trim_nil(attr_value_or_atom(attrs, "edited_body"))
      handoff_text = edited_body || rendered_message
      status = Factory.trim_nil(attr_value_or_atom(attrs, "status")) || "ready"

      title =
        Factory.trim_nil(attr_value_or_atom(attrs, "title")) ||
          "#{template.name}: #{candidate.title}"

      objective =
        Factory.trim_nil(attr_value_or_atom(attrs, "objective")) || template.purpose || title

      Repo.transaction(fn ->
        launch_attrs = %{
          "source_type" => "demand_candidate",
          "source_id" => candidate.id,
          "title" => title,
          "objective" => objective,
          "context" => candidate_launch_context(candidate),
          "risk_level" => Factory.trim_nil(attr_value_or_atom(attrs, "risk_level")) || "normal",
          "launch_mode" =>
            Factory.trim_nil(attr_value_or_atom(attrs, "launch_mode")) || "manual_handoff",
          "status" => status,
          "confirmation" => Factory.trim_nil(attr_value_or_atom(attrs, "confirmation")),
          "handoff_text" => handoff_text
        }

        case create_launch_request(launch_attrs) do
          {:ok, launch_request} ->
            run_attrs = %{
              "demand_source_repo_id" => candidate.demand_source_repo_id,
              "demand_candidate_id" => candidate.id,
              "message_template_id" => template.id,
              "codex_launch_request_id" => launch_request.id,
              "run_type" => template.default_run_type,
              "lane" => candidate.lane,
              "objective" => objective,
              "rendered_message" => rendered_message,
              "output_paths" => template.expected_output_paths,
              "status" => if(status == "ready", do: "ready", else: "draft")
            }

            with {:ok, research_run} <- insert_research_run(run_attrs),
                 {:ok, sent_message} <-
                   insert_sent_message(%{
                     "demand_research_run_id" => research_run.id,
                     "message_template_id" => template.id,
                     "codex_launch_request_id" => launch_request.id,
                     "target" => template.default_target,
                     "status" => if(status == "ready", do: "confirmed", else: "draft"),
                     "rendered_body" => rendered_message,
                     "edited_body" => edited_body,
                     "confirmed_at" => if(status == "ready", do: Factory.now(), else: nil)
                   }) do
              %{
                launch_request: launch_request,
                research_run: research_run,
                sent_message: sent_message
              }
            else
              {:error, changeset} -> Repo.rollback(changeset)
            end

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
      |> case do
        {:ok, records} -> {:ok, records}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def list_demand_items(params \\ %{}) do
    DemandItem
    |> apply_filter(:status, filter_value(params, "status"))
    |> apply_filter(:confidence, filter_value(params, "confidence"))
    |> apply_source_filter(filter_value(params, "source"))
    |> order_by([demand], desc: demand.updated_at)
    |> Repo.all()
    |> Repo.preload([:promoted_app, :launch_requests])
  end

  def list_active_demand_items do
    DemandItem
    |> where([demand], demand.status in ["captured", "researching", "validating", "validated"])
    |> order_by([demand], desc: demand.updated_at)
    |> Repo.all()
    |> Repo.preload([:promoted_app, :launch_requests])
  end

  def get_demand_item!(id) do
    DemandItem
    |> Repo.get!(id)
    |> Repo.preload([:promoted_app, :launch_requests])
  end

  def change_demand_item(%DemandItem{} = demand_item, attrs \\ %{}) do
    DemandItem.changeset(demand_item, attrs)
  end

  def create_demand_item(attrs) do
    %DemandItem{}
    |> DemandItem.changeset(attrs)
    |> Repo.insert()
    |> after_demand_write("demand_created")
  end

  def update_demand_item(%DemandItem{} = demand_item, attrs) do
    demand_item
    |> DemandItem.changeset(attrs)
    |> Repo.update()
    |> after_demand_write("demand_updated")
  end

  def transition_demand(%DemandItem{} = demand_item, status, attrs \\ %{}) do
    attrs
    |> Map.put("status", status)
    |> then(&update_demand_item(demand_item, &1))
  end

  def promote_to_app(%DemandItem{status: status}, _app_attrs) when status != "validated" do
    {:error, :demand_not_validated}
  end

  def promote_to_app(%DemandItem{} = demand_item, app_attrs) do
    app_attrs =
      app_attrs
      |> Map.put_new("next_action", demand_item.validation_action)
      |> Map.put_new("product_thesis", product_thesis_from_demand(demand_item))

    Repo.transaction(fn ->
      case Portfolio.create_app(app_attrs) do
        {:ok, app} ->
          promote_attrs = %{
            "status" => "promoted",
            "promoted_app_id" => app.id,
            "promoted_at" => Factory.now()
          }

          case demand_item |> DemandItem.changeset(promote_attrs) |> Repo.update() do
            {:ok, promoted_demand_item} ->
              Events.record_event("demand_item", demand_item.id, "demand_promoted", %{
                app_id: app.id,
                app_name: app.name
              })

              %{demand_item: Repo.preload(promoted_demand_item, :promoted_app), app: app}

            {:error, changeset} ->
              Repo.rollback(changeset)
          end

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, %{demand_item: promoted_demand_item, app: app}} -> {:ok, promoted_demand_item, app}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_launch_requests(params \\ %{}) do
    CodexLaunchRequest
    |> apply_filter(:status, filter_value(params, "status"))
    |> apply_filter(:risk_level, filter_value(params, "risk_level"))
    |> order_by([request], desc: request.updated_at)
    |> Repo.all()
    |> Repo.preload([:demand_item, :app, :ticket, :release_target])
  end

  def change_launch_request(%CodexLaunchRequest{} = launch_request, attrs \\ %{}) do
    CodexLaunchRequest.changeset(launch_request, attrs)
  end

  def create_launch_request(attrs) do
    attrs = maybe_put_handoff_text(attrs)

    %CodexLaunchRequest{}
    |> CodexLaunchRequest.changeset(attrs)
    |> Repo.insert()
    |> after_launch_write("launch_request_created")
  end

  def create_launch_request_from_demand(%DemandItem{} = demand_item, attrs) do
    attrs =
      attrs
      |> Map.put("demand_item_id", demand_item.id)
      |> Map.put("source_type", "demand_item")
      |> Map.put("source_id", demand_item.id)
      |> put_if_blank("title", "Validate #{demand_item.title}")
      |> put_if_blank("objective", demand_item.validation_action)
      |> put_if_blank("context", launch_context_from_demand(demand_item))

    create_launch_request(attrs)
  end

  def update_launch_request(%CodexLaunchRequest{} = launch_request, attrs) do
    attrs = maybe_put_handoff_text(attrs)

    launch_request
    |> CodexLaunchRequest.changeset(attrs)
    |> Repo.update()
    |> after_launch_write("launch_request_updated")
  end

  def mark_launch_request_launched(%CodexLaunchRequest{} = launch_request) do
    update_launch_request(launch_request, %{
      "status" => "launched",
      "launched_at" => Factory.now()
    })
  end

  def launch_handoff_text(%CodexLaunchRequest{} = launch_request) do
    """
    Codex Launch Request: #{launch_request.title}

    Objective:
    #{launch_request.objective}

    Source:
    #{launch_request.source_type} #{launch_request.source_id || ""}

    Risk:
    #{launch_request.risk_level}

    Context:
    #{launch_request.context || "No additional context."}

    Approval:
    Human confirmation is required before applying risky changes or promoting state.
    """
    |> String.trim()
  end

  defp inspect_existing_source_repo(base, repo_path, manifest_path) do
    git_repo? = File.dir?(Path.join(repo_path, ".git"))

    case read_source_manifest(repo_path, manifest_path) do
      {:missing, manifest_full_path} ->
        health_state = if(git_repo?, do: "manifest_missing", else: "not_git")

        Map.merge(base, %{
          "health_state" => health_state,
          "health_summary" => source_health_summary(health_state),
          "missing_paths" => [manifest_full_path],
          "parse_errors" => []
        })

      {:error, reason} ->
        Map.merge(base, %{
          "health_state" => "invalid_manifest",
          "health_summary" => "Manifest could not be parsed.",
          "parse_errors" => [reason],
          "missing_paths" => []
        })

      {:ok, manifest} ->
        manifest_attrs = source_manifest_attrs(manifest)
        health_attrs = source_health_attrs(repo_path, git_repo?, manifest_attrs)

        base
        |> Map.merge(manifest_attrs)
        |> Map.merge(health_attrs)
    end
  end

  defp read_source_manifest(repo_path, manifest_path) do
    manifest_full_path = Path.join(repo_path, manifest_path)

    if File.regular?(manifest_full_path) do
      manifest_full_path
      |> File.read()
      |> case do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, manifest} when is_map(manifest) -> {:ok, manifest}
            {:ok, _value} -> {:error, "Manifest root must be a JSON object."}
            {:error, error} -> {:error, Exception.message(error)}
          end

        {:error, reason} ->
          {:error, "Could not read manifest: #{reason}"}
      end
    else
      {:missing, manifest_full_path}
    end
  end

  defp source_manifest_attrs(manifest) do
    agent_contract = map_value(manifest, "agent_contract")
    sqlite = map_value(manifest, "sqlite")

    %{
      "kind" => string_value(manifest, "kind") || "product_demand_repo",
      "display_name" => string_value(manifest, "display_name"),
      "description" => string_value(manifest, "description"),
      "manifest_schema_version" => integer_value(manifest, "schema_version"),
      "lanes" => list_value(manifest, "lanes"),
      "agent_entrypoint" => string_value(agent_contract, "entrypoint") || "AGENTS.md",
      "agent_required" => boolean_value(agent_contract, "required", true),
      "skill_policy" => string_value(agent_contract, "skill_policy"),
      "required_skills" => list_value(agent_contract, "required_skills"),
      "optional_skills" => list_value(agent_contract, "optional_skills"),
      "read_order" => list_value(manifest, "read_order"),
      "write_targets" => map_value(manifest, "write_targets"),
      "sqlite_path" => string_value(sqlite, "path"),
      "sqlite_mode" => string_value(sqlite, "mode"),
      "sqlite_owner" => string_value(sqlite, "owner"),
      "sqlite_schema_path" => string_value(sqlite, "schema_path"),
      "sqlite_migrations_path" => string_value(sqlite, "migrations_path"),
      "sqlite_allowed_operations" => list_value(sqlite, "allowed_operations"),
      "payload" => %{"manifest" => manifest}
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, []] end)
    |> Map.new()
  end

  defp source_health_attrs(repo_path, git_repo?, manifest_attrs) do
    agent_entrypoint = Map.get(manifest_attrs, "agent_entrypoint") || "AGENTS.md"
    agent_required = Map.get(manifest_attrs, "agent_required", true)
    sqlite_mode = Map.get(manifest_attrs, "sqlite_mode")
    sqlite_path = Map.get(manifest_attrs, "sqlite_path")
    write_targets = Map.get(manifest_attrs, "write_targets", %{})

    missing_agent_paths =
      if agent_required and not File.regular?(Path.join(repo_path, agent_entrypoint)) do
        [Path.join(repo_path, agent_entrypoint)]
      else
        []
      end

    missing_sqlite_paths = missing_sqlite_paths(repo_path, sqlite_mode, sqlite_path)
    invalid_sqlite_paths = invalid_sqlite_paths(repo_path, sqlite_mode, sqlite_path)
    missing_write_target_paths = missing_write_target_paths(repo_path, write_targets)

    health_state =
      cond do
        not git_repo? -> "not_git"
        missing_agent_paths != [] -> "agents_missing"
        missing_sqlite_paths != [] -> "sqlite_missing"
        invalid_sqlite_paths != [] -> "sqlite_invalid"
        missing_write_target_paths != [] -> "invalid_structure"
        true -> "healthy"
      end

    %{
      "health_state" => health_state,
      "health_summary" => source_health_summary(health_state),
      "missing_paths" =>
        missing_agent_paths ++ missing_sqlite_paths ++ missing_write_target_paths,
      "parse_errors" => []
    }
  end

  defp missing_sqlite_paths(repo_path, "required", nil),
    do: [Path.join(repo_path, "demand.sqlite3")]

  defp missing_sqlite_paths(repo_path, "required", sqlite_path) do
    full_path = Path.join(repo_path, sqlite_path)
    if File.exists?(full_path), do: [], else: [full_path]
  end

  defp missing_sqlite_paths(_repo_path, _mode, _sqlite_path), do: []

  defp invalid_sqlite_paths(repo_path, "required", sqlite_path) when is_binary(sqlite_path) do
    full_path = Path.join(repo_path, sqlite_path)

    if File.exists?(full_path) and not File.regular?(full_path) do
      [full_path]
    else
      []
    end
  end

  defp invalid_sqlite_paths(_repo_path, _mode, _sqlite_path), do: []

  defp missing_write_target_paths(repo_path, write_targets) when is_map(write_targets) do
    write_targets
    |> Map.values()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.join(repo_path, &1))
    |> Enum.reject(&File.dir?/1)
  end

  defp missing_write_target_paths(_repo_path, _write_targets), do: []

  defp source_health_summary("healthy"), do: "Source repo contract is readable."
  defp source_health_summary("missing"), do: "Source path is missing."
  defp source_health_summary("not_git"), do: "Path exists but is not a git repository."
  defp source_health_summary("manifest_missing"), do: "Manifest is missing."
  defp source_health_summary("invalid_manifest"), do: "Manifest is invalid."
  defp source_health_summary("invalid_structure"), do: "Configured source paths are missing."
  defp source_health_summary("agents_missing"), do: "Required AGENTS.md entrypoint is missing."

  defp source_health_summary("sqlite_missing"),
    do: "Required repo-local SQLite database is missing."

  defp source_health_summary("sqlite_invalid"),
    do: "Configured SQLite path is not a database file."

  defp source_health_summary("skills_unavailable"), do: "Required skills are unavailable."
  defp source_health_summary(_health_state), do: "Source health is unknown."

  defp map_value(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_map(value) -> value
      _value -> %{}
    end
  end

  defp map_value(_map, _key), do: %{}

  defp string_value(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) -> Factory.trim_nil(value)
      _value -> nil
    end
  end

  defp string_value(_map, _key), do: nil

  defp integer_value(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _value -> nil
    end
  end

  defp integer_value(_map, _key), do: nil

  defp boolean_value(map, key, default) when is_map(map) do
    case Map.get(map, key) do
      value when is_boolean(value) -> value
      _value -> default
    end
  end

  defp boolean_value(_map, _key, default), do: default

  defp list_value(map, key) when is_map(map) do
    case Map.get(map, key) do
      values when is_list(values) ->
        values
        |> Enum.map(&to_string/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&Factory.blank?/1)

      value when is_binary(value) ->
        Factory.lines_to_list(value)

      _value ->
        []
    end
  end

  defp list_value(_map, _key), do: []

  defp upsert_candidate(changeset, nil), do: Repo.insert(changeset)
  defp upsert_candidate(changeset, _existing), do: Repo.update(changeset)

  defp create_demand_item_from_candidate!(%Candidate{} = candidate, attrs) do
    source_repo = candidate.source_repo

    demand_attrs = %{
      "title" => candidate.title,
      "status" => attr_value_or_atom(attrs, "demand_status") || "validating",
      "source" => candidate_source_label(candidate),
      "source_url" => source_artifact_path(source_repo, candidate.primary_path),
      "target_user" => candidate.target_user,
      "demand_signal" => candidate.demand_signal,
      "incumbent_weakness" => candidate.incumbent_weakness,
      "wedge_hypothesis" => candidate.wedge_hypothesis,
      "validation_action" =>
        candidate.validation_action ||
          "Review indexed candidate and choose the next validation action.",
      "evidence_summary" => evidence_summary_from_candidate(candidate),
      "confidence" => candidate.confidence
    }

    case create_demand_item(demand_attrs) do
      {:ok, demand_item} -> demand_item
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp candidate_source_label(%Candidate{source_repo: %SourceRepo{} = source_repo, lane: lane}) do
    "#{source_repo.display_name} / #{lane}"
  end

  defp candidate_source_label(%Candidate{lane: lane}), do: "Demand source / #{lane}"

  defp source_artifact_path(nil, path), do: path
  defp source_artifact_path(_source_repo, nil), do: nil

  defp source_artifact_path(%SourceRepo{} = source_repo, path) do
    Path.join(source_repo.repo_path, path)
  end

  defp evidence_summary_from_candidate(%Candidate{} = candidate) do
    [
      candidate.demand_signal,
      candidate.limitations,
      Enum.join(candidate.evidence_paths || [], "\n")
    ]
    |> Enum.reject(&Factory.blank?/1)
    |> Enum.join("\n")
  end

  defp put_candidate_timestamp(attrs, "picked_up"),
    do: Map.put_new(attrs, "picked_up_at", Factory.now())

  defp put_candidate_timestamp(attrs, status)
       when status in ["package_requested", "package_ready"],
       do: Map.put_new(attrs, "approved_for_package_at", Factory.now())

  defp put_candidate_timestamp(attrs, "handoff_ready"),
    do: Map.put_new(attrs, "handed_off_at", Factory.now())

  defp put_candidate_timestamp(attrs, "rejected"),
    do: Map.put_new(attrs, "rejected_at", Factory.now())

  defp put_candidate_timestamp(attrs, "parked"),
    do: Map.put_new(attrs, "parked_at", Factory.now())

  defp put_candidate_timestamp(attrs, _status), do: attrs

  defp insert_research_run(attrs) do
    %ResearchRun{}
    |> ResearchRun.changeset(attrs)
    |> Repo.insert()
    |> after_research_run_write("demand_research_run_created")
  end

  defp insert_sent_message(attrs) do
    %SentMessage{}
    |> SentMessage.changeset(attrs)
    |> Repo.insert()
    |> after_sent_message_write("demand_sent_message_created")
  end

  defp candidate_template_variables(%Candidate{} = candidate) do
    source_repo = candidate.source_repo

    %{
      "repo_path" => source_repo && source_repo.repo_path,
      "source_repo_path" => source_repo && source_repo.repo_path,
      "source_display_name" => source_repo && source_repo.display_name,
      "agent_entrypoint" => (source_repo && source_repo.agent_entrypoint) || "AGENTS.md",
      "lane" => candidate.lane,
      "candidate_id" => candidate.external_id,
      "candidate_title" => candidate.title,
      "title" => candidate.title,
      "source_status" => candidate.source_status,
      "afp_status" => candidate.afp_status,
      "score" => candidate.score,
      "confidence" => candidate.confidence,
      "target_user" => candidate.target_user,
      "demand_signal" => candidate.demand_signal,
      "incumbent_weakness" => candidate.incumbent_weakness,
      "wedge_hypothesis" => candidate.wedge_hypothesis,
      "validation_action" => candidate.validation_action,
      "primary_path" => candidate.primary_path,
      "report_path" => candidate.report_path,
      "package_path" => candidate.package_path,
      "evidence_paths" => Enum.join(candidate.evidence_paths || [], "\n"),
      "limitations" => candidate.limitations
    }
  end

  defp normalize_template_variables(variables) do
    variables
    |> Enum.map(fn {key, value} -> {to_string(key), template_value(value)} end)
    |> Map.new()
  end

  defp template_value(nil), do: ""
  defp template_value(%Date{} = date), do: Date.to_iso8601(date)
  defp template_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp template_value(value) when is_binary(value), do: value
  defp template_value(value), do: to_string(value)

  defp candidate_launch_context(%Candidate{} = candidate) do
    source_repo = candidate.source_repo

    [
      "Demand candidate: #{candidate.title}",
      "Source repo: #{source_repo && source_repo.repo_path}",
      "Repo instructions: #{(source_repo && source_repo.agent_entrypoint) || "AGENTS.md"}",
      "Lane: #{candidate.lane}",
      "Candidate id: #{candidate.external_id}",
      "Source status: #{candidate.source_status}",
      "AFP status: #{candidate.afp_status}",
      "Primary path: #{candidate.primary_path || "not indexed"}",
      "Report path: #{candidate.report_path || "not indexed"}",
      "Package path: #{candidate.package_path || "not indexed"}",
      "Human confirmation is required before promotion, package overwrite, repo creation, or implementation launch."
    ]
    |> Enum.join("\n")
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

  defp after_candidate_write({:ok, %Candidate{} = candidate}, event_type) do
    Events.record_event("demand_candidate", candidate.id, event_type, %{
      title: candidate.title,
      lane: candidate.lane,
      source_status: candidate.source_status,
      afp_status: candidate.afp_status
    })

    {:ok, Repo.preload(candidate, [:source_repo, :demand_item, :research_runs])}
  end

  defp after_candidate_write(result, _event_type), do: result

  defp after_research_run_write({:ok, %ResearchRun{} = research_run}, event_type) do
    Events.record_event("demand_research_run", research_run.id, event_type, %{
      run_type: research_run.run_type,
      status: research_run.status,
      candidate_id: research_run.demand_candidate_id
    })

    {:ok,
     Repo.preload(research_run, [
       :source_repo,
       :candidate,
       :message_template,
       :launch_request,
       :codex_session
     ])}
  end

  defp after_research_run_write(result, _event_type), do: result

  defp after_message_template_write({:ok, %MessageTemplate{} = template}, event_type) do
    Events.record_event("demand_message_template", template.id, event_type, %{
      name: template.name,
      default_run_type: template.default_run_type,
      default_lane: template.default_lane
    })

    {:ok, template}
  end

  defp after_message_template_write(result, _event_type), do: result

  defp after_sent_message_write({:ok, %SentMessage{} = sent_message}, event_type) do
    Events.record_event("demand_sent_message", sent_message.id, event_type, %{
      research_run_id: sent_message.demand_research_run_id,
      launch_request_id: sent_message.codex_launch_request_id,
      status: sent_message.status
    })

    {:ok, Repo.preload(sent_message, [:research_run, :message_template, :launch_request])}
  end

  defp after_sent_message_write(result, _event_type), do: result

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

  defp attr_value_or_atom(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, Map.get(@general_attr_atoms, key))
  end

  defp attr_value_or_atom(_attrs, _key), do: nil

  defp after_demand_write({:ok, %DemandItem{} = demand_item}, event_type) do
    Events.record_event("demand_item", demand_item.id, event_type, %{
      title: demand_item.title,
      status: demand_item.status,
      confidence: demand_item.confidence
    })

    {:ok, Repo.preload(demand_item, [:promoted_app, :launch_requests])}
  end

  defp after_demand_write(result, _event_type), do: result

  defp after_launch_write({:ok, %CodexLaunchRequest{} = launch_request}, event_type) do
    Events.record_event("codex_launch_request", launch_request.id, event_type, %{
      title: launch_request.title,
      status: launch_request.status,
      risk_level: launch_request.risk_level,
      source_type: launch_request.source_type,
      source_id: launch_request.source_id
    })

    {:ok, Repo.preload(launch_request, [:demand_item, :app, :ticket, :release_target])}
  end

  defp after_launch_write(result, _event_type), do: result

  defp maybe_put_handoff_text(attrs) do
    if Factory.blank?(Map.get(attrs, "handoff_text") || Map.get(attrs, :handoff_text)) do
      draft = struct(CodexLaunchRequest, atomize_launch_attrs(attrs))
      Map.put(attrs, "handoff_text", launch_handoff_text(draft))
    else
      attrs
    end
  end

  defp atomize_launch_attrs(attrs) do
    %{
      source_type: attr_value(attrs, "source_type"),
      source_id: attr_value(attrs, "source_id"),
      title: attr_value(attrs, "title"),
      objective: attr_value(attrs, "objective"),
      context: attr_value(attrs, "context"),
      risk_level: attr_value(attrs, "risk_level"),
      launch_mode: attr_value(attrs, "launch_mode"),
      status: attr_value(attrs, "status"),
      confirmation: attr_value(attrs, "confirmation"),
      handoff_text: attr_value(attrs, "handoff_text")
    }
  end

  defp attr_value(attrs, key),
    do: Map.get(attrs, key) || Map.get(attrs, Map.fetch!(@launch_attr_atoms, key))

  defp product_thesis_from_demand(%DemandItem{} = demand_item) do
    %{
      "source_demand_item_id" => demand_item.id,
      "target_user" => demand_item.target_user,
      "job_to_be_done" => demand_item.job_to_be_done,
      "demand_signal" => demand_item.demand_signal,
      "incumbent_weakness" => demand_item.incumbent_weakness,
      "wedge_hypothesis" => demand_item.wedge_hypothesis
    }
  end

  defp launch_context_from_demand(%DemandItem{} = demand_item) do
    [
      "Demand item: #{demand_item.title}",
      "Source: #{demand_item.source || "unknown"}",
      "Target user/job: #{demand_item.target_user || demand_item.job_to_be_done || "unknown"}",
      "Demand signal: #{demand_item.demand_signal || "unknown"}",
      "Incumbent weakness: #{demand_item.incumbent_weakness || "unknown"}",
      "Wedge hypothesis: #{demand_item.wedge_hypothesis || "unknown"}",
      "Evidence: #{demand_item.evidence_summary || "none yet"}"
    ]
    |> Enum.join("\n")
  end

  defp apply_filter(query, _field, value) when value in [nil, ""], do: query

  defp apply_filter(query, field, value),
    do: where(query, [record], field(record, ^field) == ^value)

  defp apply_source_filter(query, value) when value in [nil, ""], do: query

  defp apply_source_filter(query, value) do
    where(query, [demand], ilike(demand.source, ^"%#{value}%"))
  end

  defp put_if_blank(attrs, key, value) do
    if Factory.blank?(Map.get(attrs, key) || Map.get(attrs, Map.get(@launch_attr_atoms, key))) do
      Map.put(attrs, key, value)
    else
      attrs
    end
  end

  defp filter_value(params, key) when is_map(params),
    do: Map.get(params, key) || Map.get(params, Map.fetch!(@filter_attr_atoms, key))

  defp filter_value(_params, _key), do: nil
end
