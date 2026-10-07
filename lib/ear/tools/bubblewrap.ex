defmodule Ear.Tools.Bubblewrap do
  @moduledoc """
  Linux shell isolation using Bubblewrap and unprivileged namespaces.

  Only runtime files and the workspace are mounted from the host. Temporary
  files, processes, and (by default) networking are isolated from the host.
  """

  @runtime_paths ~w(/usr /bin /sbin /lib /lib64 /etc/ld.so.cache /etc/ld.so.conf /etc/ld.so.conf.d /etc/alternatives /etc/ssl)
  @network_paths ~w(/etc/resolv.conf /etc/hosts /etc/nsswitch.conf)

  @doc "Builds a Bubblewrap argument list without invoking a shell."
  def arguments(workspace, command, network? \\ false) do
    paths = @runtime_paths ++ if(network? == true, do: @network_paths, else: [])

    mounts =
      paths
      |> Enum.filter(&File.exists?/1)
      |> Enum.flat_map(&["--ro-bind", &1, &1])

    ["--die-with-parent", "--new-session", "--unshare-all"] ++
      if(network? == true, do: ["--share-net"], else: []) ++
      mounts ++
      [
        "--cap-drop",
        "ALL",
        "--proc",
        "/proc",
        "--dev",
        "/dev",
        "--tmpfs",
        "/tmp",
        "--bind",
        workspace,
        workspace,
        "--chdir",
        workspace,
        "--"
      ] ++ command
  end

  @doc "Checks whether Bubblewrap can create the required namespaces."
  def available? do
    with {:unix, :linux} <- :os.type(),
         executable when is_binary(executable) <- System.find_executable("bwrap") do
      args = arguments(System.tmp_dir!(), ["/bin/sh", "-c", "exit 0"])

      case System.cmd(executable, args, stderr_to_stdout: true) do
        {_, 0} -> true
        _ -> false
      end
    else
      _ -> false
    end
  rescue
    _ -> false
  end
end
