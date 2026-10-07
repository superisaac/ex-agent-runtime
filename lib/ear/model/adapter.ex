defmodule Ear.Model.Adapter do
  @moduledoc """
  Boundary for complete and streamed model responses.

  Successful responses contain binary `:text`, a list of normalized `:chunks`,
  or nonempty `:tool_calls`. Tool calls require distinct nonempty string IDs,
  nonempty string names, and an `:args` field; tool argument validation belongs
  to the tool. Invalid response shapes fail with `:malformed_model_response`.

  Live streaming adapters send
  `{:model_stream_chunk, context.stream_token, chunks}` to
  `context.stream_owner` while the request is running. Text chunks use
  `%{type: :text_delta, text: binary}`. Tool fragments use
  `%{type: :tool_call_delta, index: non_neg_integer, arguments: binary}` with
  optional string `:id` and `:name` fields. Other supported chunks are
  `:usage` with a map `:usage`, `:finish_reason` with a string `:reason`, and
  `:provider_metadata` with a map `:metadata`.

  Return the accumulated normalized response when streaming finishes. Accepted
  live chunks are authoritative when the final response includes text/chunks.
  Failure or cancellation preserves them in a partial assistant message and
  terminal event; incomplete tool fragments are never executed.
  """

  @callback complete(term(), map(), map()) ::
              {:ok, map()} | {:ok, map(), term()} | {:error, term()}
  @callback stream(term(), map(), map()) ::
              {:ok, map()} | {:ok, map(), term()} | {:error, term()}

  @optional_callbacks stream: 3
end
