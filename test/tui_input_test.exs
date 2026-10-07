defmodule Ear.TUIInputTest do
  use ExUnit.Case, async: false

  test "injected input does not alter terminal readline options" do
    before = :io.getopts(:standard_io)

    assert :ok =
             Ear.TUI.start(
               config: false,
               input: fn _ -> :eof end,
               renderer: fn _ -> :ok end
             )

    assert :io.getopts(:standard_io) == before
  end

  test "Erlang terminal options support line history" do
    options = :io.getopts(:standard_io)
    assert Keyword.has_key?(options, :line_history)
    assert Keyword.has_key?(options, :terminal)
  end
end
