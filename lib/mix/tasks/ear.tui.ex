defmodule Mix.Tasks.Ear.Tui do
  use Mix.Task

  @shortdoc "Start the full-screen TermUI terminal"
  @moduledoc """
  Starts the EAR full-screen terminal UI implemented with TermUI widgets.

      mix ear.tui [--workspace DIR] [--endpoint URL] [--model NAME]
                  [--skill-root PATH] [--no-ansi] [--verbose]
  """

  @impl true
  def run(args) do
    if "--help" in args or "-h" in args do
      Mix.shell().info(@moduledoc)
    else
      {opts, positional, invalid} =
        OptionParser.parse(args,
          strict: [
            workspace: :string,
            endpoint: :string,
            model: :string,
            skill_root: :keep,
            no_ansi: :boolean,
            verbose: :boolean
          ]
        )

      if positional != [] or invalid != [],
        do: Mix.raise("Invalid options: #{inspect(positional ++ invalid)}")

      Mix.Task.run("app.start")
      roots = Keyword.get_values(opts, :skill_root)
      opts = opts |> Keyword.delete(:skill_root) |> maybe_put_roots(roots)
      opts = Keyword.put(opts, :fullscreen, true) |> maybe_no_ansi()

      case Ear.TUI.start(opts) do
        {:error, reason} -> Mix.raise("Unable to start ear TUI: #{inspect(reason)}")
        result -> result
      end
    end
  end

  defp maybe_put_roots(opts, []), do: opts
  defp maybe_put_roots(opts, roots), do: Keyword.put(opts, :skill_roots, roots)

  defp maybe_no_ansi(opts),
    do: if(Keyword.get(opts, :no_ansi), do: Keyword.put(opts, :ansi, false), else: opts)
end
