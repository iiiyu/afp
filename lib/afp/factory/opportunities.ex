# @input  - Operator opportunity prompts, configured repo paths, repo-local SQLite, and agent launch progress
# @output - Opportunity repo scaffolding, health inspection, opportunity records, file previews, and Codex/Claude Code launch state
# @pos    - Context boundary for the portable opportunities repository workflow
defmodule Afp.Factory.Opportunities do
  alias Afp.Factory
  alias Afp.Factory.Events
  alias Afp.Factory.Opportunities.AgentRun
  alias Afp.Factory.Opportunities.Files
  alias Afp.Factory.Opportunities.RepoContract
  alias Afp.Factory.Opportunities.Storage
  alias Afp.Factory.Settings

  @setting_key "opportunity_repo"
  @base_sqlite_path "base.sqlite"
  @skills_path ".skills"
  @opportunities_path "opportunities"
  @steps_path "steps"
  @agents ~w(claude_code codex)
  @default_agent "claude_code"

  # Curated per-agent model pickers for the launch form (verified 2026-06);
  # free-text custom values and the CLI-default empty value stay supported.
  @codex_models ~w(gpt-5.5 gpt-5.4 gpt-5.4-mini gpt-5.3-codex gpt-5.2-codex)
  @claude_code_models ~w(claude-fable-5 claude-opus-4-8 claude-sonnet-4-6 claude-haiku-4-5)

  @research_steps [
    %{
      key: "competitor_discovery",
      index: 0,
      title: "Competitor Discovery",
      artifact: "steps/00-competitor-discovery.md",
      max_score: nil
    },
    %{
      key: "demand_proof",
      index: 1,
      title: "Demand Proof",
      artifact: "steps/01-demand-proof.md",
      max_score: 20
    },
    %{
      key: "pain_strength",
      index: 2,
      title: "Pain Strength",
      artifact: "steps/02-pain-strength.md",
      max_score: 20
    },
    %{
      key: "incumbent_weakness",
      index: 3,
      title: "Incumbent Weakness",
      artifact: "steps/03-incumbent-weakness.md",
      max_score: 20
    },
    %{
      key: "wedge_clarity",
      index: 4,
      title: "Wedge Clarity",
      artifact: "steps/04-wedge-clarity.md",
      max_score: 20
    },
    %{
      key: "build_distribution_feasibility",
      index: 5,
      title: "Build & Distribution Feasibility",
      artifact: "steps/05-build-distribution-feasibility.md",
      max_score: 20
    },
    %{
      key: "score_aggregator",
      index: 6,
      title: "Score Aggregator",
      artifact: "steps/06-score-aggregator.md",
      max_score: 100
    }
  ]

  def configured_repo do
    @setting_key
    |> Settings.get_setting(%{})
    |> configured_repo_from_setting()
  end

  def configure_repo(attrs) when is_map(attrs) do
    repo_path = attrs |> attr_value("repo_path") |> RepoContract.normalize_repo_path()

    display_name =
      Factory.trim_nil(attr_value(attrs, "display_name")) || RepoContract.display_name(repo_path)

    config =
      %{
        "repo_path" => repo_path,
        "display_name" => display_name
      }
      |> Map.merge(RepoContract.health(repo_path))

    with {:ok, _setting} <- Settings.put_setting(@setting_key, config) do
      Events.record_event("opportunity_repo", nil, "opportunity_repo_configured", %{
        repo_path: repo_path,
        health_state: config["health_state"]
      })

      {:ok, config}
    end
  end

  def configure_repo(_attrs), do: {:error, :repo_path_required}

  def create_repo_from_template(attrs) when is_map(attrs) do
    with {:ok, repo} <- RepoContract.create_from_template(attrs) do
      configure_repo(repo)
    end
  end

  def create_repo_from_template(_attrs), do: {:error, :repo_path_required}

  def refresh_configured_repo do
    case configured_repo() do
      nil -> {:error, :repo_path_required}
      repo -> configure_repo(repo)
    end
  end

  def healthy_repo? do
    case configured_repo() do
      %{"health_state" => "healthy"} -> true
      _repo -> false
    end
  end

  def list_opportunities do
    with {:ok, repo} <- healthy_repo(),
         {:ok, rows} <- Storage.list_opportunities(repo) do
      rows
    end
  end

  def get_opportunity(id) do
    with {:ok, repo} <- healthy_repo(),
         {:ok, opportunity} <- Storage.get_opportunity(repo, id) do
      {:ok, opportunity}
    end
  end

  def list_runs(opportunity_id) do
    with {:ok, repo} <- healthy_repo(),
         {:ok, runs} <- Storage.list_runs(repo, opportunity_id) do
      runs
    end
  end

  def create_opportunity_with_codex(attrs, opts \\ [])

  def create_opportunity_with_codex(attrs, opts) when is_map(attrs),
    do: create_opportunity(Map.put(attrs, "agent", "codex"), opts)

  def create_opportunity_with_codex(_attrs, _opts), do: {:error, :raw_input_required}

  def create_opportunity(attrs, opts \\ [])

  def create_opportunity(attrs, opts) when is_map(attrs) do
    with {:ok, repo} <- healthy_repo(),
         {:ok, raw_input} <- raw_input(attrs),
         {:ok, agent} <- launch_agent(attrs),
         model <- launch_model(attrs),
         {:ok, opportunity} <- create_opportunity_record(repo, raw_input, agent),
         {:ok, run} <- create_opportunity_run(repo, opportunity, raw_input, agent, model) do
      case AgentRun.start_agent_run(repo, opportunity, run, opts) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def create_opportunity(_attrs, _opts), do: {:error, :raw_input_required}

  @doc """
  Re-run an existing opportunity's research after a failed (or completed) run.

  Reuses the stored `raw_input` and `agent`, carrying forward the most recent
  run's model override. Creates a fresh run rather than mutating the old one,
  so prior attempts stay in the run history.
  """
  def relaunch_opportunity(opportunity_id, opts \\ []) do
    with {:ok, repo} <- healthy_repo(),
         {:ok, opportunity} <- get_opportunity(opportunity_id),
         {:ok, raw_input} <- raw_input(opportunity) do
      agent = opportunity["agent"] || @default_agent
      model = latest_run_model(opportunity_id)

      with {:ok, run} <- create_opportunity_run(repo, opportunity, raw_input, agent, model) do
        case AgentRun.start_agent_run(repo, opportunity, run, opts) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  # Most recent run's model override, so a re-run keeps the operator's choice.
  defp latest_run_model(opportunity_id) do
    opportunity_id
    |> list_runs()
    |> case do
      [latest | _] -> run_model(latest)
      _ -> nil
    end
  end

  defp run_model(%{"payload_json" => json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"model" => model}} when is_binary(model) and model != "" -> model
      _ -> nil
    end
  end

  defp run_model(_run), do: nil

  def supported_agents, do: @agents

  def agent_label("claude_code"), do: "Claude Code"
  def agent_label(_agent), do: "Codex"

  def known_models("claude_code"), do: @claude_code_models
  def known_models(_agent), do: @codex_models

  def research_steps, do: @research_steps

  def step_title(step_key) do
    case Enum.find(@research_steps, &(&1.key == step_key)) do
      %{title: title} -> title
      nil -> Factory.labelize(step_key)
    end
  end

  def list_step_results(opportunity_id) do
    with {:ok, repo} <- healthy_repo(),
         {:ok, rows} <- Storage.list_step_results(repo, opportunity_id) do
      rows
    end
  end

  def list_step_evidence(opportunity_id) do
    with {:ok, repo} <- healthy_repo(),
         {:ok, rows} <- Storage.list_step_evidence(repo, opportunity_id) do
      rows
    end
  end

  def list_opportunity_files(opportunity_id) do
    with {:ok, repo} <- healthy_repo() do
      Files.list(repo, opportunity_id)
    end
  end

  def read_opportunity_file(opportunity_id, relative_path) do
    with {:ok, repo} <- healthy_repo() do
      Files.read(repo, opportunity_id, relative_path)
    end
  end

  def repo_root(%{"repo_path" => repo_path}), do: repo_path
  def repo_root(_repo), do: nil

  def opportunity_relative_root(opportunity_id) do
    Path.join([@opportunities_path, opportunity_id])
  end

  def steps_path, do: @steps_path
  def base_sqlite_path, do: @base_sqlite_path

  defp configured_repo_from_setting(%{"repo_path" => repo_path} = setting)
       when is_binary(repo_path) and repo_path != "" do
    setting
    |> Map.merge(RepoContract.health(repo_path))
    |> Map.put_new("display_name", RepoContract.display_name(repo_path))
  end

  defp configured_repo_from_setting(_setting), do: nil

  defp healthy_repo do
    case configured_repo() do
      %{"health_state" => "healthy"} = repo -> {:ok, repo}
      nil -> {:error, :repo_path_required}
      repo -> {:error, {:repo_unhealthy, repo["health_state"]}}
    end
  end

  defp mkdir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, path, reason}}
    end
  end

  defp create_opportunity_record(repo, raw_input, agent) do
    opportunity_id = Ecto.UUID.generate()
    title = title_from_input(raw_input)
    source_url = first_url(raw_input)
    now = now_iso()

    with :ok <- write_opportunity_files(repo, opportunity_id, title, raw_input),
         {:ok, opportunity} <-
           Storage.insert_opportunity(repo, %{
             id: opportunity_id,
             title: title,
             raw_input: raw_input,
             source_url: source_url,
             agent: agent,
             now: now
           }),
         :ok <- Files.refresh_index(repo, opportunity_id) do
      Events.record_event("opportunity", opportunity_id, "opportunity_created", %{
        title: title,
        agent: agent,
        repo_path: repo["repo_path"]
      })

      {:ok, opportunity}
    end
  end

  defp write_opportunity_files(repo, opportunity_id, title, raw_input) do
    root = Path.join([repo["repo_path"], @opportunities_path, opportunity_id])

    with :ok <- mkdir(root),
         :ok <- mkdir(Path.join(root, @steps_path)),
         :ok <- File.write(Path.join(root, "README.md"), opportunity_readme(title, raw_input)) do
      :ok
    else
      {:error, reason} ->
        {:error, {:write_failed, opportunity_relative_root(opportunity_id), reason}}
    end
  end

  defp create_opportunity_run(repo, opportunity, raw_input, agent, model) do
    run_id = Ecto.UUID.generate()
    prompt = agent_prompt(repo, opportunity, run_id, raw_input)

    with {:ok, run} <-
           Storage.insert_initial_run(repo, %{
             id: run_id,
             opportunity_id: opportunity["id"],
             agent: agent,
             model: model,
             prompt: prompt,
             stage: "#{agent_label(agent)} launch queued",
             steps: @research_steps
           }) do
      run = %{
        run
        | "id" => run_id,
          "prompt" => prompt
      }

      Events.record_event("opportunity_run", run_id, "opportunity_run_queued", %{
        opportunity_id: opportunity["id"],
        agent: agent,
        model: model
      })

      {:ok, run}
    end
  end

  defp raw_input(attrs) do
    case attrs |> attr_value("raw_input") |> Factory.trim_nil() do
      nil -> {:error, :raw_input_required}
      raw_input -> {:ok, raw_input}
    end
  end

  defp launch_agent(attrs) do
    case attrs |> attr_value("agent") |> Factory.trim_nil() do
      nil -> {:ok, @default_agent}
      agent when agent in @agents -> {:ok, agent}
      agent -> {:error, {:unsupported_agent, agent}}
    end
  end

  # Optional model override; nil means the agent CLI's configured default.
  defp launch_model(attrs) do
    attrs |> attr_value("model") |> Factory.trim_nil()
  end

  defp title_from_input(raw_input) do
    raw_input
    |> String.split("\n", trim: true)
    |> List.first()
    |> Kernel.||("Untitled opportunity")
    |> String.replace(~r/https?:\/\/\S+/, "")
    |> String.trim()
    |> case do
      "" -> first_url(raw_input) || "Untitled opportunity"
      title -> title
    end
    |> String.slice(0, 96)
  end

  defp first_url(raw_input) do
    Regex.run(~r/https?:\/\/[^\s]+/, raw_input)
    |> case do
      [url | _rest] -> String.trim_trailing(url, ".,)")
      _match -> nil
    end
  end

  defp attr_value(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, attr_atom(key))
  end

  defp attr_value(_attrs, _key), do: nil

  defp attr_atom("repo_path"), do: :repo_path
  defp attr_atom("display_name"), do: :display_name
  defp attr_atom("raw_input"), do: :raw_input
  defp attr_atom("agent"), do: :agent
  defp attr_atom("model"), do: :model
  defp attr_atom(_key), do: nil

  defp now_iso, do: Factory.now() |> DateTime.to_iso8601()

  defp opportunity_readme(title, raw_input) do
    step_lines =
      Enum.map_join(@research_steps, "\n", fn step ->
        "- `#{step.artifact}` - #{step.title}"
      end)

    """
    # #{title}

    ## Raw Input

    #{raw_input}

    ## Current Stage

    Captured by AFP. The research agent executes the seven-step pipeline from
    `AGENTS.md` and rewrites this file as the final summary in the last step.

    ## Expected Step Artifacts

    #{step_lines}
    """
  end

  defp agent_prompt(repo, opportunity, run_id, raw_input) do
    relative_root = opportunity_relative_root(opportunity["id"])

    """
    You are working inside an AFP opportunity repo.

    Read `AGENTS.md` first, then execute the seven-step research pipeline it declares for this opportunity, in order, using the step skills under `#{@skills_path}/`.

    OPPORTUNITY_ID: #{opportunity["id"]}
    OPPORTUNITY_RUN_ID: #{run_id}
    OPPORTUNITY_DIR: #{relative_root}
    BASE_SQLITE: #{@base_sqlite_path}

    RAW_DEMAND_INPUT:
    #{raw_input}

    Required work:
    1. Execute all seven pipeline steps in order. Never skip, merge, or reorder steps.
    2. Write each step's artifact to its fixed path under `#{relative_root}/#{@steps_path}/`.
    3. After each step, upsert its row in `opportunity_step_results` (see AGENTS.md -> Step Recording) using OPPORTUNITY_ID and OPPORTUNITY_RUN_ID. The rows are pre-seeded as 'pending'.
    4. Keep only the most decision-relevant supporting materials (the 20-80 rule: max 3 files per step) under each step's own directory and register every kept file in `opportunity_step_evidence` (see AGENTS.md -> Evidence Materials).
    5. Finish with the score aggregator: rewrite `#{relative_root}/README.md` as the final summary and update the opportunities row with total_score, route, and latest_summary.
    6. Keep all files for this opportunity under `#{relative_root}/`.
    7. Do not invent evidence. Follow the evidence caps from the skills.

    Repo root: #{repo["repo_path"]}
    """
    |> String.trim()
  end
end
