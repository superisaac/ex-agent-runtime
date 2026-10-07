defmodule Ear.Tools.Registry do
  def new(tools \\ []) do
    case validate(tools) do
      :ok -> Map.new(tools, fn tool -> {tool.name(), tool} end)
      {:error, reason} -> raise ArgumentError, "Invalid tool registry: #{reason}"
    end
  end

  def validate(tools) when is_list(tools) do
    names = Enum.map(tools, &safe_name/1)

    cond do
      Enum.any?(names, &is_nil/1) -> {:error, :invalid_tool}
      length(names) != length(Enum.uniq(names)) -> {:error, :duplicate_tool_name}
      true -> :ok
    end
  end

  def validate(registry) when is_map(registry) do
    with :ok <- validate(Map.values(registry)) do
      if Enum.all?(registry, fn {name, tool} -> name == safe_name(tool) end),
        do: :ok,
        else: {:error, :tool_name_mismatch}
    end
  end

  def validate(_), do: {:error, :invalid_tool_registry}
  def get(registry, name), do: Map.get(registry, name)

  def descriptions(registry) do
    registry
    |> Enum.sort_by(fn {name, _tool} -> name end)
    |> Enum.map(fn {name, tool} ->
      schema =
        if function_exported?(tool, :parameters, 0),
          do: tool.parameters(),
          else: %{"type" => "object"}

      %{name: name, description: tool.description(), parameters: schema}
    end)
  end

  defp safe_name(tool) do
    if is_atom(tool) do
      Code.ensure_loaded(tool)
      callbacks = [name: 0, description: 0, validate: 1, execute: 2]

      if Enum.all?(callbacks, fn {name, arity} -> function_exported?(tool, name, arity) end) do
        name = tool.name()
        if is_binary(name) and name != "" and is_binary(tool.description()), do: name
      end
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
