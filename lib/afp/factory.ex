# @input  - User-submitted params, dates, paths, and compact text fields
# @output - Shared factory constants and normalization helpers
# @pos    - Cross-context utility module for the one-person app factory domain
defmodule Afp.Factory do
  @lifecycle_stages ~w(idea validation_ready validation_sprint build_ready in_build release_ready submitted live iterating maintained paused archived)
  @business_postures ~w(unknown grow maintain fix harvest pause kill)
  @ticket_statuses ~w(backlog ready active review blocked done dropped)
  @packet_states ~w(draft ready launched observing review routed superseded)
  @session_statuses ~w(detected linked running waiting stopped reviewed ignored)
  @release_statuses ~w(draft preparing ready_for_review submitted live blocked cancelled)
  @demand_statuses ~w(captured researching validating validated promoted rejected parked)
  @demand_confidences ~w(unknown low medium high)
  @demand_lanes ~w(app game)
  @demand_source_health_states ~w(unknown healthy missing not_git manifest_missing invalid_manifest invalid_structure agents_missing sqlite_missing sqlite_invalid skills_unavailable unsupported)
  @demand_candidate_source_statuses ~w(new researching validation-ready validation-sprint build-ready rejected parked watched packaged superseded)
  @demand_candidate_afp_statuses ~w(not_picked_up pickup_recommended picked_up package_requested package_ready handoff_ready promoted rejected parked)
  @demand_research_run_types ~w(scheduled_scan manual_idea manual_url deep_research package_generation repo_audit session_continue)
  @demand_research_run_statuses ~w(draft ready launched running completed failed cancelled reviewed)
  @demand_message_targets ~w(new_session existing_session manual_handoff)
  @demand_sent_message_statuses ~w(draft confirmed sent accepted failed superseded)
  @launch_request_statuses ~w(draft ready launched cancelled)
  @launch_modes ~w(manual_handoff direct_codex supervised)
  @build_run_statuses ~w(queued running verifying completed failed)
  @app_repo_health_states ~w(unknown healthy missing agents_missing manifest_missing invalid_manifest verify_missing state_db_missing state_db_invalid)
  @check_statuses ~w(pending passed failed waived not_applicable)
  @risk_levels ~w(low normal high critical)
  @priorities ~w(low normal high urgent)
  @health_states ~w(unknown healthy needs_next_action repo_missing repo_dirty blocked release_blocked review metrics_stale maintenance_due growth_review archived)
  @evidence_types ~w(manual file_path url command_log summary screenshot metadata_diff validation_note review_note)
  @reliabilities ~w(unknown low medium high verified)
  @intake_modes ~w(neither http jsonl both)
  @repo_scan_statuses ~w(unknown healthy dirty missing not_git error)
  @experiment_statuses ~w(idea ready running review won lost paused dropped)
  @maintenance_statuses ~w(open due blocked done dropped)
  @maintenance_categories ~w(maintenance compliance release support dependency privacy analytics)

  def lifecycle_stages, do: @lifecycle_stages
  def business_postures, do: @business_postures
  def ticket_statuses, do: @ticket_statuses
  def packet_states, do: @packet_states
  def session_statuses, do: @session_statuses
  def release_statuses, do: @release_statuses
  def demand_statuses, do: @demand_statuses
  def demand_confidences, do: @demand_confidences
  def demand_lanes, do: @demand_lanes
  def demand_source_health_states, do: @demand_source_health_states
  def demand_candidate_source_statuses, do: @demand_candidate_source_statuses
  def demand_candidate_afp_statuses, do: @demand_candidate_afp_statuses
  def demand_research_run_types, do: @demand_research_run_types
  def demand_research_run_statuses, do: @demand_research_run_statuses
  def demand_message_targets, do: @demand_message_targets
  def demand_sent_message_statuses, do: @demand_sent_message_statuses
  def launch_request_statuses, do: @launch_request_statuses
  def launch_modes, do: @launch_modes
  def build_run_statuses, do: @build_run_statuses
  def app_repo_health_states, do: @app_repo_health_states
  def check_statuses, do: @check_statuses
  def risk_levels, do: @risk_levels
  def priorities, do: @priorities
  def health_states, do: @health_states
  def evidence_types, do: @evidence_types
  def reliabilities, do: @reliabilities
  def intake_modes, do: @intake_modes
  def repo_scan_statuses, do: @repo_scan_statuses
  def experiment_statuses, do: @experiment_statuses
  def maintenance_statuses, do: @maintenance_statuses
  def maintenance_categories, do: @maintenance_categories

  def options(values), do: Enum.map(values, &{labelize(&1), &1})

  def now do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
  end

  def blank?(value), do: value in [nil, ""]
  def present?(value), do: not blank?(value)

  def trim_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def trim_nil(value), do: value

  def slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "app"
      slug -> slug
    end
  end

  def slugify(_value), do: "app"

  def normalize_platforms(platforms) when is_binary(platforms) do
    platforms
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  def normalize_platforms(platforms) when is_list(platforms) do
    platforms
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  def normalize_platforms(_platforms), do: []

  def lines_to_list(value) when is_binary(value) do
    value
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&blank?/1)
  end

  def lines_to_list(value) when is_list(value), do: value
  def lines_to_list(_value), do: []

  def labelize(value) when is_atom(value), do: value |> Atom.to_string() |> labelize()

  def labelize(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def labelize(value), do: to_string(value)

  def repo_path_matches?(nil, _cwd), do: false
  def repo_path_matches?("", _cwd), do: false
  def repo_path_matches?(_repo_path, nil), do: false
  def repo_path_matches?(_repo_path, ""), do: false

  def repo_path_matches?(repo_path, cwd) do
    repo = expand_path(repo_path)
    current = expand_path(cwd)

    current == repo or String.starts_with?(current, repo <> "/")
  end

  def expand_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> Path.expand()
    |> Path.join("")
    |> String.trim_trailing("/")
  end

  def expand_path(path), do: path
end
