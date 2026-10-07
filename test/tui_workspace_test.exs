defmodule Ear.TUIWorkspaceTest do
  use ExUnit.Case, async: true

  test "defaults the TUI workspace to the current directory" do
    assert Ear.TUI.workspace() == File.cwd!()
  end

  test "expands an explicit TUI workspace" do
    assert Ear.TUI.workspace(workspace: "./tmp/../.") == File.cwd!()
    assert Ear.TUI.workspace(workspace: "/tmp") == "/tmp"
  end
end
