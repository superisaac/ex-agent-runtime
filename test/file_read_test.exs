defmodule Ear.FileReadTest do
  use ExUnit.Case, async: true
  alias Ear.Tools.FileRead

  setup do
    root = Path.join(System.tmp_dir!(), "ear-read-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "accepts exactly the byte limit and rejects one byte more", %{root: root} do
    File.write!(Path.join(root, "text"), "é")
    assert {:ok, "é"} = FileRead.execute(%{path: "text"}, workspace: root, max_bytes: 2)

    assert {:error, :file_too_large} =
             FileRead.execute(%{path: "text"}, workspace: root, max_bytes: 1)
  end

  test "zero byte limit accepts only empty files", %{root: root} do
    File.write!(Path.join(root, "empty"), "")
    File.write!(Path.join(root, "text"), "x")
    assert {:ok, ""} = FileRead.execute(%{path: "empty"}, workspace: root, max_bytes: 0)

    assert {:error, :file_too_large} =
             FileRead.execute(%{path: "text"}, workspace: root, max_bytes: 0)
  end

  test "rejects directories and invalid UTF-8", %{root: root} do
    assert {:error, :not_a_regular_file} = FileRead.execute(%{path: "."}, workspace: root)
    File.write!(Path.join(root, "binary"), <<255>>)
    assert {:error, :invalid_utf8} = FileRead.execute(%{path: "binary"}, workspace: root)
  end

  test "rejects an empty path before touching the workspace" do
    assert {:error, :expected_path} = FileRead.validate(%{"path" => ""})
  end
end
