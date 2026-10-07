defmodule Ear.Model.Scripted do
  @behaviour Ear.Model.Adapter
  defstruct responses: []
  def new(responses), do: %__MODULE__{responses: responses}

  def complete(%__MODULE__{responses: [response | rest]}, _request, _context),
    do: {:ok, response, %__MODULE__{responses: rest}}

  def complete(%__MODULE__{responses: []}, _request, _context),
    do: {:error, :no_scripted_response}

  def stream(adapter, request, context) do
    case complete(adapter, request, context) do
      {:ok, %{tool_calls: calls} = response, next_adapter} when calls != [] ->
        {:ok, response, next_adapter}

      {:ok, %{text: text}, next_adapter} when is_binary(text) ->
        {:ok, %{chunks: Enum.map(String.graphemes(text), &%{type: :text_delta, text: &1})},
         next_adapter}

      {:ok, response, next_adapter} ->
        {:ok, response, next_adapter}

      other ->
        other
    end
  end
end
