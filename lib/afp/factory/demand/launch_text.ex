# @input  - Demand launch templates, source/candidate/run records, sessions, and attrs
# @output - Rendered launch text, template variables, and human-readable context strings
# @pos    - Internal text-rendering module for Demand's launch workflow
defmodule Afp.Factory.Demand.LaunchText do
  alias Afp.Factory
  alias Afp.Factory.Demand.Candidate
  alias Afp.Factory.Demand.CodexLaunchRequest
  alias Afp.Factory.Demand.DemandItem
  alias Afp.Factory.Demand.MessageTemplate
  alias Afp.Factory.Demand.ResearchRun
  alias Afp.Factory.Demand.SourceRepo
  alias Afp.Factory.Sessions.CodexSession

  @workflow_attr_atoms %{
    "run_type" => :run_type,
    "lane" => :lane,
    "input_text" => :input_text,
    "input_url" => :input_url,
    "objective" => :objective,
    "review_note" => :review_note
  }

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

  def source_template_variables(%SourceRepo{} = source_repo, attrs) do
    %{
      "repo_path" => source_repo.repo_path,
      "source_repo_path" => source_repo.repo_path,
      "source_display_name" => source_repo.display_name,
      "agent_entrypoint" => source_repo.agent_entrypoint || "AGENTS.md",
      "run_type" => attr_text(attrs, "run_type"),
      "lane" => attr_text(attrs, "lane"),
      "input_text" => attr_text(attrs, "input_text"),
      "input_url" => attr_text(attrs, "input_url"),
      "objective" => attr_text(attrs, "objective"),
      "write_targets" => Jason.encode!(source_repo.write_targets || %{}),
      "sqlite_path" => source_repo.sqlite_path,
      "sqlite_allowed_operations" => Enum.join(source_repo.sqlite_allowed_operations || [], "\n")
    }
  end

  def run_template_variables(
        %ResearchRun{} = research_run,
        %CodexSession{} = codex_session,
        attrs
      ) do
    source_repo = research_run.source_repo
    candidate = research_run.candidate
    review_note = attr_text(attrs, "review_note") || research_run.review_note

    %{
      "repo_path" => source_repo && source_repo.repo_path,
      "source_repo_path" => source_repo && source_repo.repo_path,
      "source_display_name" => source_repo && source_repo.display_name,
      "agent_entrypoint" => (source_repo && source_repo.agent_entrypoint) || "AGENTS.md",
      "run_id" => research_run.id,
      "run_type" => research_run.run_type,
      "lane" => research_run.lane,
      "objective" => research_run.objective,
      "input_text" => research_run.input_text,
      "input_url" => research_run.input_url,
      "candidate_id" => candidate && candidate.external_id,
      "candidate_title" => candidate && candidate.title,
      "session_id" => codex_session.external_session_id,
      "session_cwd" => codex_session.cwd,
      "session_status" => codex_session.status,
      "review_note" => review_note,
      "output_paths" => Enum.join(research_run.output_paths || [], "\n")
    }
  end

  def candidate_template_variables(%Candidate{} = candidate) do
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

  def source_launch_context(%SourceRepo{} = source_repo, run_type, lane, input_text, input_url) do
    [
      "Demand source repo: #{source_repo.repo_path}",
      "Repo instructions: #{source_repo.agent_entrypoint || "AGENTS.md"}",
      "Run type: #{run_type}",
      "Lane: #{lane}",
      "Input text: #{input_text || "none"}",
      "Input URL: #{input_url || "none"}",
      "SQLite path: #{source_repo.sqlite_path || "not declared"}",
      "Allowed SQLite operations: #{Enum.join(source_repo.sqlite_allowed_operations || [], ", ")}",
      "Human confirmation is required before sending, package generation, promotion, project repo creation, or implementation launch."
    ]
    |> Enum.join("\n")
  end

  def session_followup_context(%ResearchRun{} = research_run, %CodexSession{} = codex_session) do
    source_repo = research_run.source_repo
    candidate = research_run.candidate

    [
      "Demand research run: #{research_run.id}",
      "Run type: #{research_run.run_type}",
      "Objective: #{research_run.objective}",
      "Source repo: #{source_repo && source_repo.repo_path}",
      "Candidate: #{candidate && candidate.title}",
      "Existing Codex session: #{codex_session.external_session_id}",
      "Session cwd: #{codex_session.cwd || "unknown"}",
      "Session status: #{codex_session.status}",
      "Review note: #{research_run.review_note || "none"}",
      "Human confirmation is required before applying risky follow-up changes, package overwrite, project repo creation, promotion, or implementation launch."
    ]
    |> Enum.join("\n")
  end

  def candidate_launch_context(%Candidate{} = candidate) do
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

  def launch_context_from_demand(%DemandItem{} = demand_item) do
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

  defp attr_text(attrs, key), do: Factory.trim_nil(attr_value(attrs, key))

  defp attr_value(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, Map.get(@workflow_attr_atoms, key))
  end

  defp attr_value(_attrs, _key), do: nil
end
