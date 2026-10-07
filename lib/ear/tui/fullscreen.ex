defmodule Ear.TUI.Fullscreen do
  @moduledoc """
  Stateful full-screen terminal presentation and key handling.

  The state and key functions are pure so applications can embed the editor in
  another terminal driver or test it without opening a real terminal.
  """

  defstruct lines: [],
            input: "",
            key_buffer: "",
            cursor: 0,
            scroll: 0,
            width: 80,
            height: 24,
            status: "Ready",
            ansi: true,
            transcript_limit: 200

  @type t :: %__MODULE__{}

  alias Ear.TUI.{Session, Command}

  def start(opts \\ []) do
    owner = self()
    ansi = Keyword.get(opts, :ansi, true)
    key_input = Keyword.get(opts, :key_input, fn -> IO.getn("", 1) end)
    event_pid = spawn(fn -> event_loop(owner) end)

    input_pid =
      spawn(fn ->
        receive do
          :read -> input_loop(owner, key_input)
        end
      end)

    saved_opts = :io.getopts()
    tty_state = terminal_setup(ansi)

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

      session = Session.new(session_opts)
      state = new(Keyword.take(opts, [:width, :height, :transcript_limit]) ++ [ansi: ansi])
      send(input_pid, :read)
      render(state)
      loop(session, state)
    after
      send(event_pid, :stop)
      Process.exit(input_pid, :kill)
      if is_list(saved_opts), do: :io.setopts(saved_opts)
      terminal_restore(ansi, tty_state)
    end
  end

  defp loop(%Session{running: false} = session, _state) do
    await_shutdown(session.run_id, System.monotonic_time(:millisecond) + 1_000)
  end

  defp loop(session, state) do
    receive do
      {:fullscreen_event, event} ->
        state = handle_event(state, event)
        render(state)
        loop(session, state)

      {:fullscreen_key, key} when key == :eof ->
        {session, _} = Session.handle(session, {:command, "exit", ""})
        loop(session, state)

      {:fullscreen_key, {:error, _reason}} ->
        {session, _} = Session.handle(session, {:command, "exit", ""})
        loop(session, state)

      {:fullscreen_key, key} when is_atom(key) ->
        {session, state} = handle_input(session, state, key)
        render(state)
        loop(session, state)

      {:fullscreen_key, key} ->
        {keys, buffer} = decode_keys(state.key_buffer <> key)

        {session, state} =
          Enum.reduce(keys, {session, %{state | key_buffer: buffer}}, fn key, {session, state} ->
            handle_input(session, state, key)
          end)

        render(state)
        loop(session, state)
    after
      100 ->
        resized = resize(state)
        if resized != state, do: render(resized)
        loop(session, resized)
    end
  end

  defp handle_input(session, state, key) do
    case handle_key(state, normalize_key(key)) do
      {state, {:submit, prompt}} ->
        {session, result} = Session.handle(session, Command.parse(prompt))

        state =
          if String.starts_with?(prompt, "/"),
            do: state,
            else: append_text(state, "\nYou: " <> prompt <> "\nAssistant: ")

        {session, display_result(state, result)}

      {state, :cancel} ->
        command =
          if state.status in ["Running"] or String.starts_with?(state.status, "Tool:"),
            do: {:command, "cancel", ""},
            else: {:command, "exit", ""}

        {session, _result} = Session.handle(session, command)
        {session, state}

      {state, _action} ->
        {session, state}
    end
  end

  defp event_loop(owner) do
    receive do
      {:ear, event} ->
        send(owner, {:fullscreen_event, event})
        event_loop(owner)

      :stop ->
        :ok
    end
  end

  defp input_loop(owner, input) do
    receive do
      :stop -> :ok
    after
      0 ->
        key = input.()
        send(owner, {:fullscreen_key, key})
        if key != :eof and not match?({:error, _}, key), do: input_loop(owner, input)
    end
  end

  @sequences ["\e[A", "\e[B", "\e[C", "\e[D", "\e[5~", "\e[6~", "\e[3~", "\e[H", "\e[F"]
  def decode_keys(data), do: decode_keys(data, [])
  defp decode_keys("", keys), do: {Enum.reverse(keys), ""}

  defp decode_keys(data, keys) do
    sequence = Enum.find(@sequences, &String.starts_with?(data, &1))

    cond do
      sequence ->
        decode_keys(
          binary_part(data, byte_size(sequence), byte_size(data) - byte_size(sequence)),
          [parse_key(sequence) | keys]
        )

      Enum.any?(@sequences, &String.starts_with?(&1, data)) ->
        {Enum.reverse(keys), data}

      true ->
        {key, rest} = String.next_grapheme(data)
        decode_keys(rest, [parse_key(key) | keys])
    end
  end

  defp normalize_key(:eof), do: :ctrl_c
  defp normalize_key({:error, _}), do: :ctrl_c
  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: parse_key(key)
  defp normalize_key(_), do: :escape

  defp render(state), do: IO.write(render_frame(state))

  defp terminal_setup(true) do
    {saved, _status} = System.cmd("stty", ["-g"], stderr_to_stdout: true)
    System.cmd("stty", ["-icanon", "min", "1", "-echo"], stderr_to_stdout: true)
    IO.write("\e[?1049h\e[?25l")
    :io.setopts(:standard_io, binary: true, echo: false)
    String.trim(saved)
  end

  defp terminal_setup(false), do: nil

  defp terminal_restore(true, tty_state) do
    if is_binary(tty_state), do: System.cmd("stty", [tty_state], stderr_to_stdout: true)
    IO.write("\e[?25h\e[?1049l")
  rescue
    _ -> :ok
  end

  defp terminal_restore(false, _tty_state), do: :ok

  defp await_shutdown(nil, _deadline), do: :ok

  defp await_shutdown(run_id, deadline) do
    case Ear.get_run(run_id) do
      {:ok, %{status: status}} when status in [:completed, :failed, :cancelled] ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          await_shutdown(run_id, deadline)
        else
          :ok
        end
    end
  end

  defp resize(state) do
    with {:ok, width} <- :io.columns(), {:ok, height} <- :io.rows() do
      %{state | width: max(width, 10), height: max(height, 4)}
    else
      _ -> state
    end
  end

  defp display_result(state, :clear), do: %{state | lines: [], scroll: 0}
  defp display_result(state, {:message, text}), do: append_text(state, "\n" <> text <> "\n")

  defp display_result(state, {:error, error}),
    do: append_text(state, "\nError: #{inspect(error)}\n")

  defp display_result(state, {:help, commands}) do
    append_text(
      state,
      "\n" <>
        Enum.map_join(Enum.sort(commands), "\n", fn {name, description} ->
          "/#{name} - #{description}"
        end) <> "\n"
    )
  end

  defp display_result(state, :ok), do: state
  defp display_result(state, :exit), do: state
  defp display_result(state, result), do: append_text(state, "\n#{inspect(result)}\n")

  def new(opts \\ []) do
    %__MODULE__{
      width: Keyword.get(opts, :width, 80),
      height: Keyword.get(opts, :height, 24),
      ansi: Keyword.get(opts, :ansi, true),
      transcript_limit: Keyword.get(opts, :transcript_limit, 200)
    }
  end

  def handle_key(%__MODULE__{} = state, :enter), do: submit(state)
  def handle_key(%__MODULE__{} = state, :ctrl_c), do: {state, :cancel}
  def handle_key(%__MODULE__{} = state, :ctrl_l), do: {state, :redraw}

  def handle_key(%__MODULE__{} = state, :page_up),
    do: {%{state | scroll: state.scroll + page(state)}, :none}

  def handle_key(%__MODULE__{} = state, :page_down),
    do: {%{state | scroll: max(state.scroll - page(state), 0)}, :none}

  def handle_key(%__MODULE__{} = state, :up), do: {%{state | scroll: state.scroll + 1}, :none}

  def handle_key(%__MODULE__{} = state, :down),
    do: {%{state | scroll: max(state.scroll - 1, 0)}, :none}

  def handle_key(%__MODULE__{} = state, :backspace), do: delete_before_cursor(state)
  def handle_key(%__MODULE__{} = state, :delete), do: delete_at_cursor(state)

  def handle_key(%__MODULE__{} = state, :left),
    do: {%{state | cursor: max(state.cursor - 1, 0)}, :none}

  def handle_key(%__MODULE__{} = state, :right),
    do: {%{state | cursor: min(state.cursor + 1, String.length(state.input))}, :none}

  def handle_key(state, :home), do: {%{state | cursor: 0}, :none}
  def handle_key(state, :end), do: {%{state | cursor: String.length(state.input)}, :none}

  def handle_key(%__MODULE__{} = state, :escape), do: {state, :none}

  def handle_key(%__MODULE__{} = state, key) when is_binary(key) do
    chars = String.graphemes(key)

    input =
      String.slice(state.input, 0, state.cursor) <>
        key <> String.slice(state.input, state.cursor, String.length(state.input))

    {%{state | input: input, cursor: state.cursor + length(chars)}, :none}
  end

  def handle_key(state, _key), do: {state, :none}

  def handle_event(%__MODULE__{} = state, %{type: :message_delta, payload: %{text: text}})
      when is_binary(text), do: append_text(state, text)

  def handle_event(%__MODULE__{} = state, %{type: :run_started}), do: %{state | status: "Running"}

  def handle_event(%__MODULE__{} = state, %{type: :tool_call_started, payload: %{name: name}}),
    do: %{state | status: "Tool: #{name}"}

  def handle_event(%__MODULE__{} = state, %{type: :tool_call_completed}),
    do: %{state | status: "Running"}

  def handle_event(%__MODULE__{} = state, %{type: :run_completed}), do: %{state | status: "Ready"}

  def handle_event(%__MODULE__{} = state, %{type: :run_cancelled}),
    do: %{state | status: "Cancelled"}

  def handle_event(%__MODULE__{} = state, %{type: :run_failed, payload: %{reason: reason}}),
    do: %{state | status: "Failed: #{inspect(reason)}"}

  def handle_event(state, _event), do: state

  def render_frame(%__MODULE__{} = state) do
    visible_height = max(state.height - 2, 1)
    width = max(state.width, 10)

    wrapped =
      Enum.flat_map(state.lines, fn line ->
        case String.graphemes(sanitize(line)) do
          [] -> [""]
          chars -> chars |> Enum.chunk_every(width) |> Enum.map(&Enum.join/1)
        end
      end)

    scroll = min(state.scroll, max(length(wrapped) - visible_height, 0))

    lines =
      wrapped
      |> Enum.reverse()
      |> Enum.drop(scroll)
      |> Enum.take(visible_height)
      |> Enum.reverse()

    body = Enum.join(lines ++ List.duplicate("", visible_height - length(lines)), "\r\n")
    start = max(state.cursor - width + 4, 0)
    prompt = "❯ " <> String.slice(sanitize(state.input), start, width - 3)

    status =
      String.slice(
        "[#{state.status}]  Enter: send | Ctrl-C: cancel/exit | PgUp/PgDn: scroll",
        0,
        width - 1
      )

    frame = body <> "\r\n" <> prompt <> "\r\n" <> status

    if state.ansi do
      "\e[?25l\e[2J\e[H" <>
        frame <> "\e[#{visible_height + 1};#{state.cursor - start + 3}H\e[?25h"
    else
      frame
    end
  end

  defp sanitize(text), do: Regex.replace(~r/[\x00-\x08\x0B-\x1F\x7F]/u, text, "")

  def parse_key("\e[H"), do: :home
  def parse_key("\e[F"), do: :end
  def parse_key(<<27, "[A">>), do: :up
  def parse_key(<<27, "[B">>), do: :down
  def parse_key(<<27, "[C">>), do: :right
  def parse_key(<<27, "[D">>), do: :left
  def parse_key(<<27, "[5~">>), do: :page_up
  def parse_key(<<27, "[6~">>), do: :page_down
  def parse_key(<<3>>), do: :ctrl_c
  def parse_key(<<12>>), do: :ctrl_l
  def parse_key(<<13>>), do: :enter
  def parse_key(<<10>>), do: :enter
  def parse_key(<<27, "[3~">>), do: :delete
  def parse_key(<<127>>), do: :backspace
  def parse_key(<<27>>), do: :escape
  def parse_key(key) when is_binary(key), do: key

  defp submit(%{input: ""} = state), do: {state, :none}
  defp submit(state), do: {%{state | input: "", cursor: 0}, {:submit, state.input}}

  defp delete_before_cursor(%{cursor: 0} = state), do: {state, :none}
  defp delete_before_cursor(state), do: {delete_range(state, state.cursor - 1, 1), :none}
  defp delete_at_cursor(state), do: {delete_range(state, state.cursor, 1), :none}

  defp delete_range(state, index, count) do
    input =
      String.slice(state.input, 0, index) <>
        String.slice(state.input, index + count, String.length(state.input))

    %{state | input: input, cursor: min(index, String.length(input))}
  end

  defp append_text(state, text) do
    {prefix, tail} =
      case Enum.split(state.lines, -1) do
        {prefix, [tail]} -> {prefix, tail}
        _ -> {[], ""}
      end

    lines = prefix ++ String.split(tail <> text, "\n", trim: false)
    %{state | lines: Enum.take(lines, -state.transcript_limit), scroll: 0}
  end

  defp page(state), do: max(state.height - 3, 1)
end
