# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

alias Afp.Factory.Evidence
alias Afp.Factory.Evidence.EvidenceLink
alias Afp.Factory.Evidence.EvidencePacket
alias Afp.Factory.Metrics
alias Afp.Factory.Metrics.MetricsSnapshot
alias Afp.Factory.Portfolio
alias Afp.Factory.Portfolio.App
alias Afp.Factory.Releases
alias Afp.Factory.Releases.ReleaseTarget
alias Afp.Factory.Sessions
alias Afp.Factory.Settings
alias Afp.Factory.Work
alias Afp.Factory.Work.HarnessPacket
alias Afp.Factory.Work.Ticket
alias Afp.Repo

seed_apps = [
  %{
    "name" => "BabyTracker",
    "repo_path" => "/Users/ewan/Developer/Apps/BabyTracker",
    "platforms" => "ios, watchos",
    "lifecycle_stage" => "iterating",
    "business_posture" => "grow",
    "next_action" => "Review AI-backed event flow and prepare next validation packet."
  },
  %{
    "name" => "MysticLens",
    "repo_path" => "/Users/ewan/Developer/Apps/MysticLens",
    "platforms" => "ios",
    "lifecycle_stage" => "in_build",
    "business_posture" => "unknown",
    "next_action" => "Validate Worker-backed AI boundary and release blockers."
  },
  %{
    "name" => "OhMyCalculator",
    "repo_path" => "/Users/ewan/Developer/Apps/OhMyCalculator",
    "platforms" => "ios",
    "lifecycle_stage" => "release_ready",
    "business_posture" => "maintain",
    "next_action" => "Run release readiness checks and confirm App Store metadata."
  },
  %{
    "name" => "TirzeTracker",
    "repo_path" => "/Users/ewan/Developer/Apps/TirzeTracker",
    "platforms" => "ios, android",
    "lifecycle_stage" => "live",
    "business_posture" => "maintain",
    "next_action" => "Capture business snapshot and review remove-ads funnel."
  },
  %{
    "name" => "YCalculator",
    "repo_path" => "/Users/ewan/Developer/Apps/ycalculator",
    "platforms" => "ios",
    "lifecycle_stage" => "submitted",
    "business_posture" => "fix",
    "next_action" => "Track App Review state and prepare follow-up evidence."
  }
]

Settings.add_repository_root("/Users/ewan/Developer/Apps")

apps =
  Enum.map(seed_apps, fn attrs ->
    case Repo.get_by(App, repo_path: attrs["repo_path"]) do
      nil ->
        {:ok, app} = Portfolio.create_app(attrs)
        app

      app ->
        {:ok, app} = Portfolio.update_app(app, attrs)
        app
    end
  end)

tickets =
  Enum.map(apps, fn app ->
    title = "Dogfood checkpoint: #{app.name}"

    Repo.get_by(Ticket, app_id: app.id, title: title) ||
      case Work.create_ticket(%{
             "app_id" => app.id,
             "title" => title,
             "description" => "Seeded dogfood ticket for app-factory control plane validation.",
             "status" => "active",
             "lifecycle_gate" => app.lifecycle_stage,
             "risk_level" => "normal"
           }) do
        {:ok, ticket} -> ticket
      end
  end)

[first_app | _rest] = apps
[first_ticket | _rest_tickets] = tickets

packet_objective = "Validate one complete dogfood loop for #{first_app.name}."

Repo.get_by(HarnessPacket, ticket_id: first_ticket.id, objective: packet_objective) ||
  Work.create_harness_packet_from_ticket(first_ticket, %{
    "objective" => packet_objective,
    "expected_output" => "A linked evidence-backed review path exists in the control plane.",
    "verification_plan" =>
      "Confirm app, ticket, session, release, evidence, and metrics records render.",
    "required_evidence" => "Seed evidence packet and release checklist proof.",
    "review_route" => "Manual review in App detail cockpit.",
    "risk_level" => "normal"
  })

session_id = "seed-dogfood-session"

{:ok, _hook_event, session} =
  Sessions.receive_hook(%{
    "session_id" => session_id,
    "cwd" => first_app.repo_path,
    "hook_event_name" => "start",
    "model" => "gpt-5",
    "payload" => %{"seed" => true}
  })

Sessions.link_session(session, first_app.id, first_ticket.id, "Seeded dogfood link")

Sessions.receive_hook(%{
  "session_id" => session_id,
  "cwd" => first_app.repo_path,
  "hook_event_name" => "stop"
})

Sessions.review_session(Sessions.get_session!(session.id), %{
  "decision" => "pass",
  "review_note" => "Seeded dogfood session reviewed."
})

release =
  Repo.get_by(ReleaseTarget, app_id: first_app.id, version: "dogfood-1") ||
    case Releases.create_release_target(%{
           "app_id" => first_app.id,
           "platform" => "ios",
           "version" => "dogfood-1",
           "label" => "Dogfood release"
         }) do
      {:ok, release} -> release
    end

release = Releases.get_release_target!(release.id)

Enum.each(release.release_check_items, fn item ->
  Releases.update_check_item(item, %{
    "status" => "passed",
    "decision_note" => "Seeded dogfood checklist pass."
  })
end)

evidence_summary =
  "Seeded dogfood evidence proving a complete control-plane loop can be represented."

evidence =
  Repo.get_by(EvidencePacket, app_id: first_app.id, summary: evidence_summary) ||
    case Evidence.create_evidence_packet(%{
           "app_id" => first_app.id,
           "type" => "validation_note",
           "summary" => evidence_summary,
           "reliability" => "verified"
         }) do
      {:ok, evidence} -> evidence
    end

ensure_evidence_link = fn packet, subject_type, subject_id, reason ->
  Repo.get_by(EvidenceLink,
    evidence_packet_id: packet.id,
    subject_type: subject_type,
    subject_id: subject_id
  ) || Evidence.attach_evidence(packet, subject_type, subject_id, reason)
end

ensure_evidence_link.(evidence, "app", first_app.id, "Dogfood app evidence")
ensure_evidence_link.(evidence, "ticket", first_ticket.id, "Dogfood ticket evidence")
ensure_evidence_link.(evidence, "release_target", release.id, "Dogfood release evidence")

live_app = Enum.find(apps, &(&1.lifecycle_stage == "live")) || first_app

Repo.get_by(MetricsSnapshot, app_id: live_app.id, snapshot_date: Date.utc_today()) ||
  Metrics.create_metrics_snapshot(%{
    "app_id" => live_app.id,
    "snapshot_date" => Date.utc_today(),
    "downloads" => 0,
    "revenue" => 0,
    "notes" => "Seeded manual business snapshot for dogfood validation."
  })
