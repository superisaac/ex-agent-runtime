defmodule Ear.TUI do
  alias Ear.TUI.{Command, Session}

  @doc "Returns the read-only project inspection tools enabled for TUI runs."
  def default_tool_modules, do: [Ear.Tools.FileList, Ear.Tools.FileRead]

  @doc "Returns the workspace used by a TUI invocation, defaulting to the current directory."
  def workspace(opts \\ []), do: Path.expand(Keyword.get(opts, :workspace, File.cwd!()))

  def start(opts \\ []) do
    with {:ok, opts} <- Ear.Config.User.prepare_tui(opts) do
      opts =
        opts
        |> Keyword.put(:workspace, workspace(opts))
        |> Keyword.put_new(:tool_modules, default_tool_modules())
        |> Keyword.put_new(
          :renderer,
          if(Keyword.get(opts, :verbose, false),
            do: Ear.TUI.Renderer,
            else: Ear.TUI.QuietRenderer
          )
        )

      if Keyword.get(opts, :fullscreen, false) do
        Ear.TUI.Fullscreen.start(Keyword.put(opts, :config, false))
      else
        start_line_oriented(opts)
      end
    end
  end

  defp start_line_oriented(opts) do
    owner = self()
    renderer = Keyword.get(opts, :renderer, Ear.TUI.Renderer)
    input = Keyword.get(opts, :input, &IO.gets/1)
    ansi = Keyword.get(opts, :ansi, true)
    readline? = not Keyword.has_key?(opts, :input)
    readline_state = if readline?, do: Ear.TUI.Readline.new(), else: nil
    io_options = if readline?, do: enable_readline(), else: nil
    {event_pid, event_ref} = spawn_monitor(fn -> event_loop(owner, renderer) end)

    try do
      {skills, skill_errors} =
        Ear.Skills.Loader.discover_report(Keyword.get(opts, :skill_roots, []))

      session_opts =
        opts
        |> Keyword.take([:auth_adapter, :renderer])
        |> Keyword.put(:skills, skills)
        |> Keyword.put(:skill_errors, skill_errors)
        |> Keyword.put(:subscriber, event_pid)
        |> Keyword.put(:run_opts, opts)

      loop(Session.new(session_opts), input, ansi, readline_state)
    after
      send(event_pid, :stop)

      receive do
        {:DOWN, ^event_ref, :process, ^event_pid, _} -> :ok
      after
        1000 ->
          Process.exit(event_pid, :kill)
          Process.demonitor(event_ref, [:flush])
      end

      restore_readline(io_options)
    end
  end

  defp enable_readline do
    saved = :io.getopts(:standard_io)

    case System.cmd("stty", ["-g"], stderr_to_stdout: true) do
      {tty_state, 0} ->
        case System.cmd("stty", ["-icanon", "min", "1", "-echo"], stderr_to_stdout: true) do
          {_output, 0} ->
            :io.setopts(:standard_io, terminal: true, line_history: true)
            {:tty, String.trim(tty_state), saved}

          _ ->
            nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp restore_readline(nil), do: :ok

  defp restore_readline({:tty, tty_state, saved}) do
    System.cmd("stty", [tty_state], stderr_to_stdout: true)
    :io.setopts(:standard_io, saved)
  rescue
    _ -> :ok
  end

  defp loop(%Session{running: false}, _input, _ansi, _readline), do: :ok

  defp loop(session, input, ansi, readline) do
    {result, readline} =
      if is_struct(readline, Ear.TUI.Readline) do
        Ear.TUI.Readline.gets(readline)
      else
        {input.("ear> "), readline}
      end

    case result do
      :eof ->
        Session.handle(session, {:command, "exit", ""})
        await_shutdown(session.run_id)
        :ok

      {:error, reason} ->
        Session.handle(session, {:command, "exit", ""})
        await_shutdown(session.run_id)
        {:error, reason}

      line ->
        {session, result} = Session.handle(session, Command.parse(line))
        display(result, ansi)

        if session.running,
          do: loop(session, input, ansi, readline),
          else: await_shutdown(session.run_id)
    end
  end

  defp display({:message, message}, _ansi), do: IO.puts(message)
  defp display({:error, reason}, _ansi), do: IO.puts("Error: #{inspect(reason)}")

  defp display({:help, commands}, _ansi),
    do:
      commands
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.each(fn {name, description} -> IO.puts("/#{name} - #{description}") end)

  defp display({:skills, skills, errors}, _ansi) do
    Enum.each(skills, fn skill -> IO.puts("#{skill.name} - #{skill.path}") end)
    if errors != [], do: IO.puts("Skill warnings: #{length(errors)}")
  end

  defp display({:status, :idle}, _ansi), do: IO.puts("Idle")
  defp display({:status, status}, _ansi), do: IO.puts("Status: #{inspect(status)}")

  defp display({:runs, runs}, _ansi) do
    Enum.each(runs, fn run ->
      IO.puts("#{run.run_id} #{run.status} turns=#{run.turns} tools=#{run.tool_calls}")
    end)
  end

  defp display({:history, messages}, _ansi) do
    Enum.each(messages, fn message ->
      IO.puts("#{message.role}: #{message.content}")
    end)
  end

  defp display(:clear, true), do: IO.write("\e[2J\e[H")
  defp display(:clear, false), do: IO.puts("--- screen cleared ---")

  defp display(_, _ansi), do: :ok

  defp event_loop(owner, renderer) do
    owner_ref = Process.monitor(owner)
    receive_events(owner_ref, renderer)
  end

  defp receive_events(owner_ref, renderer) do
    receive do
      {:ear, event} ->
        if is_function(renderer, 1), do: renderer.(event), else: renderer.render(event)
        receive_events(owner_ref, renderer)

      :stop ->
        :ok

      {:DOWN, ^owner_ref, :process, _pid, _reason} ->
        :ok
    end
  end

  defp await_shutdown(nil), do: :ok

  defp await_shutdown(run_id),
    do: await_shutdown(run_id, System.monotonic_time(:millisecond) + 1_000)

  defp await_shutdown(run_id, deadline) do
    done? =
      case Ear.get_run(run_id) do
        {:ok, %{status: status}} when status in [:completed, :failed, :cancelled] -> true
        _ -> false
      end

    cond do
      done? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      true ->
        Process.sleep(10)
        await_shutdown(run_id, deadline)
    end
  end
end
