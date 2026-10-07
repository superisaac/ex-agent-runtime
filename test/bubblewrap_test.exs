defmodule Ear.BubblewrapTest do
  use ExUnit.Case, async: true

  alias Ear.Tools.Bubblewrap

  test "isolates namespaces and mounts only the workspace writable" do
    workspace = "/tmp/ear workspace"
    command = ["/usr/bin/env", "-i", "/bin/sh", "-c", "printf '$HOME'"]
    args = Bubblewrap.arguments(workspace, command)

    assert Enum.take(args, 3) == ["--die-with-parent", "--new-session", "--unshare-all"]
    refute "--share-net" in args
    assert ["--cap-drop", "ALL"] in Enum.chunk_every(args, 2, 1, :discard)
    assert ["--tmpfs", "/tmp"] in Enum.chunk_every(args, 2, 1, :discard)
    assert ["--bind", workspace, workspace] in Enum.chunk_every(args, 3, 1, :discard)
    assert Enum.count(args, &(&1 == "--bind")) == 1
    refute ["--ro-bind", "/", "/"] in Enum.chunk_every(args, 3, 1, :discard)
    refute "/etc" in args
    refute "/etc/resolv.conf" in args
    assert Enum.drop_while(args, &(&1 != "--")) == ["--" | command]
  end

  test "network access is explicitly enabled and preserves other isolation" do
    args = Bubblewrap.arguments("/tmp/workspace", ["/bin/sh"], true)
    assert "--share-net" in args
    assert "--unshare-all" in args

    if File.exists?("/etc/resolv.conf") do
      assert ["--ro-bind", "/etc/resolv.conf", "/etc/resolv.conf"] in Enum.chunk_every(
               args,
               3,
               1,
               :discard
             )
    end

    refute "--share-net" in Bubblewrap.arguments("/tmp/workspace", ["/bin/sh"], :yes)
  end
end

defmodule Ear.BubblewrapIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag skip: not Ear.Tools.Bubblewrap.available?()

  test "strict Linux isolation permits workspace writes and hides host files" do
    root = Path.join(System.tmp_dir!(), "ear-bwrap-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    secret = Path.join(root, "secret")
    marker = "/tmp/ear-host-marker-#{System.unique_integer([:positive])}"
    File.mkdir_p!(workspace)
    File.write!(secret, "host-only")
    File.write!(marker, "host-only")

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm(marker)
    end)

    context = %{workspace: workspace, shell_isolation: :strict}

    assert {:ok, "ok"} =
             Ear.Tools.Shell.execute(%{"command" => "printf ok > result; cat result"}, context)

    assert File.read!(Path.join(workspace, "result")) == "ok"

    assert {:error, {:exit_status, _, _}} =
             Ear.Tools.Shell.execute(%{"command" => "cat ../secret"}, context)

    assert {:error, {:exit_status, _, _}} =
             Ear.Tools.Shell.execute(%{"command" => "printf changed > ../secret"}, context)

    assert File.read!(secret) == "host-only"

    assert {:ok, "private"} =
             Ear.Tools.Shell.execute(
               %{"command" => "test ! -e #{marker} && printf private"},
               context
             )
  end
end
