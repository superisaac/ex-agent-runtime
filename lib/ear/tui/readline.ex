defmodule Ear.TUI.Readline do
  @moduledoc "Small readline-style editor used by the line-oriented TUI."

  defstruct history: [], index: nil

  def new, do: %__MODULE__{}

  def gets(%__MODULE__{} = state, prompt \\ "ear> ") do
    IO.write(prompt)
    read(%{state | index: nil}, prompt, [], 0)
  end

  defp read(state, prompt, chars, cursor) do
    case IO.getn("", 1) do
      :eof -> {:eof, state}
      {:error, reason} -> {{:error, reason}, state}
      key -> handle_key(state, prompt, chars, cursor, key)
    end
  end

  defp handle_key(state, _prompt, chars, _cursor, "\r"), do: submit(state, chars)
  defp handle_key(state, _prompt, chars, _cursor, "\n"), do: submit(state, chars)
  defp handle_key(state, _prompt, _chars, _cursor, <<3>>), do: {{:error, :interrupted}, state}

  defp handle_key(state, prompt, chars, cursor, <<1>>),
    do: redraw(state, prompt, chars, 0, cursor)

  defp handle_key(state, prompt, chars, cursor, <<5>>),
    do: redraw(state, prompt, chars, length(chars), cursor)

  defp handle_key(state, prompt, chars, cursor, <<11>>),
    do: redraw(state, prompt, Enum.take(chars, cursor), cursor, cursor)

  defp handle_key(state, prompt, _chars, _cursor, <<21>>), do: redraw(state, prompt, [], 0, 0)

  defp handle_key(state, prompt, chars, cursor, <<127>>),
    do: backspace(state, prompt, chars, cursor)

  defp handle_key(state, prompt, chars, cursor, <<8>>),
    do: backspace(state, prompt, chars, cursor)

  defp handle_key(state, prompt, chars, cursor, "\e") do
    case IO.getn("", 2) do
      "[D" -> redraw(state, prompt, chars, max(cursor - 1, 0), cursor)
      "[C" -> redraw(state, prompt, chars, min(cursor + 1, length(chars)), cursor)
      "[A" -> history(state, prompt, chars, cursor, :up)
      "[B" -> history(state, prompt, chars, cursor, :down)
      _ -> read(state, prompt, chars, cursor)
    end
  end

  defp handle_key(state, prompt, chars, cursor, key) do
    case String.next_grapheme(key) do
      {grapheme, ""} ->
        next = List.insert_at(chars, cursor, grapheme)
        redraw(state, prompt, next, cursor + 1, cursor)

      _ ->
        read(state, prompt, chars, cursor)
    end
  end

  defp backspace(state, prompt, chars, cursor) when cursor > 0 do
    next = List.delete_at(chars, cursor - 1)
    redraw(state, prompt, next, cursor - 1, cursor)
  end

  defp backspace(state, prompt, chars, cursor), do: read(state, prompt, chars, cursor)

  defp redraw(state, prompt, chars, cursor, old_cursor) do
    IO.write(
      "\r\e[2K" <> prompt <> IO.iodata_to_binary(chars) <> cursor_back(length(chars) - cursor)
    )

    if cursor == old_cursor, do: :ok
    read(state, prompt, chars, cursor)
  end

  defp cursor_back(0), do: ""
  defp cursor_back(count), do: "\e[#{count}D"

  defp submit(state, chars) do
    line = IO.iodata_to_binary(chars)
    IO.write("\r\e[2K" <> "ear> " <> line <> "\n")

    history =
      if String.trim(line) == "",
        do: state.history,
        else: [line | state.history] |> Enum.uniq() |> Enum.take(100)

    {line, %{state | history: history, index: nil}}
  end

  defp history(%{history: []} = state, prompt, chars, cursor, _direction),
    do: read(state, prompt, chars, cursor)

  defp history(state, prompt, _chars, cursor, direction) do
    index =
      case {state.index, direction} do
        {nil, :up} -> 0
        {nil, :down} -> length(state.history) - 1
        {current, :up} -> min(current + 1, length(state.history) - 1)
        {current, :down} -> max(current - 1, 0)
      end

    value = Enum.at(state.history, index, "") |> String.graphemes()
    redraw(%{state | index: index}, prompt, value, length(value), cursor)
  end
end
