defmodule Littleagent.Model.Adapter do
  @callback complete(term(), map(), map()) ::
              {:ok, map()} | {:ok, map(), term()} | {:error, term()}
  @callback stream(term(), map(), map()) ::
              {:ok, map()} | {:ok, map(), term()} | {:error, term()}

  @optional_callbacks stream: 3
end
