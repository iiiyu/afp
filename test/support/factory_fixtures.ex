# @input  - Factory contexts and temporary local filesystem paths
# @output - Focused test fixtures for app-factory domain records
# @pos    - Test helper module for context, controller, and LiveView coverage
defmodule Afp.FactoryFixtures do
  alias Afp.Factory.Portfolio

  def unique_integer, do: System.unique_integer([:positive])

  def unique_repo_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "afp-test-repo-#{System.os_time(:microsecond)}-#{unique_integer()}"
      )

    File.mkdir_p!(path)
    path
  end

  def temp_git_repo_fixture(files \\ %{}) do
    path = unique_repo_path()
    {_output, 0} = System.cmd("git", ["init"], cd: path, stderr_to_stdout: true)
    {_output, 0} = System.cmd("git", ["config", "user.email", "afp@example.test"], cd: path)
    {_output, 0} = System.cmd("git", ["config", "user.name", "AFP Test"], cd: path)

    files
    |> Enum.each(fn {file, content} ->
      full_path = Path.join(path, file)
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, content)
    end)

    {_output, 0} = System.cmd("git", ["add", "."], cd: path, stderr_to_stdout: true)
    {_output, 0} = System.cmd("git", ["commit", "-m", "Initial test commit"], cd: path)
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
end
