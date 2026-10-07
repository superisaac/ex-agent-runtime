defmodule Ear.TUI.QuietRenderer do
  @moduledoc "Renders assistant output and terminal errors without lifecycle diagnostics."

  def render(%{type: :message_delta, payload: %{text: text}}), do: IO.write(text)
  def render(%{type: :run_completed}), do: prompt()

  def render(%{type: :run_failed, payload: %{reason: reason}}),
    do: IO.write("\nError: #{inspect(reason)}\n\near> ")

  def render(%{type: :run_failed}), do: IO.write("\nError: run failed\n\near> ")
  def render(%{type: :run_cancelled}), do: IO.write("\nCancelled\n\near> ")
  def render(_event), do: :ok

  defp prompt, do: IO.write("\n\near> ")
end
