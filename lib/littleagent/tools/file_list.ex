defmodule Littleagent.Tools.FileList do
  @behaviour Littleagent.Tools.Tool
  def name, do: "file_list"
  def description, do: "List files under a workspace directory."

  def parameters,
    do: %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}},
      "required" => []
    }

  def validate(%{"path" => path}) when is_binary(path), do: :ok
  def validate(%{path: path}) when is_binary(path), do: :ok
  def validate(_), do: :ok

  def execute(args, context) do
    root = Littleagent.Tools.Path.root(context)
    relative = args[:path] || args["path"] || "."
    directory = Path.expand(relative, context[:workspace] || File.cwd!())
    max_entries = context[:max_entries] || 500

    if not (is_integer(max_entries) and max_entries >= 0) do
      {:error, :invalid_max_entries}
    else
      list_directory(directory, root, max_entries)
    end
  end

  defp list_directory(directory, root, max_entries) do
    case Littleagent.Tools.Path.existing(directory, root) do
      {:error, reason} ->
        {:error, reason}

      {:ok, directory, root} ->
        if not File.dir?(directory),
          do: {:error, :not_a_directory},
          else: {:ok, list_files(directory, root, max_entries)}
    end
  end

  defp list_files(directory, root, max_entries) do
    walk([directory], root, max_entries, [], MapSet.new()) |> Enum.reverse() |> Enum.sort()
  end

  defp walk(_pending, _root, max_entries, acc, _visited) when length(acc) >= max_entries, do: acc
  defp walk([], _root, _max_entries, acc, _visited), do: acc

  defp walk([directory | pending], root, max_entries, acc, visited) do
    if MapSet.member?(visited, directory) do
      walk(pending, root, max_entries, acc, visited)
    else
      walk_directory(directory, pending, root, max_entries, acc, MapSet.put(visited, directory))
    end
  end

  defp walk_directory(directory, pending, root, max_entries, acc, visited) do
    case File.ls(directory) do
      {:ok, names} ->
        {pending, acc} =
          Enum.reduce_while(Enum.sort(names), {pending, acc}, fn name, {queue, files} ->
            if length(files) >= max_entries do
              {:halt, {queue, files}}
            else
              path = Path.join(directory, name)

              case Littleagent.Tools.Path.existing(path, {:ok, root}) do
                {:ok, canonical, _} ->
                  cond do
                    File.dir?(canonical) ->
                      {:cont, {[canonical | queue], files}}

                    File.regular?(canonical) ->
                      {:cont, {queue, [Path.relative_to(canonical, root) | files]}}

                    true ->
                      {:cont, {queue, files}}
                  end

                _ ->
                  {:cont, {queue, files}}
              end
            end
          end)

        walk(pending, root, max_entries, acc, visited)

      {:error, _reason} ->
        walk(pending, root, max_entries, acc, visited)
    end
  end
end
