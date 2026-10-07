defmodule Littleagent.Tools.Echo do
  @behaviour Littleagent.Tools.Tool
  def name, do: "echo"
  def description, do: "Return the provided text."

  def parameters,
    do: %{
      "type" => "object",
      "properties" => %{"text" => %{"type" => "string", "description" => "Text to return"}},
      "required" => ["text"]
    }

  def validate(value) when is_binary(value), do: :ok
  def validate(%{"text" => text}) when is_binary(text), do: :ok
  def validate(%{text: text}) when is_binary(text), do: :ok
  def validate(_), do: {:error, :expected_string}
  def execute(value, _context), do: {:ok, value}
end
