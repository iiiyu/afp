# @input  - Indexed demand repo candidate summaries and operator routing decisions
# @output - Normalized AFP read-model records for app and game opportunities
# @pos    - Candidate pool boundary that separates repo-owned status from AFP pickup state
defmodule Afp.Factory.Demand.Candidate do
  use Afp.Factory.Schema

  alias Afp.Factory
  alias Afp.Factory.JsonData

  schema "demand_candidates" do
    field :lane, :string
    field :external_id, :string
    field :title, :string
    field :source_status, :string, default: "new"
    field :afp_status, :string, default: "not_picked_up"
    field :score, :integer
    field :confidence, :string, default: "unknown"
    field :target_user, :string
    field :demand_signal, :string
    field :incumbent_weakness, :string
    field :wedge_hypothesis, :string
    field :validation_action, :string
    field :primary_path, :string
    field :report_path, :string
    field :package_path, :string
    field :evidence_paths, {:array, :string}, default: []
    field :observed_at, :date
    field :limitations, :string
    field :review_note, :string
    field :picked_up_at, :utc_datetime_usec
    field :approved_for_package_at, :utc_datetime_usec
    field :handed_off_at, :utc_datetime_usec
    field :rejected_at, :utc_datetime_usec
    field :parked_at, :utc_datetime_usec
    field :payload, JsonData, default: %{}

    belongs_to :source_repo, Afp.Factory.Demand.SourceRepo, foreign_key: :demand_source_repo_id
    belongs_to :demand_item, Afp.Factory.Demand.DemandItem
    has_many :research_runs, Afp.Factory.Demand.ResearchRun, foreign_key: :demand_candidate_id

    timestamps()
  end

  def changeset(candidate, attrs) do
    attrs = normalize_attrs(attrs)

    candidate
    |> cast(attrs, [
      :demand_source_repo_id,
      :demand_item_id,
      :lane,
      :external_id,
      :title,
      :source_status,
      :afp_status,
      :score,
      :confidence,
      :target_user,
      :demand_signal,
      :incumbent_weakness,
      :wedge_hypothesis,
      :validation_action,
      :primary_path,
      :report_path,
      :package_path,
      :evidence_paths,
      :observed_at,
      :limitations,
      :review_note,
      :picked_up_at,
      :approved_for_package_at,
      :handed_off_at,
      :rejected_at,
      :parked_at,
      :payload
    ])
    |> normalize_text_fields([
      :lane,
      :external_id,
      :title,
      :source_status,
      :afp_status,
      :confidence,
      :target_user,
      :demand_signal,
      :incumbent_weakness,
      :wedge_hypothesis,
      :validation_action,
      :primary_path,
      :report_path,
      :package_path,
      :limitations,
      :review_note
    ])
    |> put_default(:lane, "app")
    |> put_default(
      :external_id,
      external_id_from_title(get_field(candidate_changeset_stub(attrs), :title))
    )
    |> put_default(:source_status, "new")
    |> put_default(:afp_status, "not_picked_up")
    |> put_default(:confidence, "unknown")
    |> validate_required([
      :demand_source_repo_id,
      :lane,
      :external_id,
      :title,
      :source_status,
      :afp_status,
      :confidence
    ])
    |> validate_inclusion(:lane, Factory.demand_lanes())
    |> validate_inclusion(:source_status, Factory.demand_candidate_source_statuses())
    |> validate_inclusion(:afp_status, Factory.demand_candidate_afp_statuses())
    |> validate_inclusion(:confidence, Factory.demand_confidences())
    |> validate_number(:score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> foreign_key_constraint(:demand_source_repo_id)
    |> foreign_key_constraint(:demand_item_id)
    |> unique_constraint([:demand_source_repo_id, :lane, :external_id])
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    normalize_lines(attrs, :evidence_paths)
  end

  defp normalize_attrs(attrs), do: attrs

  defp normalize_lines(attrs, field) do
    value = Map.get(attrs, Atom.to_string(field)) || Map.get(attrs, field)

    if is_binary(value) do
      put_existing(attrs, field, Factory.lines_to_list(value))
    else
      attrs
    end
  end

  defp normalize_text_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      value = get_change(acc, field)

      if is_binary(value) do
        put_change(acc, field, Factory.trim_nil(value))
      else
        acc
      end
    end)
  end

  defp put_default(changeset, field, default) do
    if Factory.blank?(get_field(changeset, field)) do
      put_change(changeset, field, default)
    else
      changeset
    end
  end

  defp external_id_from_title(title) when is_binary(title), do: Factory.slugify(title)
  defp external_id_from_title(_title), do: nil

  defp candidate_changeset_stub(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:title])
    |> normalize_text_fields([:title])
  end

  defp put_existing(attrs, field, value) do
    string_key = Atom.to_string(field)

    cond do
      Map.has_key?(attrs, string_key) -> Map.put(attrs, string_key, value)
      Map.has_key?(attrs, field) -> Map.put(attrs, field, value)
      true -> attrs
    end
  end
end
