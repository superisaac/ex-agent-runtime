defmodule Littleagent.Tools.FileRead do
  @behaviour Littleagent.Tools.Tool
  def name, do: "file_read"
  def description, do: "Read a UTF-8 text file from the configured workspace."

  def parameters,
    do: %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}},
      "required" => ["path"]
    }

  def validate(%{"path" => path}) when is_binary(path) and path != "", do: :ok
  def validate(%{path: path}) when is_binary(path) and path != "", do: :ok
  def validate(_), do: {:error, :expected_path}

  def execute(args, context) do
    path = args[:path] || args["path"]
    root = Littleagent.Tools.Path.root(context)
    expanded = Path.expand(path, context[:workspace] || File.cwd!())
    max_bytes = context[:max_bytes] || 256_000

    if not (is_integer(max_bytes) and max_bytes >= 0) do
      {:error, :invalid_max_bytes}
    else
      read_file(expanded, root, max_bytes)
    end
  end

  defp read_file(expanded, root, max_bytes) do
    case Littleagent.Tools.Path.existing(expanded, root) do
      {:error, reason} ->
        {:error, reason}

      {:ok, expanded, _root} ->
        case File.stat(expanded) do
          {:ok, %{type: type}} when type != :regular ->
            {:error, :not_a_regular_file}

          {:ok, %{size: size}} when size > max_bytes ->
            {:error, :file_too_large}

          {:ok, _} ->
            read_bounded(expanded, max_bytes)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp read_bounded(path, max_bytes) do
    case File.open(path, [:read, :binary], fn file ->
           case IO.binread(file, max_bytes + 1) do
             :eof ->
               {:ok, ""}

             {:error, reason} ->
               {:error, reason}

             content when byte_size(content) > max_bytes ->
               {:error, :file_too_large}

             content ->
               if String.valid?(content), do: {:ok, content}, else: {:error, :invalid_utf8}
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
