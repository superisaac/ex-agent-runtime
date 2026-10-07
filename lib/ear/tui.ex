defmodule Ear.TUI do
  alias Ear.TUI.{Command, Session}

  def start(opts \\ []) do
    if Keyword.get(opts, :fullscreen, false) do
      Ear.TUI.Fullscreen.start(opts)
    else
      start_line_oriented(opts)
    end
  end

  defp start_line_oriented(opts) do
    owner = self()
    renderer = Keyword.get(opts, :renderer, Ear.TUI.Renderer)
    input = Keyword.get(opts, :input, &IO.gets/1)
    ansi = Keyword.get(opts, :ansi, true)
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

      loop(Session.new(session_opts), input, ansi)
    after
      send(event_pid, :stop)

      receive do
        {:DOWN, ^event_ref, :process, ^event_pid, _} -> :ok
      after
        1000 ->
          Process.exit(event_pid, :kill)
          Process.demonitor(event_ref, [:flush])
      end
    end
  end

  defp loop(%Session{running: false}, _input, _ansi), do: :ok

  defp loop(session, input, ansi) do
    case input.("ear> ") do
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

        if session.running, do: loop(session, input, ansi), else: await_shutdown(session.run_id)
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
