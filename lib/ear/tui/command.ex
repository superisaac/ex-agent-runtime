defmodule Ear.TUI.Command do
  @commands %{
    "help" => "Show available commands",
    "login" => "Authenticate a provider",
    "exit" => "Exit the session",
    "quit" => "Exit the session",
    "clear" => "Clear the transcript",
    "cancel" => "Cancel the active run",
    "skills" => "List loaded skills",
    "reload-skills" => "Reload skills from configured roots",
    "status" => "Show the active run status",
    "history" => "Show the latest conversation history",
    "runs" => "List stored runs",
    "clear-runs" => "Clear stored run snapshots"
  }
  def parse(line) when is_binary(line) do
    case String.trim(line) do
      "/" <> command ->
        case String.split(command, ~r/\s+/, parts: 2) do
          [name] -> {:command, String.downcase(name), ""}
          [name, args] -> {:command, String.downcase(name), args}
        end

      prompt ->
        {:prompt, prompt}
    end
  end

  def parse(_line), do: {:error, :invalid_input}

  def known?(name), do: Map.has_key?(@commands, name)
  def help, do: @commands
end
