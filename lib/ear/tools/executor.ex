defmodule Ear.Tools.Executor do
  def execute(registry, name, args, context \\ %{}) do
    case Map.get(registry, name) do
      nil ->
        {:error, :unknown_tool}

      tool ->
        with :ok <- tool.validate(args),
             {:ok, value} <- tool.execute(args, context) do
          {:ok, value}
        end
    end
  rescue
    exception -> {:error, {:exception, exception}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    :throw, value -> {:error, {:throw, value}}
  end

  def execute_with_timeout(registry, name, args, context, timeout)
      when is_integer(timeout) and timeout >= 0 do
    task =
      Task.Supervisor.async_nolink(Ear.TaskSupervisor, fn ->
        execute(registry, name, args, context)
      end)

    result = Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill)

    case result do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> {:error, :tool_timeout}
    end
  end

  def execute_with_timeout(registry, name, args, context, _timeout),
    do: execute(registry, name, args, context)
end
