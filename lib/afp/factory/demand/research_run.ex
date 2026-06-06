# @input  - Demand source, candidate, template, launch request, and run state attrs
# @output - Persisted research-run records for scheduled and manual demand work
# @pos    - Run metadata boundary between AFP orchestration and repo-owned artifacts
defmodule Afp.Factory.Demand.ResearchRun do
  use Afp.Factory.Schema

  alias Afp.Factory
  alias Afp.Factory.JsonData

  schema "demand_research_runs" do
    field :run_type, :string
    field :lane, :string
    field :input_text, :string
    field :input_url, :string
    field :objective, :string
    field :rendered_message, :string
    field :output_paths, {:array, :string}, default: []
    field :status, :string, default: "draft"
    field :error, :string
    field :limitations, :string
    field :review_note, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :payload, JsonData, default: %{}

    belongs_to :source_repo, Afp.Factory.Demand.SourceRepo, foreign_key: :demand_source_repo_id
    belongs_to :candidate, Afp.Factory.Demand.Candidate, foreign_key: :demand_candidate_id
    belongs_to :message_template, Afp.Factory.Demand.MessageTemplate

    belongs_to :launch_request, Afp.Factory.Demand.CodexLaunchRequest,
      foreign_key: :codex_launch_request_id

    belongs_to :codex_session, Afp.Factory.Sessions.CodexSession
    has_many :sent_messages, Afp.Factory.Demand.SentMessage, foreign_key: :demand_research_run_id

    timestamps()
  end

  def changeset(run, attrs) do
    attrs = normalize_attrs(attrs)

    run
    |> cast(attrs, [
      :demand_source_repo_id,
      :demand_candidate_id,
      :message_template_id,
      :codex_launch_request_id,
      :codex_session_id,
      :run_type,
      :lane,
      :input_text,
      :input_url,
      :objective,
      :rendered_message,
      :output_paths,
      :status,
      :error,
      :limitations,
      :review_note,
      :started_at,
      :completed_at,
      :payload
    ])
    |> normalize_text_fields([
      :run_type,
      :lane,
      :input_text,
      :input_url,
      :objective,
      :rendered_message,
      :status,
      :error,
      :limitations,
      :review_note
    ])
    |> put_default(:run_type, "manual_idea")
    |> put_default(:status, "draft")
    |> validate_required([:run_type, :objective, :status])
    |> validate_inclusion(:run_type, Factory.demand_research_run_types())
    |> validate_inclusion(:status, Factory.demand_research_run_statuses())
    |> validate_lane()
    |> foreign_key_constraint(:demand_source_repo_id)
    |> foreign_key_constraint(:demand_candidate_id)
    |> foreign_key_constraint(:message_template_id)
    |> foreign_key_constraint(:codex_launch_request_id)
    |> foreign_key_constraint(:codex_session_id)
  end

  defp normalize_attrs(attrs) when is_map(attrs), do: normalize_lines(attrs, :output_paths)
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

  defp validate_lane(changeset) do
    case get_field(changeset, :lane) do
      nil -> changeset
      _lane -> validate_inclusion(changeset, :lane, Factory.demand_lanes())
    end
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
