defmodule Ear.Tools.Shell do
  @behaviour Ear.Tools.Tool
  def name, do: "shell"
  def description, do: "Run a shell command in the configured workspace."

  def parameters,
    do: %{
      "type" => "object",
      "properties" => %{"command" => %{"type" => "string"}},
      "required" => ["command"]
    }

  def validate(%{"command" => command}) when is_binary(command) and command != "", do: :ok
  def validate(%{command: command}) when is_binary(command) and command != "", do: :ok
  def validate(_), do: {:error, :expected_command}

  def execute(args, context) do
    command = args[:command] || args["command"]
    workspace = Path.expand(context[:workspace] || File.cwd!())
    max_output = context[:max_output_bytes] || 64_000
    isolation = context[:shell_isolation] || :workspace

    env = Map.new(context[:env] || []) |> Map.to_list()

    if not (is_integer(max_output) and max_output >= 0) do
      {:error, :invalid_max_output_bytes}
    else
      if isolation not in [:none, :workspace, :strict] do
        {:error, :invalid_shell_isolation}
      else
        execute_in_workspace(command, workspace, max_output, env, isolation, context)
      end
    end
  end

  defp execute_in_workspace(command, workspace, max_output, env, isolation, context) do
    case Ear.Tools.Path.existing(workspace, Ear.Tools.Path.root(context)) do
      {:error, reason} ->
        {:error, reason}

      {:ok, workspace, _root} ->
        execute_command(command, workspace, max_output, env, isolation, context)
    end
  end

  defp execute_command(command, workspace, max_output, env, isolation, context) do
    executable = System.find_executable("env") || "/usr/bin/env"
    shell = System.find_executable("sh") || "/bin/sh"
    environment = [{"PATH", System.get_env("PATH", "/usr/bin:/bin")} | env]

    with {:ok, launcher, args} <-
           launch_command(executable, shell, command, environment, workspace, isolation, context) do
      port =
        Port.open({:spawn_executable, launcher}, [
          :binary,
          :exit_status,
          {:args, args},
          {:cd, workspace}
        ])

      collect_output(port, max_output, [])
    end
  rescue
    exception -> {:error, {:exception, exception}}
  end

  def isolation_available?(:none), do: true

  def isolation_available?(mode) when mode in [:workspace, :strict], do: sandbox_exec_available?()

  def isolation_available?(_), do: false

  defp launch_command(executable, shell, command, environment, _workspace, :none, _context),
    do: {:ok, executable, ["-i" | environment_args(environment)] ++ [shell, "-c", command]}

  defp launch_command(executable, shell, command, environment, workspace, isolation, context)
       when isolation in [:workspace, :strict] do
    case {System.find_executable("sandbox-exec"), sandbox_exec_available?()} do
      {_sandbox, false} when isolation == :strict ->
        {:error, {:isolation_unavailable, :sandbox_exec}}

      {_sandbox, false} ->
        {:ok, executable, ["-i" | environment_args(environment)] ++ [shell, "-c", command]}

      {nil, _} ->
        {:ok, executable, ["-i" | environment_args(environment)] ++ [shell, "-c", command]}

      {sandbox, true} ->
        profile = sandbox_profile(workspace, Map.get(context, :shell_network, false))

        {:ok, sandbox,
         ["-p", profile, executable, "-i" | environment_args(environment)] ++
           [shell, "-c", command]}
    end
  end

  defp sandbox_profile(workspace, network?) do
    workspace = profile_path(workspace)
    network_rule = if network? == true, do: "(allow network*)", else: "(deny network*)"

    """
    (version 1)
    (deny default)
    (allow process-fork)
    (allow process-exec*)
    (allow signal (target self))
    (allow sysctl-read)
    (allow file-read-metadata)
    (allow file-read* (subpath "#{workspace}") (subpath "/usr") (subpath "/bin") (subpath "/sbin") (subpath "/System") (subpath "/Library") (subpath "/private/etc") (subpath "/dev"))
    (allow file-write* (subpath "#{workspace}") (subpath "/private/tmp"))
    #{network_rule}
    """
  end

  defp sandbox_exec_available? do
    case System.find_executable("sandbox-exec") do
      nil ->
        false

      executable ->
        profile = sandbox_profile(System.tmp_dir!(), false)

        case System.cmd(executable, ["-p", profile, "/usr/bin/true"], stderr_to_stdout: true) do
          {_output, 0} -> true
          _ -> false
        end
    end
  rescue
    _ -> false
  end

  defp profile_path(path) do
    path
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp environment_args(environment) do
    Enum.flat_map(environment, fn {name, value} ->
      [to_string(name) <> "=" <> to_string(value)]
    end)
  end

  defp collect_output(port, max_output, chunks, size) do
    receive do
      {^port, {:data, data}} ->
        next_size = size + byte_size(data)

        if next_size > max_output do
          Port.close(port)
          {:error, {:output_too_large, nil}}
        else
          collect_output(port, max_output, [data | chunks], next_size)
        end

      {^port, {:exit_status, 0}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, status}} ->
        output = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        {:error, {:exit_status, status, output}}
    end
  end

  defp collect_output(port, max_output, chunks), do: collect_output(port, max_output, chunks, 0)
end
