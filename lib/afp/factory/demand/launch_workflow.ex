# @input  - Demand sources, candidates, templates, sessions, launch attrs, and run attrs
# @output - Rendered launch handoffs plus persisted launch/run/message records
# @pos    - Deep workflow module behind Demand's source, candidate, and follow-up launches
defmodule Afp.Factory.Demand.LaunchWorkflow do
  @moduledoc """
  Creates Demand launch workflows from caller intent.

  Source repo launches, candidate launches, and existing-session follow-ups all
  create the same launch/request/run/message record set. This module owns those
  defaults and transaction paths so callers only name the intent.
  """

  alias Afp.Factory
  alias Afp.Factory.Demand.Candidate
  alias Afp.Factory.Demand.CodexLaunchRequest
  alias Afp.Factory.Demand.DemandItem
  alias Afp.Factory.Demand.LaunchText
  alias Afp.Factory.Demand.MessageTemplate
  alias Afp.Factory.Demand.ResearchRun
  alias Afp.Factory.Demand.SentMessage
  alias Afp.Factory.Demand.SourceRepo
  alias Afp.Factory.Events
  alias Afp.Factory.Sessions.CodexSession
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

  @workflow_attr_atoms %{
    "edited_body" => :edited_body,
    "status" => :status,
    "title" => :title,
    "objective" => :objective,
    "risk_level" => :risk_level,
    "launch_mode" => :launch_mode,
    "confirmation" => :confirmation,
    "run_type" => :run_type,
    "lane" => :lane,
    "input_text" => :input_text,
    "input_url" => :input_url,
    "review_note" => :review_note
  }

  def render_message_template(%MessageTemplate{} = template, variables) when is_map(variables) do
    LaunchText.render_message_template(template, variables)
  end

  def create_source_launch_request(
        %SourceRepo{} = source_repo,
        %MessageTemplate{} = template,
        attrs
      ) do
    with {:ok, rendered_message} <-
           render_message_template(
             template,
             LaunchText.source_template_variables(source_repo, attrs)
           ) do
      create_launch_records(source_launch_plan(source_repo, template, attrs, rendered_message))
    end
  end

  def create_candidate_launch_request(
        %Candidate{} = candidate,
        %MessageTemplate{} = template,
        attrs
      ) do
    candidate = Repo.preload(candidate, [:source_repo, :demand_item])

    with {:ok, rendered_message} <-
           render_message_template(template, LaunchText.candidate_template_variables(candidate)) do
      create_launch_records(candidate_launch_plan(candidate, template, attrs, rendered_message))
    end
  end

  def create_session_followup(
        %ResearchRun{} = research_run,
        %CodexSession{} = codex_session,
        %MessageTemplate{} = template,
        attrs
      ) do
    research_run = Repo.preload(research_run, [:source_repo, :candidate, :launch_request])

    with {:ok, rendered_message} <-
           render_message_template(
             template,
             LaunchText.run_template_variables(research_run, codex_session, attrs)
           ) do
      create_followup_records(
        followup_launch_plan(research_run, codex_session, template, attrs, rendered_message)
      )
    end
  end

  def create_research_run(attrs) do
    %ResearchRun{}
    |> ResearchRun.changeset(attrs)
    |> Repo.insert()
    |> after_research_run_write("demand_research_run_created")
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
      |> put_if_blank("context", LaunchText.launch_context_from_demand(demand_item))

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
    LaunchText.launch_handoff_text(launch_request)
  end

  defp create_launch_records(plan) do
    Repo.transaction(fn ->
      with {:ok, launch_request} <- create_launch_request(plan.launch_attrs),
           {:ok, research_run} <-
             create_research_run(
               Map.put(plan.run_attrs, "codex_launch_request_id", launch_request.id)
             ),
           {:ok, sent_message} <-
             insert_sent_message(
               plan.message_attrs
               |> Map.put("demand_research_run_id", research_run.id)
               |> Map.put("codex_launch_request_id", launch_request.id)
             ) do
        maybe_touch_source_last_run(plan)

        %{
          launch_request: launch_request,
          research_run: research_run,
          sent_message: sent_message
        }
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, records} -> {:ok, records}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_followup_records(plan) do
    Repo.transaction(fn ->
      with {:ok, launch_request} <- create_launch_request(plan.launch_attrs) do
        research_run =
          plan.research_run
          |> ResearchRun.changeset(
            Map.put(plan.run_attrs, "codex_launch_request_id", launch_request.id)
          )
          |> Repo.update!()

        case insert_sent_message(
               plan.message_attrs
               |> Map.put("demand_research_run_id", research_run.id)
               |> Map.put("codex_launch_request_id", launch_request.id)
             ) do
          {:ok, sent_message} ->
            %{
              launch_request: launch_request,
              research_run:
                Repo.preload(research_run, [:source_repo, :candidate, :codex_session]),
              sent_message: sent_message
            }

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, records} -> {:ok, records}
      {:error, reason} -> {:error, reason}
    end
  end

  defp source_launch_plan(%SourceRepo{} = source_repo, template, attrs, rendered_message) do
    base = common_launch_fields(attrs, rendered_message)
    run_type = attr_text(attrs, "run_type") || template.default_run_type
    lane = attr_text(attrs, "lane") || template.default_lane
    input_text = attr_text(attrs, "input_text")
    input_url = attr_text(attrs, "input_url")
    title = attr_text(attrs, "title") || "#{template.name}: #{source_repo.display_name}"
    objective = attr_text(attrs, "objective") || template.purpose || title

    %{
      source_repo: source_repo,
      launch_attrs: %{
        "source_type" => "demand_source_repo",
        "source_id" => source_repo.id,
        "title" => title,
        "objective" => objective,
        "context" =>
          LaunchText.source_launch_context(source_repo, run_type, lane, input_text, input_url),
        "risk_level" => base.risk_level,
        "launch_mode" => base.launch_mode,
        "status" => base.status,
        "confirmation" => base.confirmation,
        "handoff_text" => base.handoff_text
      },
      run_attrs: %{
        "demand_source_repo_id" => source_repo.id,
        "message_template_id" => template.id,
        "run_type" => run_type,
        "lane" => lane,
        "input_text" => input_text,
        "input_url" => input_url,
        "objective" => objective,
        "rendered_message" => rendered_message,
        "output_paths" => template.expected_output_paths,
        "status" => run_status(base.status)
      },
      message_attrs: message_attrs(template, base, rendered_message)
    }
  end

  defp candidate_launch_plan(%Candidate{} = candidate, template, attrs, rendered_message) do
    base = common_launch_fields(attrs, rendered_message)
    title = attr_text(attrs, "title") || "#{template.name}: #{candidate.title}"
    objective = attr_text(attrs, "objective") || template.purpose || title

    %{
      launch_attrs: %{
        "source_type" => "demand_candidate",
        "source_id" => candidate.id,
        "title" => title,
        "objective" => objective,
        "context" => LaunchText.candidate_launch_context(candidate),
        "risk_level" => base.risk_level,
        "launch_mode" => base.launch_mode,
        "status" => base.status,
        "confirmation" => base.confirmation,
        "handoff_text" => base.handoff_text
      },
      run_attrs: %{
        "demand_source_repo_id" => candidate.demand_source_repo_id,
        "demand_candidate_id" => candidate.id,
        "message_template_id" => template.id,
        "run_type" => template.default_run_type,
        "lane" => candidate.lane,
        "objective" => objective,
        "rendered_message" => rendered_message,
        "output_paths" => template.expected_output_paths,
        "status" => run_status(base.status)
      },
      message_attrs: message_attrs(template, base, rendered_message)
    }
  end

  defp followup_launch_plan(research_run, codex_session, template, attrs, rendered_message) do
    base = common_launch_fields(attrs, rendered_message)

    title =
      attr_text(attrs, "title") ||
        "#{template.name}: continue #{codex_session.external_session_id}"

    objective = attr_text(attrs, "objective") || template.purpose || title

    %{
      research_run: research_run,
      launch_attrs: %{
        "source_type" => "demand_research_run",
        "source_id" => research_run.id,
        "title" => title,
        "objective" => objective,
        "context" => LaunchText.session_followup_context(research_run, codex_session),
        "risk_level" => base.risk_level,
        "launch_mode" => base.launch_mode,
        "status" => base.status,
        "confirmation" => base.confirmation,
        "handoff_text" => base.handoff_text
      },
      run_attrs: %{
        "message_template_id" => template.id,
        "codex_session_id" => codex_session.id,
        "rendered_message" => rendered_message,
        "status" => if(base.status == "ready", do: "ready", else: research_run.status),
        "review_note" => attr_text(attrs, "review_note") || research_run.review_note
      },
      message_attrs:
        message_attrs(template, base, rendered_message)
        |> Map.put("codex_session_id", codex_session.id)
        |> Map.put("target", "existing_session")
    }
  end

  defp common_launch_fields(attrs, rendered_message) do
    edited_body = attr_text(attrs, "edited_body")

    %{
      edited_body: edited_body,
      handoff_text: edited_body || rendered_message,
      status: attr_text(attrs, "status") || "ready",
      risk_level: attr_text(attrs, "risk_level") || "normal",
      launch_mode: attr_text(attrs, "launch_mode") || "manual_handoff",
      confirmation: attr_text(attrs, "confirmation")
    }
  end

  defp message_attrs(template, base, rendered_message) do
    %{
      "message_template_id" => template.id,
      "target" => template.default_target,
      "status" => message_status(base.status),
      "rendered_body" => rendered_message,
      "edited_body" => base.edited_body,
      "confirmed_at" => confirmed_at(base.status)
    }
  end

  defp insert_sent_message(attrs) do
    %SentMessage{}
    |> SentMessage.changeset(attrs)
    |> Repo.insert()
    |> after_sent_message_write("demand_sent_message_created")
  end

  defp maybe_touch_source_last_run(%{source_repo: %SourceRepo{} = source_repo}) do
    source_repo
    |> SourceRepo.changeset(%{"last_run_at" => Factory.now()})
    |> Repo.update!()
  end

  defp maybe_touch_source_last_run(_plan), do: nil

  defp run_status("ready"), do: "ready"
  defp run_status(_status), do: "draft"

  defp message_status("ready"), do: "confirmed"
  defp message_status(_status), do: "draft"

  defp confirmed_at("ready"), do: Factory.now()
  defp confirmed_at(_status), do: nil

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

  defp after_sent_message_write({:ok, %SentMessage{} = sent_message}, event_type) do
    Events.record_event("demand_sent_message", sent_message.id, event_type, %{
      research_run_id: sent_message.demand_research_run_id,
      launch_request_id: sent_message.codex_launch_request_id,
      status: sent_message.status
    })

    {:ok, Repo.preload(sent_message, [:research_run, :message_template, :launch_request])}
  end

  defp after_sent_message_write(result, _event_type), do: result

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

  defp attr_text(attrs, key), do: Factory.trim_nil(attr_value(attrs, key))

  defp attr_value(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) ||
      Map.get(attrs, Map.get(@workflow_attr_atoms, key)) ||
      Map.get(attrs, Map.get(@launch_attr_atoms, key))
  end

  defp attr_value(_attrs, _key), do: nil

  defp put_if_blank(attrs, key, value) do
    if Factory.blank?(Map.get(attrs, key) || Map.get(attrs, Map.get(@launch_attr_atoms, key))) do
      Map.put(attrs, key, value)
    else
      attrs
    end
  end
end
