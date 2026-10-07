defmodule Ear.Auth.Noop do
  @behaviour Ear.Auth
  def login(provider, _opts) when is_binary(provider) do
    provider = String.trim(provider)

    if provider == "",
      do: {:error, :invalid_provider},
      else: {:ok, %{provider: provider, authenticated: true}}
  end

  def login(_provider, _opts), do: {:error, :invalid_provider}
end
