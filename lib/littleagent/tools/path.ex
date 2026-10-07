defmodule Littleagent.Tools.Path do
  @moduledoc false

  def root(context), do: canonical(context[:workspace] || File.cwd!())

  def inside?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  def existing(path, root) do
    with {:ok, canonical_root} <- root,
         {:ok, canonical_path} <- canonical(path),
         true <- inside?(canonical_path, canonical_root) do
      {:ok, canonical_path, canonical_root}
    else
      false ->
        {:error, :path_outside_workspace}

      {:error, :enoent} ->
        with {:ok, canonical_root} <- root,
             {:ok, canonical_parent} <- canonical(Path.dirname(path)),
             true <- inside?(canonical_parent, canonical_root) do
          {:error, :enoent}
        else
          false -> {:error, :path_outside_workspace}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def writable(path, root) do
    with {:ok, canonical_root} <- root,
         {:ok, canonical_path} <- writable_path(Path.expand(path), 0),
         true <- inside?(canonical_path, canonical_root) do
      {:ok, canonical_path, canonical_root}
    else
      false -> {:error, :path_outside_workspace}
      {:error, reason} -> {:error, reason}
    end
  end

  defp writable_path(_path, depth) when depth > 64, do: {:error, :too_many_path_components}

  defp writable_path(path, depth) do
    case File.lstat(path) do
      {:ok, _} ->
        canonical(path)

      {:error, :enoent} ->
        parent = Path.dirname(path)

        if parent == path do
          {:error, :enoent}
        else
          with {:ok, canonical_parent} <- writable_path(parent, depth + 1) do
            {:ok, Path.join(canonical_parent, Path.basename(path))}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp canonical(path), do: canonical(Path.expand(path), 0)

  defp canonical(_path, depth) when depth > 32, do: {:error, :too_many_symlinks}

  defp canonical(path, depth) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(path) do
          canonical(Path.expand(target, Path.dirname(path)), depth + 1)
        end

      {:ok, _} ->
        parent = Path.dirname(path)

        if parent == path do
          {:ok, path}
        else
          with {:ok, canonical_parent} <- canonical(parent, depth) do
            {:ok, Path.join(canonical_parent, Path.basename(path))}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
