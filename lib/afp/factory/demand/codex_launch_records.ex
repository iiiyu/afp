# @input  - A validated launch context and Codex app-server results/progress events
# @output - Persisted launch/run/message state, Codex sessions, and recorded events
# @pos    - Write side of Demand's Codex launch: all DB transactions and event log
defmodule Afp.Factory.Demand.CodexLaunchRecords do
  @moduledoc """
  All database writes and event emission for a Codex launch: the started/
  progress/success/failure transitions across the launch request, research run,
  sent message, and Codex session, plus stale-startup reconciliation writes.
  """

  import Ecto.Query

  require Logger

  alias Afp.Factory
  alias Afp.Factory.Demand
  alias Afp.Factory.Demand.CodexLaunchContext, as: Context
  alias Afp.Factory.Demand.CodexLaunchRequest
  alias Afp.Factory.Demand.ResearchRun
  alias Afp.Factory.Demand.SentMessage
  alias Afp.Factory.Events
  alias Afp.Factory.Sessions.CodexSession
  alias Afp.Repo

  def persist_codex_launch_started(launch_context) do
    now = Factory.now()
    launch_attempt_id = launch_attempt_id(launch_context.launch_request.id, now)

    payload = %{
      "codex_launch_status" => "started",
      "launch_attempt_id" => launch_attempt_id,
      "started_at" => DateTime.to_iso8601(now),
      "latest_progress_at" => DateTime.to_iso8601(now)
    }

    Repo.transaction(fn ->
      launch_request =
        launch_context.launch_request
        |> CodexLaunchRequest.changeset(%{
          "launch_mode" => "direct_codex",
          "status" => "launched",
          "launched_at" => now
        })
        |> Repo.update!()

      research_run =
        launch_context.research_run
        |> ResearchRun.changeset(%{
          "status" => "running",
          "started_at" => now,
          "completed_at" => nil,
          "error" => nil,
          "payload" => payload
        })
        |> Repo.update!()

      sent_message =
        launch_context.sent_message
        |> SentMessage.changeset(%{
          "status" => "accepted",
          "sent_at" => now,
          "failed_at" => nil,
          "payload" => payload
        })
        |> Repo.update!()

      Events.record_event("codex_launch_request", launch_request.id, "launch_request_started", %{
        launch_mode: launch_request.launch_mode,
        research_run_id: research_run.id,
        sent_message_id: sent_message.id
      })

      %{
        launch_request: launch_request,
        research_run: Repo.preload(research_run, [:source_repo, :launch_request, :codex_session]),
        sent_message: Repo.preload(sent_message, [:research_run, :launch_request, :codex_session])
      }
    end)
    |> case do
      {:ok, records} ->
        log_codex_launch_progress("started", launch_context, %{
          "launch_attempt_id" => launch_attempt_id,
          "started_at" => DateTime.to_iso8601(now)
        })

        {:ok, records}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def launch_attempt_id(launch_request_id, now) do
    "#{launch_request_id}:#{DateTime.to_unix(now, :microsecond)}"
  end

  def persist_codex_launch_progress(launch_request_id, :thread_started, thread_response) do
    now = Factory.now()

    with {:ok, launch_context} <-
           Context.codex_launch_context(Demand.get_launch_request!(launch_request_id)) do
      thread = get_in(thread_response, ["result", "thread"]) || %{}
      session_id = thread["sessionId"] || thread["id"]
      model = get_in(thread_response, ["result", "model"])

      result =
        if Factory.blank?(session_id) do
          {:error, :codex_thread_started_without_session_id}
        else
          Repo.transaction(fn ->
            current_run = Repo.get!(ResearchRun, launch_context.research_run.id)
            current_message = Repo.get!(SentMessage, launch_context.sent_message.id)

            session =
              upsert_codex_session!(%{
                "external_session_id" => session_id,
                "cwd" => thread["cwd"] || launch_context.source_repo.repo_path,
                "model" => model,
                "status" => "running",
                "transcript_path" => thread["path"],
                "first_seen_at" => now,
                "last_seen_at" => now,
                "stopped_at" => nil
              })

            progress_payload = %{
              "codex_launch_status" => "thread_started",
              "thread_id" => thread["id"],
              "session_id" => session_id,
              "transcript_path" => thread["path"],
              "model" => model,
              "latest_progress_at" => DateTime.to_iso8601(now)
            }

            run_attrs =
              %{
                "codex_session_id" => session.id,
                "payload" => Context.merge_payload(current_run.payload, progress_payload)
              }
              |> maybe_running_progress_attrs(current_run)

            research_run =
              current_run
              |> ResearchRun.changeset(run_attrs)
              |> Repo.update!()

            current_message
            |> SentMessage.changeset(%{
              "codex_session_id" => session.id,
              "payload" => Context.merge_payload(current_message.payload, progress_payload)
            })
            |> Repo.update!()

            Events.record_event(
              "codex_launch_request",
              launch_context.launch_request.id,
              "launch_request_thread_started",
              %{
                codex_session_id: session.id,
                session_id: session_id,
                research_run_id: research_run.id
              }
            )

            :ok
          end)
          |> case do
            {:ok, :ok} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end

      if result == :ok do
        log_codex_launch_progress("thread_started", launch_context, %{
          "thread_id" => thread["id"],
          "session_id" => session_id,
          "transcript_path" => thread["path"]
        })
      end

      result
    end
  end

  def persist_codex_launch_progress(launch_request_id, :turn_started, turn_response) do
    now = Factory.now()

    with {:ok, launch_context} <-
           Context.codex_launch_context(Demand.get_launch_request!(launch_request_id)) do
      turn = get_in(turn_response, ["result", "turn"]) || %{}

      result =
        Repo.transaction(fn ->
          current_run = Repo.get!(ResearchRun, launch_context.research_run.id)
          current_message = Repo.get!(SentMessage, launch_context.sent_message.id)

          session =
            case current_run.codex_session_id do
              nil -> nil
              session_id -> Repo.get(CodexSession, session_id)
            end

          if session do
            session
            |> CodexSession.changeset(%{
              "latest_turn_id" => turn["id"],
              "status" => "running",
              "last_seen_at" => now,
              "stopped_at" => nil
            })
            |> Repo.update!()
          end

          progress_payload = %{
            "codex_launch_status" => "turn_started",
            "turn_id" => turn["id"],
            "turn_status" => turn["status"],
            "latest_progress_at" => DateTime.to_iso8601(now)
          }

          run_attrs =
            %{
              "payload" => Context.merge_payload(current_run.payload, progress_payload)
            }
            |> maybe_running_progress_attrs(current_run)

          current_run
          |> ResearchRun.changeset(run_attrs)
          |> Repo.update!()

          current_message
          |> SentMessage.changeset(%{
            "payload" => Context.merge_payload(current_message.payload, progress_payload)
          })
          |> Repo.update!()

          Events.record_event(
            "codex_launch_request",
            launch_context.launch_request.id,
            "launch_request_turn_started",
            %{turn_id: turn["id"], turn_status: turn["status"]}
          )

          :ok
        end)
        |> case do
          {:ok, :ok} -> :ok
          {:error, reason} -> {:error, reason}
        end

      if result == :ok do
        log_codex_launch_progress("turn_started", launch_context, %{
          "turn_id" => turn["id"],
          "turn_status" => turn["status"]
        })
      end

      result
    end
  end

  def persist_codex_launch_progress(_launch_request_id, _event, _payload), do: :ok

  def maybe_running_progress_attrs(attrs, %ResearchRun{} = run) do
    if run.status == "running" or stale_startup_failure?(run) do
      Map.merge(attrs, %{
        "status" => "running",
        "completed_at" => nil,
        "error" => nil
      })
    else
      attrs
    end
  end

  def stale_startup_failure?(%ResearchRun{status: "failed", payload: payload, error: error}) do
    Context.payload_value(payload || %{}, "codex_launch_status") == "stale_startup_failed" or
      (is_binary(error) and String.contains?(error, "without thread metadata"))
  end

  def stale_startup_failure?(_run), do: false

  def persist_codex_launch_worker_start_failure(launch_context, reason) do
    now = Factory.now()
    error_text = inspect({:codex_launch_worker_start_failed, reason})

    log_codex_launch_failure("Codex launch worker failed to start", launch_context, error_text)

    Repo.transaction(fn ->
      launch_request = Repo.get!(CodexLaunchRequest, launch_context.launch_request.id)

      launch_request
      |> CodexLaunchRequest.changeset(%{
        "launch_mode" => launch_context.launch_request.launch_mode,
        "status" => launch_context.launch_request.status,
        "launched_at" => launch_context.launch_request.launched_at
      })
      |> Repo.update!()

      launch_context.research_run
      |> ResearchRun.changeset(%{
        "status" => "failed",
        "error" => error_text,
        "completed_at" => now,
        "payload" => %{"codex_error" => error_text}
      })
      |> Repo.update!()

      launch_context.sent_message
      |> SentMessage.changeset(%{
        "status" => "failed",
        "failed_at" => now,
        "payload" => %{"codex_error" => error_text}
      })
      |> Repo.update!()

      Events.record_event(
        "codex_launch_request",
        launch_context.launch_request.id,
        "launch_request_failed",
        %{reason: error_text}
      )
    end)

    :ok
  end

  def persist_codex_launch_success(launch_context, codex_result) do
    now = Factory.now()
    session_attrs = Context.codex_session_attrs(launch_context, codex_result, now)

    Repo.transaction(fn ->
      current_run = Repo.get!(ResearchRun, launch_context.research_run.id)
      current_message = Repo.get!(SentMessage, launch_context.sent_message.id)

      payload =
        Context.merge_payload(
          current_run.payload,
          Context.codex_launch_payload(codex_result, now)
        )

      started_at = current_run.started_at || now
      session = upsert_codex_session!(session_attrs)

      launch_request =
        launch_context.launch_request
        |> CodexLaunchRequest.changeset(%{
          "launch_mode" => "direct_codex",
          "status" => "launched",
          "launched_at" => now
        })
        |> Repo.update!()

      research_run =
        current_run
        |> ResearchRun.changeset(%{
          "codex_session_id" => session.id,
          "status" => "completed",
          "started_at" => started_at,
          "completed_at" => now,
          "error" => nil,
          "payload" => payload
        })
        |> Repo.update!()

      sent_message =
        current_message
        |> SentMessage.changeset(%{
          "codex_session_id" => session.id,
          "status" => "sent",
          "sent_at" => now,
          "failed_at" => nil,
          "payload" => payload
        })
        |> Repo.update!()

      Events.record_event("codex_launch_request", launch_request.id, "launch_request_sent", %{
        launch_mode: launch_request.launch_mode,
        codex_session_id: session.id,
        turn_id: payload["turn_id"]
      })

      %{
        launch_request: launch_request,
        research_run: Repo.preload(research_run, [:source_repo, :launch_request, :codex_session]),
        sent_message:
          Repo.preload(sent_message, [:research_run, :launch_request, :codex_session]),
        codex_session: session,
        codex_result: payload
      }
    end)
    |> case do
      {:ok, records} -> {:ok, records}
      {:error, reason} -> {:error, reason}
    end
  end

  def persist_codex_launch_failure(launch_context, reason) do
    now = Factory.now()
    error_text = inspect(reason)

    log_codex_launch_failure("Codex launch failed", launch_context, error_text)

    Repo.transaction(fn ->
      current_run = Repo.get!(ResearchRun, launch_context.research_run.id)
      current_message = Repo.get!(SentMessage, launch_context.sent_message.id)
      failure_payload = Context.codex_failure_payload(reason, error_text)

      launch_request =
        launch_context.launch_request
        |> CodexLaunchRequest.changeset(%{
          "launch_mode" => "direct_codex",
          "status" => "ready"
        })
        |> Repo.update!()

      if current_run.codex_session_id do
        case Repo.get(CodexSession, current_run.codex_session_id) do
          nil ->
            nil

          session ->
            session
            |> CodexSession.changeset(%{
              "status" => "stopped",
              "last_seen_at" => now,
              "stopped_at" => now
            })
            |> Repo.update!()
        end
      end

      current_run
      |> ResearchRun.changeset(%{
        "status" => "failed",
        "error" => error_text,
        "completed_at" => now,
        "payload" => Context.merge_payload(current_run.payload, failure_payload)
      })
      |> Repo.update!()

      current_message
      |> SentMessage.changeset(%{
        "status" => "failed",
        "failed_at" => now,
        "payload" => Context.merge_payload(current_message.payload, failure_payload)
      })
      |> Repo.update!()

      Events.record_event(
        "codex_launch_request",
        launch_request.id,
        "launch_request_failed",
        %{reason: error_text}
      )
    end)

    :ok
  end

  def log_codex_launch_failure(message, launch_context, error_text) do
    metadata = %{
      launch_request_id: launch_context.launch_request.id,
      research_run_id: launch_context.research_run.id,
      sent_message_id: launch_context.sent_message.id,
      reason: error_text
    }

    Logger.error("#{message}: #{inspect(metadata)}")
    IO.puts(:stdio, "[error] #{message}: #{inspect(metadata)}")
  end

  def log_codex_launch_progress(event, launch_context, metadata) do
    payload =
      metadata
      |> Map.merge(%{
        "event" => event,
        "launch_request_id" => launch_context.launch_request.id,
        "research_run_id" => launch_context.research_run.id,
        "sent_message_id" => launch_context.sent_message.id
      })

    Logger.info("Codex launch progress: #{inspect(payload)}")
    IO.puts(:stdio, "[codex-launch] progress #{inspect(payload)}")
  end

  def upsert_codex_session!(attrs) do
    existing = Repo.get_by(CodexSession, external_session_id: attrs["external_session_id"])

    (existing || %CodexSession{})
    |> CodexSession.changeset(attrs)
    |> Repo.insert_or_update!()
  end

  def mark_stale_codex_startup_failed(%ResearchRun{} = run, now, startup_grace_ms) do
    error_text =
      "Codex launch stayed in startup without thread metadata for more than " <>
        "#{div(startup_grace_ms, 1_000)} seconds; marked failed and retryable."

    Logger.warning("Reconciled stale Codex launch startup",
      research_run_id: run.id,
      launch_request_id: run.codex_launch_request_id,
      reason: error_text
    )

    IO.puts(
      :stdio,
      "[codex-launch] stale running research_run=#{run.id} launch_request=#{run.codex_launch_request_id} marked failed"
    )

    Repo.transaction(fn ->
      launch_request =
        run.launch_request || Repo.get(CodexLaunchRequest, run.codex_launch_request_id)

      if launch_request do
        launch_request
        |> CodexLaunchRequest.changeset(%{
          "launch_mode" => "direct_codex",
          "status" => "ready"
        })
        |> Repo.update!()
      end

      failed_run =
        run
        |> ResearchRun.changeset(%{
          "status" => "failed",
          "error" => error_text,
          "completed_at" => now,
          "payload" =>
            Context.merge_payload(run.payload, %{
              "codex_launch_status" => "stale_startup_failed",
              "codex_error" => error_text,
              "reconciled_at" => DateTime.to_iso8601(now)
            })
        })
        |> Repo.update!()

      SentMessage
      |> where([message], message.codex_launch_request_id == ^run.codex_launch_request_id)
      |> Repo.all()
      |> Enum.each(fn message ->
        message
        |> SentMessage.changeset(%{
          "status" => "failed",
          "failed_at" => now,
          "payload" =>
            Context.merge_payload(message.payload, %{
              "codex_launch_status" => "stale_startup_failed",
              "codex_error" => error_text,
              "reconciled_at" => DateTime.to_iso8601(now)
            })
        })
        |> Repo.update!()
      end)

      Events.record_event(
        "codex_launch_request",
        run.codex_launch_request_id,
        "launch_request_stale_startup_failed",
        %{research_run_id: run.id, reason: error_text}
      )

      failed_run
    end)
    |> case do
      {:ok, failed_run} -> failed_run
      {:error, reason} -> {:error, reason}
    end
  end
end
