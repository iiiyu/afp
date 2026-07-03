# @input  - The golden template repo, a target path, and an opportunity's spec package
# @output - A fresh contract app repo: template export + spec/ + fresh state db + git init
# @pos    - The deterministic (non-agent) half of promoting an opportunity to an app
defmodule Afp.Factory.Builds.Scaffold do
  @moduledoc """
  Instantiates `afp-app-template` for one app. Deterministic by design: the
  template's committed tree is exported (`git archive`, so gitignored local
  noise never leaks), the opportunity's spec package lands in the manifest's
  `spec_dir`, the state db starts fresh, and the result is a new git repo
  with one initial commit. The agent-side identity work (tokens, bundle id,
  demo removal) stays with the repo's `scaffold-from-spec` skill.
  """

  alias Afp.Factory.Builds.Storage

  @manifest_path "afp/manifest.json"

  def create_app_repo(template_path, target_path, %{} = attrs) do
    template = Path.expand(template_path)
    target = Path.expand(target_path)

    with :ok <- check_template(template),
         :ok <- check_target(target),
         :ok <- export_template(template, target),
         {:ok, manifest} <- patch_manifest(target, attrs),
         :ok <- copy_spec_package(target, manifest, attrs[:spec_source]),
         :ok <- fresh_state_db(target, manifest),
         :ok <- git_init(target) do
      {:ok, %{path: target, manifest: manifest}}
    end
  end

  defp check_template(template) do
    if File.dir?(Path.join(template, ".git")) do
      :ok
    else
      {:error, {:template_not_a_git_repo, template}}
    end
  end

  defp check_target(target) do
    case File.ls(target) do
      {:ok, []} -> :ok
      {:ok, _entries} -> {:error, :target_not_empty}
      {:error, :enoent} -> File.mkdir_p(target)
      {:error, reason} -> {:error, {:target_unreadable, reason}}
    end
  end

  # git archive exports the committed tree only — DerivedData, App.xcodeproj,
  # and other gitignored noise in the local template checkout never leak.
  defp export_template(template, target) do
    case System.cmd(
           "sh",
           ["-c", "git -C #{sh_quote(template)} archive HEAD | tar -x -C #{sh_quote(target)}"],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, {:template_export_failed, String.trim(output)}}
    end
  end

  defp patch_manifest(target, attrs) do
    manifest_file = Path.join(target, @manifest_path)

    with {:ok, raw} <- File.read(manifest_file),
         {:ok, manifest} when is_map(manifest) <- Jason.decode(raw) do
      manifest = put_in(manifest, ["app", "display_name"], attrs.display_name)

      case File.write(manifest_file, Jason.encode!(manifest, pretty: true) <> "\n") do
        :ok -> {:ok, manifest}
        {:error, reason} -> {:error, {:manifest_write_failed, reason}}
      end
    else
      _error -> {:error, :template_manifest_invalid}
    end
  end

  defp copy_spec_package(_target, _manifest, nil), do: :ok

  defp copy_spec_package(target, manifest, spec_source) do
    spec_dir = Path.join(target, manifest["spec_dir"] || "spec")

    case File.cp_r(spec_source, spec_dir) do
      {:ok, _copied} -> :ok
      {:error, reason, file} -> {:error, {:spec_copy_failed, reason, file}}
    end
  end

  defp fresh_state_db(target, manifest) do
    db_path = Path.join(target, manifest["state_db"] || "afp/state.sqlite")
    File.rm(db_path)
    File.mkdir_p!(Path.dirname(db_path))
    Storage.ensure_schema(db_path)
  end

  defp git_init(target) do
    commands = [
      ["init", "-q"],
      ["add", "."],
      [
        "-c",
        "user.email=afp@local",
        "-c",
        "user.name=AFP",
        "commit",
        "-q",
        "-m",
        "Scaffold from afp-app-template with spec package"
      ]
    ]

    Enum.reduce_while(commands, :ok, fn args, :ok ->
      case System.cmd("git", args, cd: target, stderr_to_stdout: true) do
        {_output, 0} -> {:cont, :ok}
        {output, _status} -> {:halt, {:error, {:git_init_failed, String.trim(output)}}}
      end
    end)
  end

  defp sh_quote(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"
end
