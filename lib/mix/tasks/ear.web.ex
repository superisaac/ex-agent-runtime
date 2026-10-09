defmodule Mix.Tasks.Ear.Web do
  use Mix.Task
  @shortdoc "Start the local Phoenix web UI"
  @moduledoc """
  Starts the Phoenix web UI at http://localhost:9000.

      mix ear.web [--workspace DIR] [--endpoint URL] [--model NAME]
                  [--skill-root PATH] [--port PORT] [--model-timeout MS]
                  [--verbose]

  Skill roots may be repeated. Uses the same user configuration as `mix ear.tui`.
  Model timeout defaults to 120000 ms; for streaming, it limits inactivity.
  Debug logs are hidden by default; pass --verbose to show them.
  """

  @impl true
  def run(args) do
    if "--help" in args or "-h" in args do
      Mix.shell().info(@moduledoc)
    else
      case OptionParser.parse(args,
             strict: [
               workspace: :string,
               endpoint: :string,
               model: :string,
               skill_root: :keep,
               port: :integer,
               model_timeout: :integer,
               verbose: :boolean
             ]
           ) do
        {opts, [], []} ->
          Logger.configure(level: if(Keyword.get(opts, :verbose, false), do: :debug, else: :info))
          port = Keyword.get(opts, :port, 9000)
          if port < 1 or port > 65_535, do: Mix.raise("Port must be between 1 and 65535")

          if opts[:model_timeout] && opts[:model_timeout] <= 0,
            do: Mix.raise("Model timeout must be a positive number of milliseconds")

          Mix.Task.run("app.start")
          roots = Keyword.get_values(opts, :skill_root)
          opts = Keyword.delete(opts, :skill_root)
          opts = if roots == [], do: opts, else: Keyword.put(opts, :skill_roots, roots)

          case Ear.Web.start_link(opts) do
            {:ok, _pid} ->
              Mix.shell().info("EAR web UI: http://localhost:#{port}")
              Process.sleep(:infinity)

            {:error, reason} ->
              Mix.raise("Unable to start EAR web UI: #{inspect(reason)}")
          end

        {_opts, positional, invalid} ->
          Mix.raise("Invalid options: #{inspect(positional ++ invalid)}")
      end
    end
  end
end
