# @input  - Operator-selected local paths and source repo display names
# @output - Standard demand source repo files, git metadata, and SQLite schema
# @pos    - Filesystem scaffold for creating a healthy demand source repo contract
defmodule Afp.Factory.Demand.SourceRepoScaffold do
  alias Afp.Factory

  @manifest_path "afp-demand-source.json"

  @directories ~w(
    config
    sqlite/migrations
    runs
    evidence/app
    evidence/game
    candidates/app
    candidates/game
    reports/app
    reports/game
    packages/app
    packages/game
    market/snapshots
    market/candidates
    market/weekly
    shared
    templates
  )

  def create(attrs) when is_map(attrs) do
    with {:ok, repo_path} <- target_repo_path(attrs),
         :ok <- ensure_target_available(repo_path),
         :ok <- ensure_executable("sqlite3", :sqlite3_unavailable),
         :ok <- ensure_executable("git", :git_unavailable),
         display_name <- display_name(attrs, repo_path),
         :ok <- write_files(repo_path, display_name),
         :ok <- create_sqlite(repo_path),
         :ok <- init_git(repo_path) do
      {:ok,
       %{
         "repo_path" => repo_path,
         "display_name" => display_name,
         "manifest_path" => @manifest_path,
         "schedule_enabled" => attr_value(attrs, "schedule_enabled") || false,
         "schedule_interval_hours" =>
           Factory.trim_nil(attr_value(attrs, "schedule_interval_hours")) || 12
       }}
    end
  end

  def create(_attrs), do: {:error, :repo_path_required}

  defp target_repo_path(attrs) do
    case attrs |> attr_value("repo_path") |> Factory.trim_nil() do
      nil -> {:error, :repo_path_required}
      path -> {:ok, Factory.expand_path(path)}
    end
  end

  defp ensure_target_available(repo_path) do
    cond do
      File.exists?(repo_path) and not File.dir?(repo_path) ->
        {:error, :target_path_not_directory}

      File.dir?(repo_path) ->
        case File.ls(repo_path) do
          {:ok, []} -> :ok
          {:ok, _entries} -> {:error, :target_not_empty}
          {:error, reason} -> {:error, {:target_unreadable, reason}}
        end

      true ->
        :ok
    end
  end

  defp display_name(attrs, repo_path) do
    Factory.trim_nil(attr_value(attrs, "display_name")) ||
      repo_path |> Path.basename() |> Factory.labelize()
  end

  defp ensure_executable(command, error) do
    if System.find_executable(command), do: :ok, else: {:error, error}
  end

  defp write_files(repo_path, display_name) do
    with :ok <- mkdir(repo_path),
         :ok <- write_directories(repo_path),
         :ok <- write_file(repo_path, @manifest_path, manifest(display_name)),
         :ok <- write_file(repo_path, "AGENTS.md", agents_md(display_name)),
         :ok <- write_file(repo_path, "README.md", readme_md(display_name)),
         :ok <- write_file(repo_path, "config/sources.md", sources_md()),
         :ok <- write_file(repo_path, "config/scoring-model.md", scoring_model_md()),
         :ok <- write_file(repo_path, "sqlite/schema.sql", sqlite_schema()),
         :ok <- write_file(repo_path, "shared/rejected-ideas.md", rejected_ideas_md()),
         :ok <- write_file(repo_path, "shared/competitor-index.md", competitor_index_md()),
         :ok <- write_file(repo_path, "templates/app-report.md", app_report_template_md()),
         :ok <- write_file(repo_path, "templates/game-candidate.md", game_candidate_template_md()),
         :ok <- write_file(repo_path, ".gitignore", gitignore()) do
      :ok
    end
  end

  defp mkdir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, path, reason}}
    end
  end

  defp write_directories(repo_path) do
    Enum.reduce_while(@directories, :ok, fn directory, :ok ->
      case mkdir(Path.join(repo_path, directory)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp write_file(repo_path, relative_path, content) do
    full_path = Path.join(repo_path, relative_path)

    with :ok <- mkdir(Path.dirname(full_path)),
         :ok <- File.write(full_path, content, [:exclusive]) do
      :ok
    else
      {:error, :eexist} -> {:error, {:target_file_exists, relative_path}}
      {:error, reason} -> {:error, {:write_failed, relative_path, reason}}
    end
  end

  defp create_sqlite(repo_path) do
    db_path = Path.join(repo_path, "demand.sqlite3")

    case System.cmd("sqlite3", [db_path, sqlite_schema()], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, {:sqlite_schema_failed, String.trim(output)}}
    end
  rescue
    error in ErlangError ->
      case error.original do
        :enoent -> {:error, :sqlite3_unavailable}
        _other -> {:error, {:sqlite_schema_failed, Exception.message(error)}}
      end
  end

  defp init_git(repo_path) do
    case System.cmd("git", ["init"], cd: repo_path, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, {:git_init_failed, String.trim(output)}}
    end
  rescue
    error in ErlangError ->
      case error.original do
        :enoent -> {:error, :git_unavailable}
        _other -> {:error, {:git_init_failed, Exception.message(error)}}
      end
  end

  defp attr_value(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, attr_atom(key))
  end

  defp attr_atom("repo_path"), do: :repo_path
  defp attr_atom("display_name"), do: :display_name
  defp attr_atom("schedule_enabled"), do: :schedule_enabled
  defp attr_atom("schedule_interval_hours"), do: :schedule_interval_hours
  defp attr_atom(_key), do: nil

  defp manifest(display_name) do
    %{
      "schema_version" => 2,
      "kind" => "product_demand_repo",
      "display_name" => display_name,
      "description" => "Unified app and game demand research source repo for AFP.",
      "lanes" => ["app", "game"],
      "agent_contract" => %{
        "entrypoint" => "AGENTS.md",
        "required" => true,
        "skill_policy" => "repo_agents_first",
        "required_skills" => [],
        "optional_skills" => []
      },
      "read_order" => [
        "AGENTS.md",
        "README.md",
        "sqlite/schema.sql",
        "config/*.md",
        "shared/**/*.md",
        "market/**/*.md",
        "runs/**/*.md",
        "candidates/**/*.md",
        "reports/**/*.md",
        "packages/**/*.md",
        "evidence/**/*.md"
      ],
      "write_targets" => %{
        "runs" => "runs",
        "candidates" => "candidates",
        "evidence" => "evidence",
        "reports" => "reports",
        "packages" => "packages",
        "market" => "market"
      },
      "sqlite" => %{
        "path" => "demand.sqlite3",
        "mode" => "required",
        "owner" => "repo",
        "schema_path" => "sqlite/schema.sql",
        "migrations_path" => "sqlite/migrations",
        "allowed_operations" => [
          "read_index",
          "read_candidates",
          "upsert_research_run",
          "upsert_candidate",
          "upsert_source",
          "upsert_score",
          "link_artifact"
        ]
      }
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp agents_md(display_name) do
    """
    # #{display_name} Agent Instructions

    This repository is a demand source repo for AFP. AFP owns orchestration,
    launch requests, operator decisions, Codex session links, and promotion into
    app/game implementation. This repo owns market evidence, candidates,
    reports, product packages, repo-local SQLite, and durable Markdown review
    artifacts.

    ## Read Order

    Read these files before changing research artifacts:

    1. `AGENTS.md`
    2. `README.md`
    3. `sqlite/schema.sql`
    4. `config/sources.md`
    5. `config/scoring-model.md`
    6. Relevant `shared/`, `market/`, `candidates/`, `reports/`, `packages/`, and `evidence/` files

    ## Core Rule

    Do not start from an abstract pain point. Start from proven or ranked demand,
    then narrow to one concrete wedge, packet, artifact, workflow, or playable
    loop. Keep `validation-ready`, `validation-sprint`, and `build-ready`
    separate.

    ## App Lane Method

    AppIdeas is the model for app research: proven demand first, narrow wedge
    second. Use rankings, paid apps, reviews, Reddit, competitor pages, support
    docs, public pricing, search demand, or other concrete demand proof before
    proposing an app.

    For app candidates, Codex should:

    - prove demand with cited or locally recorded evidence;
    - identify the target user and job-to-be-done;
    - describe incumbent weakness without cloning the incumbent;
    - narrow the wedge to a user-owned artifact or specific workflow packet;
    - define exclusions and non-goals;
    - design a validation sprint;
    - avoid saying "build-ready" until direct user proof exists.

    Validation-ready means the demand signal and wedge are credible enough to
    run a sprint. Build-ready means the validation sprint produced direct proof,
    such as user interviews, real redacted folders or workflow samples, and
    willingness-to-pay evidence. A ranked or paid incumbent plus visible pain is
    not enough by itself.

    ## Game Lane Method

    GameIdeas is the model for game research: market signal to playable concept.
    Do not write a PRD from one hot title or trend name. First create or update
    `market/snapshots/`, `market/candidates/`, and `market/weekly/` artifacts.
    Only promote high-quality candidates into `packages/game/<slug>/` after the
    signal, fit, and safety are clear.

    For game candidates, Codex should:

    - scan platform, ranking, paid acquisition, creator, and industry signals;
    - assess short-video native readability and shareability;
    - assess buildability for a lightweight implementation;
    - identify innovation room and what will be borrowed versus avoided;
    - keep assets lightweight;
    - treat IP safety as a first-class gate.

    Borrow mechanics, pacing, and interaction patterns. Do not copy names, art,
    levels, maps, characters, trademarks, monetization framing, or distinctive
    expression from another game.

    ## Scoring

    Use the 100-point model in `config/scoring-model.md`. Scores should move
    only when new evidence changes the decision. If a platform signal is broad
    but lacks title-level rank, revenue, ad, or retention proof, record it as
    directional evidence instead of inflating the score.

    ## Artifact Rules

    Write dated research runs under `runs/YYYY/MM/`.
    Write app candidates under `candidates/app/`.
    Write game candidates under `candidates/game/`.
    Write evidence under `evidence/<lane>/YYYY-MM-DD/`.
    Write reports under `reports/<lane>/`.
    Write app packages under `packages/app/<slug>/`.
    Write game packages under `packages/game/<slug>/`.

    Every durable decision must be visible in Markdown. SQLite is the structured
    index and dedupe layer, not the only review surface.

    ## SQLite Rules

    Use `demand.sqlite3` only according to `sqlite/schema.sql` and the manifest's
    allowed operations. Keep candidate rows aligned with Markdown artifacts.
    Important decisions must also be summarized in Markdown.

    ## Human Gates

    Do not create app or game project repositories.
    Do not launch implementation work.
    Do not promote candidates into AFP apps.
    Do not mark an item as `validation-sprint` or `build-ready` without explicit
    operator approval.
    Do not overwrite existing product packages without creating a new version or
    receiving operator approval.

    ## Status Vocabulary

    Use source statuses: `new`, `researching`, `validation-ready`,
    `validation-sprint`, `build-ready`, `rejected`, `parked`, `watched`,
    `packaged`, `superseded`.

    Keep uncertainty explicit. If proof is missing, write the limitation and the
    next evidence collection step instead of filling the gap with speculation.
    """
  end

  defp readme_md(display_name) do
    """
    <!-- If files in this folder change, update this document. -->

    # #{display_name}

    This is an AFP demand source repository. It stores app and game opportunity
    research outside AFP while exposing a small manifest and SQLite index for
    AFP's `/demand` control plane.

    ## Workflow

    - App lane: proven demand -> incumbent weakness -> narrow wedge -> validation sprint -> package.
    - Game lane: market signal -> playable concept -> IP-safe candidate -> package.
    - AFP owns pickup, launch requests, session links, promotion, and lifecycle routing.
    - This repo owns evidence, candidates, reports, packages, and repo-local SQLite.

    ## Inventory

    - `afp-demand-source.json` - AFP source repo manifest.
    - `AGENTS.md` - Required Codex operating instructions.
    - `config/` - Source and scoring rules.
    - `sqlite/schema.sql` and `demand.sqlite3` - Repo-local structured index.
    - `market/` - Game and market signal snapshots before package creation.
    - `runs/` - Dated research run notes.
    - `candidates/` - Indexed app/game opportunity summaries.
    - `evidence/` - Source logs and proof packets.
    - `reports/` - Deep reports.
    - `packages/` - Operator-approved product package handoffs.
    - `shared/` - Cross-lane indexes and rejection memory.
    - `templates/` - Artifact templates.
    """
  end

  defp sources_md do
    """
    <!-- If files in this folder change, update this document. -->

    # Sources

    Prefer evidence that proves existing demand:

    - paid or top-ranked app charts;
    - public review text and support complaints;
    - Reddit/forum threads with concrete workflows;
    - competitor pricing, changelogs, docs, and feature gaps;
    - platform, creator, ad, or ranking signals for games;
    - industry reports only when they affect a concrete candidate.

    Record source limitations directly in evidence files and reports.
    """
  end

  defp scoring_model_md do
    """
    <!-- If files in this folder change, update this document. -->

    # Scoring Model

    ## App Lane 100-Point Model

    - Demand proof: 30
    - Incumbent weakness: 20
    - Narrow wedge clarity: 20
    - Validation sprint quality: 15
    - Buildability and scope control: 10
    - Monetization plausibility: 5

    `validation-ready` requires credible proof and a narrow sprint. `build-ready`
    requires direct user proof and willingness-to-pay evidence.

    ## Game Lane 100-Point Model

    - Trend strength: 25
    - TikTok-native fit: 20
    - Buildability: 20
    - Innovation room: 15
    - Asset lightness: 10
    - IP safety: 10

    IP safety is also a gate. A high score cannot override clone risk.
    """
  end

  defp rejected_ideas_md do
    """
    <!-- If files in this folder change, update this document. -->

    # Rejected Ideas

    Record rejected, parked, and superseded candidates here when the decision
    should prevent repeated research.
    """
  end

  defp competitor_index_md do
    """
    <!-- If files in this folder change, update this document. -->

    # Competitor Index

    Track competitors that recur across app and game candidates. Keep factual
    observations separate from candidate decisions.
    """
  end

  defp app_report_template_md do
    """
    # App Report Template

    ## Demand Proof

    ## Target User And Job

    ## Incumbent Weakness

    ## Narrow Wedge

    ## Exclusions

    ## Validation Sprint

    ## Build-Ready Criteria

    ## Limitations
    """
  end

  defp game_candidate_template_md do
    """
    # Game Candidate Template

    ## Market Signal

    ## Playable Concept

    ## TikTok-Native Fit

    ## Borrow / Avoid

    ## Buildability

    ## Asset Plan

    ## IP Safety

    ## Limitations
    """
  end

  defp gitignore do
    """
    .DS_Store
    *.tmp
    """
  end

  defp sqlite_schema do
    """
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version TEXT PRIMARY KEY,
      inserted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE IF NOT EXISTS research_runs (
      id TEXT PRIMARY KEY,
      lane TEXT NOT NULL,
      run_type TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'draft',
      input TEXT,
      output_paths TEXT,
      started_at TEXT,
      completed_at TEXT
    );

    CREATE TABLE IF NOT EXISTS candidates (
      id TEXT PRIMARY KEY,
      lane TEXT NOT NULL DEFAULT 'app',
      title TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'new',
      score INTEGER,
      confidence TEXT NOT NULL DEFAULT 'unknown',
      target_user TEXT,
      demand_signal TEXT,
      incumbent_weakness TEXT,
      wedge_hypothesis TEXT,
      validation_action TEXT,
      primary_path TEXT,
      current_report_path TEXT,
      package_path TEXT,
      evidence_paths TEXT,
      observed_at TEXT,
      limitations TEXT,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE IF NOT EXISTS sources (
      id TEXT PRIMARY KEY,
      url_or_path TEXT NOT NULL,
      source_family TEXT,
      reliability TEXT NOT NULL DEFAULT 'unknown',
      access_status TEXT,
      last_observed_at TEXT
    );

    CREATE TABLE IF NOT EXISTS evidence_items (
      id TEXT PRIMARY KEY,
      candidate_id TEXT,
      source_id TEXT,
      summary TEXT NOT NULL,
      evidence_path TEXT,
      observed_at TEXT,
      FOREIGN KEY(candidate_id) REFERENCES candidates(id),
      FOREIGN KEY(source_id) REFERENCES sources(id)
    );

    CREATE TABLE IF NOT EXISTS scores (
      id TEXT PRIMARY KEY,
      candidate_id TEXT NOT NULL,
      dimension TEXT NOT NULL,
      score INTEGER NOT NULL,
      notes TEXT,
      FOREIGN KEY(candidate_id) REFERENCES candidates(id)
    );

    CREATE TABLE IF NOT EXISTS artifacts (
      id TEXT PRIMARY KEY,
      artifact_type TEXT NOT NULL,
      path TEXT NOT NULL,
      title TEXT,
      created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE IF NOT EXISTS candidate_artifacts (
      candidate_id TEXT NOT NULL,
      artifact_id TEXT NOT NULL,
      relation TEXT NOT NULL,
      PRIMARY KEY(candidate_id, artifact_id, relation),
      FOREIGN KEY(candidate_id) REFERENCES candidates(id),
      FOREIGN KEY(artifact_id) REFERENCES artifacts(id)
    );

    INSERT OR IGNORE INTO schema_migrations (version) VALUES ('0001_initial');
    """
  end
end
