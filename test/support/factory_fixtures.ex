# @input  - Factory contexts and temporary local filesystem paths
# @output - Focused test fixtures for app-factory domain records
# @pos    - Test helper module for context, controller, and LiveView coverage
defmodule Afp.FactoryFixtures do
  alias Afp.Factory.Evidence
  alias Afp.Factory.Portfolio
  alias Afp.Factory.Releases
  alias Afp.Factory.Work

  def unique_integer, do: System.unique_integer([:positive])

  def unique_repo_path do
    path = Path.join(System.tmp_dir!(), "afp-test-repo-#{unique_integer()}")
    File.mkdir_p!(path)
    path
  end

  def app_fixture(attrs \\ %{}) do
    defaults = %{
      "name" => "Test App #{unique_integer()}",
      "repo_path" => unique_repo_path(),
      "platforms" => "ios, web",
      "lifecycle_stage" => "build_ready",
      "business_posture" => "unknown",
      "next_action" => "Prepare next release"
    }

    {:ok, app} = Portfolio.create_app(Map.merge(defaults, attrs))
    app
  end

  def ticket_fixture(app, attrs \\ %{}) do
    defaults = %{
      "app_id" => app.id,
      "title" => "Ticket #{unique_integer()}",
      "status" => "ready",
      "risk_level" => "normal"
    }

    {:ok, ticket} = Work.create_ticket(Map.merge(defaults, attrs))
    ticket
  end

  def release_fixture(app, attrs \\ %{}) do
    defaults = %{
      "app_id" => app.id,
      "platform" => "ios",
      "version" => "1.0.#{unique_integer()}"
    }

    {:ok, release} = Releases.create_release_target(Map.merge(defaults, attrs))
    Releases.get_release_target!(release.id)
  end

  def evidence_fixture(app, attrs \\ %{}) do
    defaults = %{
      "app_id" => app.id,
      "type" => "manual",
      "summary" => "Evidence summary #{unique_integer()}",
      "reliability" => "verified"
    }

    {:ok, evidence} = Evidence.create_evidence_packet(Map.merge(defaults, attrs))
    evidence
  end
end
