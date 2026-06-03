# @input  - Codex hook payloads, manual session links, ignore/review decisions
# @output - Hook event intake, Codex sessions, ticket links, and review prompts
# @pos    - Context boundary for the Codex session bridge
defmodule Afp.Factory.Sessions do
  import Ecto.Query

  alias Afp.Factory
  alias Afp.Factory.Events
  alias Afp.Factory.Evidence
  alias Afp.Factory.Portfolio
  alias Afp.Factory.Sessions.CodexSession
  alias Afp.Factory.Sessions.HookEvent
  alias Afp.Factory.Sessions.TicketSessionLink
  alias Afp.Factory.Work
  alias Afp.Repo

  @known_hook_fields ~w(session_id cwd hook_event_name model transcript_path turn_id timestamp payload)

  def list_sessions(params \\ %{}) do
    CodexSession
    |> preload([:app, :tickets])
    |> apply_filter(:app_id, Map.get(params, "app_id") || Map.get(params, :app_id))
    |> apply_filter(:status, Map.get(params, "status") || Map.get(params, :status))
    |> order_by([session], desc_nulls_last: session.last_seen_at, desc: session.inserted_at)
    |> Repo.all()
  end

  def list_hook_events(limit \\ 100) do
    HookEvent
    |> order_by([event], desc: event.received_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_unlinked_sessions do
    CodexSession
    |> where([session], is_nil(session.app_id) and session.status != "ignored")
    |> order_by([session], desc_nulls_last: session.last_seen_at)
    |> Repo.all()
  end

  def list_stopped_review_sessions do
    CodexSession
    |> where([session], session.status == "stopped")
    |> preload([:app, :tickets])
    |> order_by([session], desc_nulls_last: session.stopped_at)
    |> Repo.all()
  end

  def count_active_sessions(app_id) do
    CodexSession
    |> where(
      [session],
      session.app_id == ^app_id and session.status in ["linked", "running", "waiting"]
    )
    |> Repo.aggregate(:count)
  end

  def get_session!(id) do
    CodexSession
    |> Repo.get!(id)
    |> Repo.preload([:app, :tickets])
  end

  def receive_hook(attrs) when is_map(attrs) do
    extracted = extract_hook_attrs(attrs)

    Repo.transaction(fn ->
      hook_event =
        %HookEvent{}
        |> HookEvent.changeset(extracted.hook_event)
        |> Repo.insert!()

      session = upsert_session_from_hook!(hook_event)

      Events.record_event("hook_event", hook_event.id, "codex_hook_received", %{
        external_session_id: hook_event.external_session_id,
        event_name: hook_event.event_name,
        session_id: session && session.id
      })

      {hook_event, session}
    end)
    |> case do
      {:ok, {hook_event, session}} -> {:ok, hook_event, session}
      {:error, reason} -> {:error, reason}
    end
  end

  def link_session(%CodexSession{} = session, app_id, ticket_id \\ nil, link_reason \\ nil) do
    Repo.transaction(fn ->
      session =
        session
        |> CodexSession.changeset(%{app_id: app_id, status: "linked"})
        |> Repo.update!()

      link =
        if Factory.present?(ticket_id) do
          %TicketSessionLink{}
          |> TicketSessionLink.changeset(%{
            ticket_id: ticket_id,
            codex_session_id: session.id,
            link_reason: link_reason
          })
          |> Repo.insert!(
            on_conflict: :nothing,
            conflict_target: [:ticket_id, :codex_session_id]
          )
        end

      Events.record_event("codex_session", session.id, "session_linked", %{
        app_id: app_id,
        ticket_id: ticket_id,
        link_reason: link_reason
      })

      {session, link}
    end)
    |> case do
      {:ok, {session, _link}} -> {:ok, Repo.preload(session, [:app, :tickets])}
      {:error, reason} -> {:error, reason}
    end
  end

  def mark_ignored(%CodexSession{} = session, note \\ nil) do
    session
    |> CodexSession.changeset(%{status: "ignored", ignored_at: Factory.now()})
    |> Repo.update()
    |> after_session_write("session_ignored", %{note: note})
  end

  def review_session(%CodexSession{} = session, attrs) do
    decision = Map.get(attrs, "decision") || Map.get(attrs, :decision)
    note = Map.get(attrs, "review_note") || Map.get(attrs, :review_note)
    evidence_summary = Map.get(attrs, "evidence_summary") || Map.get(attrs, :evidence_summary)
    evidence_count = Afp.Factory.Evidence.count_links("codex_session", session.id)

    cond do
      decision not in ~w(pass needs_work blocked reject) ->
        {:error, :invalid_review_decision}

      decision == "pass" and Factory.blank?(note) and Factory.blank?(evidence_summary) and
          evidence_count == 0 ->
        {:error, :review_or_evidence_required}

      decision == "blocked" and
          Factory.blank?(Map.get(attrs, "blocked_reason") || Map.get(attrs, :blocked_reason)) ->
        {:error, :blocked_reason_required}

      true ->
        Repo.transaction(fn ->
          session =
            session
            |> CodexSession.changeset(%{
              status: "reviewed",
              reviewed_at: Factory.now(),
              summary: note || session.summary
            })
            |> Repo.update!()
            |> Repo.preload(:tickets)

          maybe_create_review_evidence(session, attrs)
          route_reviewed_tickets(session.tickets, decision, attrs)

          Events.record_event("codex_session", session.id, "session_reviewed", %{
            decision: decision,
            review_note: note
          })

          session
        end)
        |> case do
          {:ok, session} -> {:ok, session}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp upsert_session_from_hook!(%HookEvent{} = hook_event) do
    external_session_id = hook_event.external_session_id || fallback_session_id(hook_event)
    app = Portfolio.match_app_by_cwd(hook_event.cwd)
    now = hook_event.received_at || Factory.now()
    existing = Repo.get_by(CodexSession, external_session_id: external_session_id)
    status = status_from_hook(hook_event.event_name, app, existing)

    attrs = %{
      external_session_id: external_session_id,
      app_id: app && app.id,
      cwd: hook_event.cwd,
      model: hook_event.model,
      status: status,
      transcript_path: hook_event.transcript_path,
      latest_turn_id: hook_event.turn_id,
      first_seen_at: (existing && existing.first_seen_at) || now,
      last_seen_at: now,
      stopped_at: stopped_at(status, existing, now)
    }

    session =
      (existing || %CodexSession{})
      |> CodexSession.changeset(attrs)
      |> Repo.insert_or_update!()

    hook_event
    |> HookEvent.changeset(%{processed_at: Factory.now()})
    |> Repo.update!()

    Events.record_event("codex_session", session.id, "session_observed", %{
      event_name: hook_event.event_name,
      app_id: session.app_id,
      status: session.status
    })

    if session.status == "stopped" do
      prompt_linked_tickets(session)
    end

    session
  rescue
    error ->
      hook_event
      |> HookEvent.changeset(%{
        processed_at: Factory.now(),
        processing_error: Exception.message(error)
      })
      |> Repo.update!()

      reraise error, __STACKTRACE__
  end

  defp prompt_linked_tickets(%CodexSession{} = session) do
    session
    |> Repo.preload(:tickets)
    |> Map.fetch!(:tickets)
    |> Enum.filter(&(&1.status not in ["done", "dropped"]))
    |> Enum.each(fn ticket -> Work.mark_ticket_review_prompt(ticket, session.id) end)
  end

  defp route_reviewed_tickets(tickets, "pass", attrs) do
    Enum.each(tickets, fn ticket ->
      Work.transition_ticket(ticket, "done", %{
        "review_note" => Map.get(attrs, "review_note") || Map.get(attrs, :review_note)
      })
    end)
  end

  defp route_reviewed_tickets(tickets, "needs_work", attrs) do
    Enum.each(tickets, fn ticket ->
      Work.transition_ticket(ticket, "active", %{
        "review_note" => Map.get(attrs, "review_note") || Map.get(attrs, :review_note)
      })
    end)
  end

  defp route_reviewed_tickets(tickets, "blocked", attrs) do
    Enum.each(tickets, fn ticket ->
      Work.transition_ticket(ticket, "blocked", %{
        "blocked_reason" => Map.get(attrs, "blocked_reason") || Map.get(attrs, :blocked_reason),
        "review_note" => Map.get(attrs, "review_note") || Map.get(attrs, :review_note)
      })
    end)
  end

  defp route_reviewed_tickets(tickets, "reject", attrs) do
    Enum.each(tickets, fn ticket ->
      Work.transition_ticket(ticket, "dropped", %{
        "review_note" => Map.get(attrs, "review_note") || Map.get(attrs, :review_note)
      })
    end)
  end

  defp maybe_create_review_evidence(session, attrs) do
    summary = Map.get(attrs, "evidence_summary") || Map.get(attrs, :evidence_summary)

    first_ticket = List.first(session.tickets)
    app_id = session.app_id || (first_ticket && first_ticket.app_id)

    if Factory.present?(summary) and app_id != nil do
      {:ok, packet, _links} =
        Evidence.create_evidence_packet(
          %{
            "app_id" => app_id,
            "type" => "review_note",
            "title" => "Codex review evidence: #{session.external_session_id}",
            "summary" => summary,
            "source_path" => session.transcript_path,
            "reliability" => "medium"
          },
          [
            %{
              "subject_type" => "codex_session",
              "subject_id" => session.id,
              "link_reason" => "Session review evidence"
            }
            | Enum.map(session.tickets, fn ticket ->
                %{
                  "subject_type" => "ticket",
                  "subject_id" => ticket.id,
                  "link_reason" => "Evidence captured during session review"
                }
              end)
          ]
        )

      packet
    else
      nil
    end
  end

  defp extract_hook_attrs(attrs) do
    payload = Map.get(attrs, "payload") || Map.get(attrs, :payload) || %{}
    unknown = Map.drop(attrs, @known_hook_fields) |> stringify_keys()

    event_payload =
      if is_map(payload) do
        Map.merge(stringify_keys(payload), unknown)
      else
        Map.put(unknown, "payload", payload)
      end

    %{
      hook_event: %{
        external_session_id: Map.get(attrs, "session_id") || Map.get(attrs, :session_id),
        event_name:
          Map.get(attrs, "hook_event_name") || Map.get(attrs, :hook_event_name) || "unknown",
        cwd: Map.get(attrs, "cwd") || Map.get(attrs, :cwd),
        model: Map.get(attrs, "model") || Map.get(attrs, :model),
        transcript_path: Map.get(attrs, "transcript_path") || Map.get(attrs, :transcript_path),
        turn_id: Map.get(attrs, "turn_id") || Map.get(attrs, :turn_id),
        payload: event_payload,
        received_at:
          parse_timestamp(Map.get(attrs, "timestamp") || Map.get(attrs, :timestamp)) ||
            Factory.now()
      }
    }
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(value) when is_binary(value) do
    with {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
      DateTime.truncate(datetime, :microsecond)
    else
      _error -> nil
    end
  end

  defp parse_timestamp(%DateTime{} = value), do: DateTime.truncate(value, :microsecond)
  defp parse_timestamp(_value), do: nil

  defp status_from_hook(_event_name, _app, %CodexSession{status: status})
       when status in ["ignored", "reviewed"], do: status

  defp status_from_hook(event_name, app, _existing) do
    normalized = String.downcase(to_string(event_name))

    cond do
      String.contains?(normalized, ["stop", "finish", "complete"]) -> "stopped"
      String.contains?(normalized, ["wait", "ask"]) -> "waiting"
      String.contains?(normalized, ["start", "resume", "submit", "tool", "run"]) -> "running"
      app != nil -> "linked"
      true -> "detected"
    end
  end

  defp stopped_at("stopped", %CodexSession{stopped_at: stopped_at}, now), do: stopped_at || now
  defp stopped_at("stopped", nil, now), do: now
  defp stopped_at(_status, existing, _now), do: existing && existing.stopped_at

  defp fallback_session_id(%HookEvent{} = hook_event) do
    hash =
      :crypto.hash(
        :sha256,
        "#{hook_event.cwd}|#{hook_event.event_name}|#{DateTime.to_iso8601(hook_event.received_at)}"
      )
      |> Base.encode16(case: :lower)
      |> String.slice(0, 16)

    "hook-#{hash}"
  end

  defp after_session_write({:ok, %CodexSession{} = session}, event_type, payload) do
    Events.record_event("codex_session", session.id, event_type, payload)
    {:ok, session}
  end

  defp after_session_write(result, _event_type, _payload), do: result

  defp apply_filter(query, _field, value) when value in [nil, ""], do: query

  defp apply_filter(query, field, value),
    do: where(query, [record], field(record, ^field) == ^value)
end
