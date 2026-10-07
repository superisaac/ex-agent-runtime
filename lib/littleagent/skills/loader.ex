defmodule Littleagent.Skills.Loader do
  @max_skill_bytes 256_000

  def discover(roots), do: roots |> Enum.flat_map(&discover_root/1) |> Enum.uniq_by(& &1.name)

  def discover_report(roots) do
    roots
    |> Enum.flat_map(&discover_root_report/1)
    |> Enum.reduce({[], []}, fn
      {:ok, skill}, {skills, errors} -> {[skill | skills], errors}
      {:error, error}, {skills, errors} -> {skills, [error | errors]}
    end)
    |> then(fn {skills, errors} -> {Enum.uniq_by(skills, & &1.name), Enum.reverse(errors)} end)
  end

  defp discover_root(root),
    do:
      root
      |> Path.join("*")
      |> Path.wildcard()
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(fn dir -> load(Path.join(dir, "SKILL.md")) end)

  defp discover_root_report(root) do
    root
    |> Path.expand()
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(fn dir -> load_report(Path.join(dir, "SKILL.md"), root) end)
  end

  def load_report(path, root) do
    expanded = Path.expand(path)

    cond do
      not skill_path_inside?(expanded, root) ->
        {:error, {:path_outside_root, path}}

      not File.exists?(expanded) ->
        {:error, {:missing_skill_file, path}}

      true ->
        case File.stat(expanded) do
          {:ok, %{size: size}} when size > @max_skill_bytes ->
            {:error, {:skill_too_large, path}}

          {:ok, _} ->
            case load(path) do
              [skill] -> {:ok, skill}
              [] -> {:error, {:invalid_skill, path}}
            end

          {:error, _reason} ->
            {:error, {:missing_skill_file, path}}
        end
    end
  end

  defp skill_path_inside?(path, root) do
    case Littleagent.Tools.Path.existing(path, Littleagent.Tools.Path.root(%{workspace: root})) do
      {:ok, _canonical, _root} ->
        true

      {:error, :enoent} ->
        Path.expand(path) == Path.expand(root) or
          String.starts_with?(Path.expand(path), Path.expand(root) <> "/")

      _ ->
        false
    end
  end

  def load(path) do
    with {:ok, body} <- File.read(path),
         {attrs, content} <- split_front_matter(body),
         {:ok, name} <- required(attrs, "name"),
         {:ok, description} <- required(attrs, "description") do
      [
        %{
          name: name,
          description: description,
          priority: integer(attrs["priority"], 0),
          enabled: attrs["enabled"] != "false",
          tags: tags(attrs["tags"]),
          content: content,
          path: path
        }
      ]
    else
      _ -> []
    end
  end

  defp split_front_matter("---\n" <> rest) do
    case String.split(rest, "\n---\n", parts: 2) do
      [head, body] ->
        {Map.new(String.split(head, "\n", trim: true), fn line ->
           case String.split(line, ":", parts: 2) do
             [k, v] -> {String.trim(k), String.trim(v)}
             _ -> {line, ""}
           end
         end), body}

      _ ->
        {%{}, rest}
    end
  end

  defp split_front_matter(body), do: {%{}, body}

  defp required(attrs, key) do
    case attrs[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, key}
    end
  end

  defp integer(value, default) do
    case Integer.parse(to_string(value)) do
      {n, _} -> n
      _ -> default
    end
  end

  defp tags(nil), do: []

  defp tags(value),
    do:
      value
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
end
