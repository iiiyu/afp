# @input  - Ticket state changes, harness packet params, and app next actions
# @output - Ticket workflow and executable harness packet operations
# @pos    - Context boundary for work items and harness contracts
defmodule Afp.Factory.Work do
  import Ecto.Query

  alias Afp.Factory
  alias Afp.Factory.Events
  alias Afp.Factory.Portfolio
  alias Afp.Factory.Portfolio.App
  alias Afp.Factory.Work.HarnessPacket
  alias Afp.Factory.Work.Ticket
  alias Afp.Repo

  @ticket_transitions %{
    "backlog" => ~w(ready active blocked dropped),
    "ready" => ~w(active blocked done dropped),
    "active" => ~w(review blocked done dropped),
    "review" => ~w(active blocked done dropped),
    "blocked" => ~w(ready active done dropped),
    "done" => ~w(ready),
    "dropped" => ~w(backlog)
  }

  def list_tickets(params \\ %{}) do
    Ticket
    |> preload([:app, :harness_packets, :codex_sessions])
    |> apply_filter(:app_id, Map.get(params, "app_id") || Map.get(params, :app_id))
    |> apply_filter(:status, Map.get(params, "status") || Map.get(params, :status))
    |> apply_filter(
      :lifecycle_gate,
      Map.get(params, "lifecycle_gate") || Map.get(params, :lifecycle_gate)
    )
    |> order_by([ticket], asc: ticket.status, desc: ticket.updated_at)
    |> Repo.all()
  end

  def list_active_tickets_for_app(app_id) do
    Ticket
    |> where([ticket], ticket.app_id == ^app_id and ticket.status not in ["done", "dropped"])
    |> order_by([ticket], asc: ticket.status, desc: ticket.updated_at)
    |> Repo.all()
  end

  def count_active_tickets(app_id) do
    Ticket
    |> where([ticket], ticket.app_id == ^app_id and ticket.status not in ["done", "dropped"])
    |> Repo.aggregate(:count)
  end

  def get_ticket!(id) do
    Ticket
    |> Repo.get!(id)
    |> Repo.preload([:app, :harness_packets, :codex_sessions])
  end

  def get_ticket(id) when is_binary(id) do
    Ticket
    |> Repo.get(id)
    |> case do
      nil -> nil
      ticket -> Repo.preload(ticket, [:app, :harness_packets, :codex_sessions])
    end
  end

  def get_ticket(_id), do: nil

  def change_ticket(%Ticket{} = ticket, attrs \\ %{}) do
    Ticket.changeset(ticket, attrs)
  end

  def create_ticket(attrs) do
    %Ticket{}
    |> Ticket.changeset(attrs)
    |> Repo.insert()
    |> after_ticket_write("ticket_created")
  end

  def create_ticket_from_next_action(%App{} = app, attrs \\ %{}) do
    title =
      Map.get(attrs, "title") || Map.get(attrs, :title) || app.next_action || "Define next action"

    attrs =
      attrs
      |> Map.put("app_id", app.id)
      |> Map.put_new("title", title)
      |> Map.put_new("status", "ready")
      |> Map.put_new("lifecycle_gate", app.lifecycle_stage)

    create_ticket(attrs)
  end

  def transition_ticket(%Ticket{} = ticket, target_status, attrs \\ %{}) do
    cond do
      target_status not in Factory.ticket_statuses() ->
        {:error, :invalid_ticket_status}

      target_status not in Map.get(@ticket_transitions, ticket.status, []) ->
        {:error, :invalid_ticket_transition}

      requires_reopen_note?(ticket.status, target_status) and blank_param?(attrs, "review_note") ->
        {:error, :note_required}

      target_status == "blocked" and blank_param?(attrs, "blocked_reason") ->
        {:error, :blocked_reason_required}

      target_status == "done" and not done_allowed?(ticket, attrs) ->
        {:error, :review_or_evidence_required}

      true ->
        attrs =
          attrs
          |> Map.put("status", target_status)
          |> put_terminal_timestamps(target_status)

        ticket
        |> Ticket.changeset(attrs)
        |> Repo.update()
        |> after_ticket_write("ticket_transitioned", %{to: target_status})
    end
  end

  def mark_ticket_review_prompt(%Ticket{} = ticket, session_id) do
    attrs = %{
      "status" => "review",
      "review_note" => "Codex session stopped and requires manual review."
    }

    ticket
    |> Ticket.changeset(attrs)
    |> Repo.update()
    |> after_ticket_write("ticket_review_prompted", %{session_id: session_id})
  end

  def list_harness_packets(params \\ %{}) do
    HarnessPacket
    |> preload([:app, :ticket, :release_target])
    |> apply_filter(:app_id, Map.get(params, "app_id") || Map.get(params, :app_id))
    |> apply_filter(:ticket_id, Map.get(params, "ticket_id") || Map.get(params, :ticket_id))
    |> apply_filter(:state, Map.get(params, "state") || Map.get(params, :state))
    |> order_by([packet], desc: packet.updated_at)
    |> Repo.all()
  end

  def get_harness_packet!(id) do
    HarnessPacket
    |> Repo.get!(id)
    |> Repo.preload([:app, :ticket, :release_target])
  end

  def change_harness_packet(%HarnessPacket{} = packet, attrs \\ %{}) do
    HarnessPacket.changeset(packet, attrs)
  end

  def create_harness_packet(attrs) do
    attrs = populate_repository_path(attrs)

    %HarnessPacket{}
    |> HarnessPacket.changeset(attrs)
    |> Repo.insert()
    |> after_packet_write("harness_packet_created")
  end

  def create_harness_packet_from_ticket(%Ticket{} = ticket, attrs \\ %{}) do
    ticket = Repo.preload(ticket, :app)

    attrs =
      attrs
      |> Map.put("app_id", ticket.app_id)
      |> Map.put("ticket_id", ticket.id)
      |> Map.put_new("lifecycle_gate", ticket.lifecycle_gate)
      |> Map.put_new("repository_path", ticket.app && ticket.app.repo_path)
      |> Map.put_new("objective", ticket.title)

    create_harness_packet(attrs)
  end

  def mark_harness_packet_ready(%HarnessPacket{} = packet, attrs \\ %{}) do
    risk_level = Map.get(attrs, "risk_level") || packet.risk_level
    confirmed? = Map.get(attrs, "confirm_high_risk") in ["true", true, "1", 1]

    if risk_level in ["high", "critical"] and not confirmed? do
      {:error, :high_risk_confirmation_required}
    else
      packet
      |> HarnessPacket.ready_changeset(attrs)
      |> Repo.update()
      |> after_packet_write("harness_packet_readied")
    end
  end

  def mark_harness_packet_launched(%HarnessPacket{} = packet) do
    packet
    |> HarnessPacket.changeset(%{"state" => "launched", "launch_mode" => "manual"})
    |> Repo.update()
    |> after_packet_write("harness_packet_launched")
  end

  def update_harness_packet(%HarnessPacket{} = packet, attrs) do
    packet
    |> HarnessPacket.changeset(attrs)
    |> Repo.update()
    |> after_packet_write("harness_packet_updated")
  end

  def handoff_text(%HarnessPacket{} = packet) do
    packet = Repo.preload(packet, [:app, :ticket, :release_target])

    """
    # Harness Packet

    App: #{packet.app && packet.app.name}
    Repository: #{packet.repository_path || (packet.app && packet.app.repo_path) || "not specified"}
    Lifecycle gate: #{packet.lifecycle_gate || "not specified"}
    Ticket: #{(packet.ticket && packet.ticket.title) || "none"}
    Risk: #{packet.risk_level}
    Review route: #{packet.review_route || "manual review in AFP"}

    ## Objective
    #{packet.objective}

    ## Context Inputs
    #{inspect(packet.context_inputs, pretty: true, limit: :infinity)}

    ## Constraints
    #{inspect(packet.constraints, pretty: true, limit: :infinity)}

    ## Non-goals
    #{inspect(packet.non_goals, pretty: true, limit: :infinity)}

    ## Allowed Tools
    #{inspect(packet.allowed_tools, pretty: true, limit: :infinity)}

    ## Expected Output
    #{packet.expected_output || "not specified"}

    ## Verification Plan
    #{inspect(packet.verification_plan, pretty: true, limit: :infinity)}

    ## Required Evidence
    #{inspect(packet.required_evidence, pretty: true, limit: :infinity)}

    ## Approval Points
    #{inspect(packet.approval_points, pretty: true, limit: :infinity)}

    ## Completion Contract
    Do not mark related AFP tickets done automatically. Report result summary,
    evidence paths, tests run, and any next route for manual review.
    """
    |> String.trim()
  end

  defp done_allowed?(%Ticket{} = ticket, attrs) do
    not blank_param?(attrs, "review_note") or
      Afp.Factory.Evidence.count_links("ticket", ticket.id) > 0
  end

  defp requires_reopen_note?("done", "ready"), do: true
  defp requires_reopen_note?("dropped", "backlog"), do: true
  defp requires_reopen_note?(_from, _to), do: false

  defp put_terminal_timestamps(attrs, "done") do
    attrs
    |> Map.put("done_at", Factory.now())
    |> Map.put("dropped_at", nil)
  end

  defp put_terminal_timestamps(attrs, "dropped") do
    attrs
    |> Map.put("dropped_at", Factory.now())
    |> Map.put("done_at", nil)
  end

  defp put_terminal_timestamps(attrs, _status), do: attrs

  defp populate_repository_path(attrs) do
    repository_path = Map.get(attrs, "repository_path") || Map.get(attrs, :repository_path)
    app_id = Map.get(attrs, "app_id") || Map.get(attrs, :app_id)

    cond do
      Factory.present?(repository_path) ->
        attrs

      Factory.blank?(app_id) ->
        attrs

      app = Portfolio.get_app(app_id) ->
        Map.put(attrs, "repository_path", app.repo_path)

      true ->
        attrs
    end
  end

  defp after_ticket_write({:ok, %Ticket{} = ticket}, event_type) do
    after_ticket_write({:ok, ticket}, event_type, %{})
  end

  defp after_ticket_write(result, _event_type), do: result

  defp after_ticket_write({:ok, %Ticket{} = ticket}, event_type, payload) do
    Events.record_event(
      "ticket",
      ticket.id,
      event_type,
      Map.merge(%{app_id: ticket.app_id, title: ticket.title}, payload)
    )

    {:ok, ticket}
  end

  defp after_ticket_write(result, _event_type, _payload), do: result

  defp after_packet_write({:ok, %HarnessPacket{} = packet}, event_type) do
    Events.record_event("harness_packet", packet.id, event_type, %{
      app_id: packet.app_id,
      ticket_id: packet.ticket_id,
      state: packet.state
    })

    {:ok, packet}
  end

  defp after_packet_write(result, _event_type), do: result

  defp apply_filter(query, _field, value) when value in [nil, ""], do: query

  defp apply_filter(query, field, value),
    do: where(query, [record], field(record, ^field) == ^value)

  defp blank_param?(attrs, key) do
    value = Map.get(attrs, key) || Map.get(attrs, param_atom(key))
    Factory.blank?(value)
  end

  defp param_atom("review_note"), do: :review_note
  defp param_atom("blocked_reason"), do: :blocked_reason
  defp param_atom(_key), do: :unknown
end
