defmodule Ear.TUI.ReadlineTest do
  use ExUnit.Case, async: true

  test "readline state starts with an empty history" do
    assert %Ear.TUI.Readline{history: [], index: nil} = Ear.TUI.Readline.new()
  end
end
