defmodule Ear.TUIVerbosityTest do
  use ExUnit.Case, async: true

  test "quiet is the default renderer" do
    assert Ear.TUI.start(config: false, input: fn _ -> :eof end) == :ok
  end

  test "fullscreen quiet mode does not show tool status" do
    state = Ear.TUI.Fullscreen.new()

    assert Ear.TUI.Fullscreen.handle_event(state, %{
             type: :tool_call_started,
             payload: %{name: "file_read"}
           }).status == "Ready"

    verbose = Ear.TUI.Fullscreen.new(verbose: true)

    assert Ear.TUI.Fullscreen.handle_event(verbose, %{
             type: :tool_call_started,
             payload: %{name: "file_read"}
           }).status == "Tool: file_read"
  end
end
