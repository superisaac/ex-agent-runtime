defmodule Littleagent.Tools.Tool do
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback validate(term()) :: :ok | {:error, term()}
  @callback execute(term(), map()) :: {:ok, term()} | {:error, term()}
end
