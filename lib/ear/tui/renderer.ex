defmodule Ear.TUI.Renderer do
  def render(%{type: :run_started}), do: IO.puts("[run] started")

  def render(%{type: :skill_loaded, payload: %{name: name}}),
    do: IO.puts("[skill] #{name} loaded")

  def render(%{type: :skill_loaded}), do: IO.puts("[skill] loaded")

  def render(%{type: :skill_error, payload: %{error: error}}),
    do: IO.puts("[skill] failed: #{inspect(error)}")

  def render(%{type: :skill_error}), do: IO.puts("[skill] failed")

  def render(%{type: :tool_call_started, payload: %{name: name}}),
    do: IO.puts("\n[tool] #{name} started")

  def render(%{type: :tool_call_started}), do: IO.puts("\n[tool] started")

  def render(%{type: :tool_call_completed, payload: %{name: name}}),
    do: IO.puts("\n[tool] #{name} completed")

  def render(%{type: :tool_call_completed}), do: IO.puts("\n[tool] completed")

  def render(%{type: :tool_call_failed, payload: %{name: name, result: result}}),
    do: IO.puts("\n[tool] #{name} failed: #{inspect(result)}")

  def render(%{type: :tool_call_failed}), do: IO.puts("\n[tool] failed")

  def render(%{type: :message_delta, payload: %{text: text}}), do: IO.write(text)

  def render(%{type: :run_completed}), do: IO.write("\n")

  def render(%{type: :run_failed, payload: %{reason: reason}}),
    do: IO.puts("\nError: #{inspect(reason)}")

  def render(%{type: :run_failed}), do: IO.puts("\nError: run failed")

  def render(%{type: :run_cancelled}), do: IO.puts("\nCancelled")
  def render(_), do: :ok
end
