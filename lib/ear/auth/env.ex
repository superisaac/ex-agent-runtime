defmodule Ear.Auth.Env do
  @behaviour Ear.Auth

  @impl true
  def login(provider, opts) when is_binary(provider) do
    provider = String.trim(provider)

    if provider == "" do
      {:error, :invalid_provider}
    else
      login_provider(provider, Map.get(opts, :api_env_key))
    end
  end

  def login(_provider, _opts), do: {:error, :invalid_provider}

  defp login_provider(provider, configured_key) do
    env_name =
      configured_key ||
        case String.downcase(provider) do
          "openai" -> "OPENAI_API_KEY"
          "default" -> "OPENAI_API_KEY"
          other -> String.upcase(other) <> "_API_KEY"
        end

    case System.get_env(env_name) do
      value when is_binary(value) ->
        if String.trim(value) == "" do
          {:error, {:missing_credential, env_name}}
        else
          {:ok, %{provider: provider, credential_source: :environment}}
        end

      _ ->
        {:error, {:missing_credential, env_name}}
    end
  end
end
