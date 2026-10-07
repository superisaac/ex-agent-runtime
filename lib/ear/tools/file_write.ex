defmodule Ear.Tools.FileWrite do
  @behaviour Ear.Tools.Tool
  def name, do: "file_write"
  def description, do: "Write UTF-8 text to a file inside the configured workspace."

  def parameters,
    do: %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}, "content" => %{"type" => "string"}},
      "required" => ["path", "content"]
    }

  def validate(%{"path" => path, "content" => content})
      when is_binary(path) and path != "" and is_binary(content), do: :ok

  def validate(%{path: path, content: content})
      when is_binary(path) and path != "" and is_binary(content),
      do: :ok

  def validate(_), do: {:error, :expected_path_and_content}

  def execute(args, context) do
    path = args[:path] || args["path"]
    content = args[:content] || args["content"]
    workspace = context[:workspace] || File.cwd!()
    root = Ear.Tools.Path.root(context)
    expanded = Path.expand(path, workspace)
    max_bytes = context[:max_bytes] || 256_000

    if not (is_integer(max_bytes) and max_bytes >= 0) do
      {:error, :invalid_max_bytes}
    else
      write_file(expanded, root, content, max_bytes)
    end
  end

  defp write_file(expanded, root, content, max_bytes) do
    cond do
      byte_size(content) > max_bytes ->
        {:error, :file_too_large}

      not String.valid?(content) ->
        {:error, :invalid_utf8}

      true ->
        case Ear.Tools.Path.writable(expanded, root) do
          {:error, reason} ->
            {:error, reason}

          {:ok, target, _root} ->
            File.mkdir_p(Path.dirname(target))
            |> case do
              :ok ->
                case File.write(target, content) do
                  :ok -> {:ok, "written"}
                  error -> error
                end

              error ->
                error
            end
        end
    end
  end
end
