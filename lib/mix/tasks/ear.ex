defmodule Mix.Tasks.Ear do
  @shortdoc "Start the ear terminal UI"
  @moduledoc "Starts the interactive ear TUI."
  use Mix.Task

  @impl true
  def run(args) do
    if "--help" in args or "-h" in args do
      Mix.shell().info(
        "Usage: mix ear [options]\n\n" <>
          "Starts the interactive ear terminal UI.\n\n" <>
          "Options:\n  --endpoint URL\n  --model NAME\n  --skill-root PATH (repeatable)\n  --no-ansi\n  --fullscreen\n  -h, --help"
      )

      :ok
    else
      case OptionParser.parse(args,
             strict: [
               endpoint: :string,
               model: :string,
               skill_root: :keep,
               no_ansi: :boolean,
               fullscreen: :boolean
             ]
           ) do
        {opts, [], []} -> start_ui(opts)
        {_opts, invalid, _} -> Mix.raise("Invalid options: #{inspect(invalid)}")
      end
    end
  end

  defp start_ui(cli_opts) do
    Mix.Task.run("app.start")

    adapter_opts =
      []
      |> maybe_put(:endpoint, cli_opts[:endpoint])
      |> maybe_put(:model, cli_opts[:model])

    opts = adapter_opts

    opts = if cli_opts[:no_ansi], do: [{:ansi, false} | opts], else: opts
    opts = if cli_opts[:fullscreen], do: [{:fullscreen, true} | opts], else: opts

    opts =
      if cli_opts[:skill_root], do: [{:skill_roots, cli_opts[:skill_root]} | opts], else: opts

    case Ear.TUI.start(opts) do
      {:error, reason} -> Mix.raise("Unable to start ear: #{inspect(reason)}")
      result -> result
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
