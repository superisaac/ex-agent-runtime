defmodule Ear.TUI.TermUIApp do
  use TermUI.Elm

  alias Ear.TUI.{Command, Session}

  defstruct session: nil,
            lines: [],
            input: nil,
            dimensions: {80, 24},
            status: "Ready",
            verbose: false,
            transcript_limit: 200

  def init(opts) do
    dimensions = Keyword.get(opts, :dimensions, {80, 24})
    app_opts = Keyword.get(opts, :ear_runtime_opts, [])
    session_opts = Keyword.put(Keyword.get(app_opts, :session_opts, []), :subscriber, self())

    %__MODULE__{
      session: Session.new(session_opts),
      input: new_input(),
      dimensions: dimensions,
      verbose: Keyword.get(app_opts, :verbose, false),
      transcript_limit: Keyword.get(app_opts, :transcript_limit, 200)
    }
  end

  def event_to_msg(%TermUI.Event.Key{key: key, modifiers: modifiers}, _),
    do: {:msg, {:key, key, modifiers}}

  def event_to_msg(%TermUI.Event.Text{text: text}, _), do: {:msg, {:text, text}}
  def event_to_msg(%TermUI.Event.Paste{content: text}, _), do: {:msg, {:text, text}}

  def event_to_msg(%TermUI.Event.Resize{width: width, height: height}, _),
    do: {:msg, {:resize, width, height}}

  def event_to_msg(_, _), do: :ignore

  def handle_info({:ear, event}, state), do: apply_event(state, event)
  def handle_info(_, _state), do: :noreply

  def update({:text, text}, state), do: update_input(state, TermUI.Event.text(text))

  def update({:key, :ctrl_c, _modifiers}, state), do: cancel_or_exit(state)

  def update({:key, key, modifiers}, state)
      when key in ["c", :c] and (modifiers == [:ctrl] or modifiers == [:control]),
      do: cancel_or_exit(state)

  def update({:key, key, modifiers}, state),
    do: update_input(state, TermUI.Event.key(key, modifiers: modifiers))

  def update({:key, key}, state), do: update_input(state, TermUI.Event.key(key))
  def update({:resize, width, height}, state), do: %{state | dimensions: {width, height}}
  def update(_, state), do: state

  defp cancel_or_exit(%{session: %{run_id: nil}} = state) do
    {%{state | session: %{state.session | running: false}}, [TermUI.Command.shutdown()]}
  end

  defp cancel_or_exit(state) do
    {session, _result} = Session.handle(state.session, {:command, "cancel", ""})
    {%{state | session: session, status: "Cancelled"}, []}
  end

  defp update_input(state, event) do
    {input, messages} = TermUI.Widget.TextInput.update(event, state.input)
    state = %{state | input: input}

    Enum.reduce(messages, {state, []}, fn
      {:submit, prompt}, {_state, _commands} -> submit(state, prompt)
      _, {state, commands} -> {state, commands}
    end)
  end

  defp submit(state, ""), do: {state, []}

  defp submit(state, prompt) do
    {session, result} = Session.handle(state.session, Command.parse(prompt))
    state = %{state | session: session, input: new_input()}

    if session.running,
      do:
        {state
         |> append("You: #{prompt}")
         |> append_stream("\nAssistant: ")
         |> apply_result(result), []},
      else: {state, [TermUI.Command.shutdown()]}
  end

  def view(%__MODULE__{dimensions: {width, height}} = state) do
    width = max(width, 1)
    height = max(height, 1)
    visible = max(height - 2, 1)
    body = Enum.flat_map(state.lines, &wrap(&1, width)) |> Enum.take(-visible)
    body = body ++ List.duplicate("", max(visible - length(body), 0))
    {input_row, cursor_column} = TermUI.Widget.TextInput.row(state.input, max(width - 2, 1))

    TermUI.Frame.from_rows(body ++ ["❯ " <> input_row], width, height,
      cursor: {min(cursor_column + 2, width), min(length(body) + 1, height)}
    )
  end

  defp apply_result(state, :clear), do: %{state | lines: []}
  defp apply_result(state, {:message, text}), do: append(state, text)
  defp apply_result(state, {:error, error}), do: append(state, "Error: #{inspect(error)}")

  defp apply_result(state, {:help, commands}),
    do:
      append(
        state,
        Enum.map_join(Enum.sort(commands), "\n", fn {name, description} ->
          "/#{name} - #{description}"
        end)
      )

  defp apply_result(state, {:skills, skills, errors}),
    do:
      append(
        state,
        Enum.map_join(skills, "\n", &"#{&1.name} - #{&1.path}") <>
          if(errors == [], do: "", else: "\nSkill warnings: #{length(errors)}")
      )

  defp apply_result(state, _), do: state

  defp apply_event(state, %{type: :message_delta, payload: %{text: text}}),
    do: append_stream(state, text)

  defp apply_event(state, %{type: :run_started}), do: %{state | status: "Running"}
  defp apply_event(state, %{type: :run_completed}), do: %{state | status: "Ready"}
  defp apply_event(state, %{type: :run_cancelled}), do: %{state | status: "Cancelled"}

  defp apply_event(state, %{type: :run_failed, payload: %{reason: reason}}),
    do: %{state | status: "Failed: #{inspect(reason)}"}

  defp apply_event(state, _), do: state

  defp append(state, text),
    do: %{
      state
      | lines: Enum.take(state.lines ++ String.split(text, "\n"), -state.transcript_limit)
    }

  defp append_stream(state, text) do
    {prefix, tail} =
      case Enum.split(state.lines, -1) do
        {prefix, [tail]} -> {prefix, tail}
        _ -> {[], ""}
      end

    lines = prefix ++ String.split(tail <> text, "\n", trim: false)
    %{state | lines: Enum.take(lines, -state.transcript_limit)}
  end

  defp wrap(text, width),
    do: text |> String.graphemes() |> Enum.chunk_every(max(width, 1)) |> Enum.map(&Enum.join/1)

  defp new_input, do: TermUI.Widget.TextInput.init(placeholder: "Type a prompt or /command")
end
