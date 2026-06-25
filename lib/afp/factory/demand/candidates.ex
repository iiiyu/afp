# @input  - Demand source repos, candidate attrs, routing attrs, and package paths
# @output - Candidate indexing, routing transitions, package verification, pickup records
# @pos    - Demand-candidate implementation behind the public Demand context facade
defmodule Afp.Factory.Demand.Candidates do
  import Ecto.Query

  alias Ecto.Changeset

  alias Afp.Factory
  alias Afp.Factory.Demand.Candidate
  alias Afp.Factory.Demand.DemandItem
  alias Afp.Factory.Demand.Items
  alias Afp.Factory.Demand.SourceRepo
  alias Afp.Factory.Events
  alias Afp.Repo

  @candidate_attr_atoms %{"demand_status" => :demand_status}

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

  def inspect_candidate_package(%Candidate{} = candidate) do
    candidate = Repo.preload(candidate, :source_repo)

    with {:ok, package_root} <- candidate_package_root(candidate) do
      required_files = required_package_files(candidate.lane)

      required_paths =
        Enum.map(required_files, fn file ->
          %{relative_path: file, full_path: Path.join(package_root, file)}
        end)

      missing_paths =
        required_paths
        |> Enum.reject(&File.regular?(&1.full_path))
        |> Enum.map(& &1.relative_path)

      {:ok,
       %{
         package_root: package_root,
         required_files: required_files,
         missing_paths: missing_paths,
         ready?: missing_paths == []
       }}
    end
  end

  def verify_candidate_package(%Candidate{} = candidate, attrs \\ %{}) do
    case inspect_candidate_package(candidate) do
      {:ok, %{ready?: true} = inspection} ->
        attrs =
          attrs
          |> Map.put_new(
            "review_note",
            "Package verified at #{Path.relative_to_cwd(inspection.package_root)}."
          )

        transition_candidate(candidate, "package_ready", attrs)

      {:ok, %{missing_paths: missing_paths}} ->
        {:error, {:package_missing, missing_paths}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def mark_candidate_handoff_ready(%Candidate{} = candidate, attrs \\ %{}) do
    transition_candidate(candidate, "handoff_ready", attrs)
  end

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

    case Items.create_demand_item(demand_attrs) do
      {:ok, %DemandItem{} = demand_item} -> demand_item
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp candidate_source_label(%Candidate{source_repo: %SourceRepo{} = source_repo, lane: lane}) do
    "#{source_repo.display_name} / #{lane}"
  end

  defp candidate_source_label(%Candidate{lane: lane}), do: "Demand source / #{lane}"

  defp source_artifact_path(nil, path), do: path
  defp source_artifact_path(_source_repo, nil), do: nil

  defp source_artifact_path(%SourceRepo{} = source_repo, path),
    do: Path.join(source_repo.repo_path, path)

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

  defp candidate_package_root(%Candidate{source_repo: nil}), do: {:error, :source_repo_missing}

  defp candidate_package_root(%Candidate{package_path: package_path})
       when package_path in [nil, ""],
       do: {:error, :package_path_missing}

  defp candidate_package_root(%Candidate{} = candidate) do
    source_root = Factory.expand_path(candidate.source_repo.repo_path)

    package_root =
      if Path.type(candidate.package_path) == :absolute do
        Factory.expand_path(candidate.package_path)
      else
        source_root
        |> Path.join(candidate.package_path)
        |> Factory.expand_path()
      end

    if package_root == source_root or String.starts_with?(package_root, source_root <> "/") do
      {:ok, package_root}
    else
      {:error, :package_outside_source_repo}
    end
  end

  defp required_package_files("game"), do: ~w(PRD.md DESIGN_KIT.md IMPLEMENTATION_BRIEF.md)

  defp required_package_files(_lane) do
    ~w(README.md PRD.md VALIDATION_PLAN.md MVP_SCOPE.md DATA_MODEL.md UX_FLOW.md PROTOTYPE.md)
  end

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

  defp apply_filter(query, _field, value) when value in [nil, ""], do: query

  defp apply_filter(query, field, value),
    do: where(query, [record], field(record, ^field) == ^value)

  defp filter_value(params, key) when is_map(params), do: Map.get(params, key)
  defp filter_value(_params, _key), do: nil

  defp attr_value_or_atom(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, Map.get(@candidate_attr_atoms, key))
  end

  defp attr_value_or_atom(_attrs, _key), do: nil
end
