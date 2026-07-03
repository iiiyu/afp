# @input  - Shell command strings and extra allowance patterns per launch
# @output - One command-safety vocabulary rendered per transport
# @pos    - The single source of the destructive/safe command policy both adapters consume
defmodule Afp.Factory.AgentClient.CommandPolicy do
  @moduledoc """
  The command-safety policy shared by both agent transports. Codex consumes
  it as approval predicates (`destructive?/1`, `safe_read?/1`); Claude Code
  consumes it rendered as CLI permission rules (`claude_allow_rules/1`,
  `claude_deny_rules/0`). One policy, two representations — change it here,
  it applies to both.
  """

  @safe_read_commands ~w(cat date find head ls pwd rg sed tail wc)

  # curl/mkdir support downloading real evidence screenshots into step
  # directories; destructive commands stay on the deny side.
  @claude_extra_allowed_commands ~w(sqlite3 curl mkdir)

  @destructive_commands ~w(rm sudo chmod chown open osascript)
  @destructive_git_subcommands ~w(checkout clean reset push)

  def safe_read_commands, do: @safe_read_commands

  @doc "True when the command matches a blocked destructive or out-of-band pattern."
  def destructive?(command) when is_binary(command) do
    normalized = " " <> String.trim(command) <> " "

    Enum.any?(@destructive_commands, &command_word?(normalized, &1)) or
      Enum.any?(@destructive_git_subcommands, &String.contains?(normalized, "git #{&1}"))
  end

  def destructive?(_command), do: false

  @doc "True when the command is a recognized read-only invocation (rtk prefix tolerated)."
  def safe_read?(command) when is_binary(command) do
    normalized = command |> String.trim() |> strip_rtk_prefix()
    first = normalized |> String.split(~r/\s+/, parts: 2) |> List.first()

    cond do
      first in @safe_read_commands and not writes?(normalized) -> true
      String.starts_with?(normalized, "git status") -> true
      String.starts_with?(normalized, "git diff") -> true
      String.starts_with?(normalized, "git log") -> true
      String.starts_with?(normalized, "sqlite3 -readonly") -> true
      true -> false
    end
  end

  def safe_read?(_command), do: false

  @doc "Claude CLI `Bash(...)` allow rules: policy commands plus per-launch extras."
  def claude_allow_rules(extra_command_allow \\ []) do
    policy_rules =
      Enum.map(@claude_extra_allowed_commands ++ @safe_read_commands, &"Bash(#{&1} *)")

    extra_rules = Enum.map(extra_command_allow || [], &"Bash(#{&1})")

    policy_rules ++ extra_rules
  end

  @doc "Claude CLI `Bash(...)` deny rules derived from the destructive vocabulary."
  def claude_deny_rules do
    Enum.map(@destructive_commands, &"Bash(#{&1} *)") ++
      Enum.map(@destructive_git_subcommands, &"Bash(git #{&1} *)")
  end

  defp command_word?(normalized, command) do
    String.contains?(normalized, " #{command} ") or
      String.contains?(normalized, " #{command}\t") or
      String.contains?(normalized, " #{command}\n") or
      String.contains?(normalized, " #{command} -") or
      Regex.match?(~r/\s#{Regex.escape(command)}(\s|$)/, normalized)
  end

  defp strip_rtk_prefix("rtk " <> rest), do: String.trim(rest)
  defp strip_rtk_prefix(command), do: command

  defp writes?(command) do
    String.contains?(command, ">") or
      String.contains?(command, " tee ") or
      String.contains?(command, " -i ")
  end
end
