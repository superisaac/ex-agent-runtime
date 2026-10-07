defmodule Ear.TUIToolsTest do
  use ExUnit.Case, async: true

  test "TUI defaults expose read-only project inspection tools" do
    assert Ear.TUI.default_tool_modules() == [Ear.Tools.FileList, Ear.Tools.FileRead]
    assert Enum.map(Ear.TUI.default_tool_modules(), & &1.name()) == ["file_list", "file_read"]
    refute Ear.Tools.Shell in Ear.TUI.default_tool_modules()
    refute Ear.Tools.FileWrite in Ear.TUI.default_tool_modules()
  end
end
