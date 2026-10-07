defmodule Ear.Config.User do
  @moduledoc """
  User model and TUI settings stored beneath `~/.ear/agent`.

  Missing files are created from environment defaults, without replacing existing
  files. Credentials are resolved through `apiEnvKey` and are never serialized.
  """

  @default_base_url "https://api.openai.com/v1"
  @default_model "gpt-4o-mini"
  @run_limits %{
    "maxTurns" => :max_turns,
    "maxToolCalls" => :max_tool_calls,
    "maxOutputChars" => :max_output_chars,
    "maxElapsedMs" => :max_elapsed_ms,
    "toolTimeoutMs" => :tool_timeout_ms
  }

  def directory, do: Path.join(System.user_home!(), ".ear/agent")

  @doc "Creates missing files and reads validated configuration. Errors omit file contents."
  def load(opts \\ []) do
    dir = Keyword.get(opts, :directory, directory())
    env = Keyword.get(opts, :env, System.get_env())
    {models, settings} = defaults(env)

    with :ok <- mkdir(dir),
         :ok <- create_missing(Path.join(dir, "models.yaml"), models_yaml(models)),
         {:ok, models} <- read_yaml(Path.join(dir, "models.yaml")),
         :ok <- validate_models(models),
         settings <- select_default(settings, models),
         :ok <- create_missing(Path.join(dir, "settings.yaml"), settings_yaml(settings)),
         {:ok, settings} <- read_yaml(Path.join(dir, "settings.yaml")),
         :ok <- validate_settings(settings) do
      {:ok, %{models: models, settings: settings}}
    end
  end

  @doc "Applies user configuration to TUI options; explicit options take precedence."
  def prepare_tui(opts) do
    if Keyword.get(opts, :config, true) == false do
      {:ok, opts}
    else
      with {:ok, config} <- load(directory: Keyword.get(opts, :config_dir, directory())),
           {:ok, configured} <- tui_options(config, opts) do
        {:ok, Keyword.merge(configured, opts)}
      end
    end
  end

  defp defaults(env) do
    provider = env_value(env, ["EAR_PROVIDER"], "openai")
    model = env_value(env, ["EAR_MODEL", "OPENAI_MODEL"], @default_model)
    base_url = env_value(env, ["EAR_OPENAI_ENDPOINT", "OPENAI_BASE_URL"], @default_base_url)
    api_env_key = env_value(env, ["EAR_API_ENV_KEY"], "OPENAI_API_KEY")

    models = %{
      "providers" => %{
        provider => %{
          "baseUrl" => base_url,
          "api" => "openai-completions",
          "apiEnvKey" => api_env_key,
          "models" => [%{"id" => model, "name" => model}]
        }
      }
    }

    settings = %{
      "defaultProvider" => provider,
      "defaultModel" => model,
      "stream" => env_boolean(env, "EAR_STREAM", true),
      "ansi" => env_boolean(env, "EAR_ANSI", true),
      "fullscreen" => env_boolean(env, "EAR_FULLSCREEN", false),
      "skillRoots" => []
    }

    settings =
      Enum.reduce(@run_limits, settings, fn {key, option}, acc ->
        value = env_value(env, ["EAR_" <> String.upcase(Atom.to_string(option))], "")

        case Integer.parse(value) do
          {limit, ""} when limit >= 0 -> Map.put(acc, key, limit)
          _ -> acc
        end
      end)

    {models, settings}
  end

  defp env_boolean(env, name, default) do
    case String.downcase(env_value(env, [name], "")) do
      value when value in ["true", "1"] -> true
      value when value in ["false", "0"] -> false
      _ -> default
    end
  end

  defp env_value(env, keys, default) do
    Enum.find_value(keys, default, fn key ->
      case env[key] do
        value when is_binary(value) ->
          if String.trim(value) != "", do: String.trim(value)

        _ ->
          nil
      end
    end)
  end

  defp select_default(settings, %{"providers" => providers}) do
    preferred = settings["defaultProvider"]

    provider =
      if Map.has_key?(providers, preferred),
        do: preferred,
        else: hd(Enum.sort(Map.keys(providers)))

    models = providers[provider]["models"]
    preferred_model = settings["defaultModel"]

    model =
      if Enum.any?(models, &(&1["id"] == preferred_model)),
        do: preferred_model,
        else: hd(models)["id"]

    Map.merge(settings, %{"defaultProvider" => provider, "defaultModel" => model})
  end

  defp tui_options(%{models: %{"providers" => providers}, settings: settings}, opts) do
    provider_name = Keyword.get(opts, :provider, settings["defaultProvider"])
    model_name = Keyword.get(opts, :model, settings["defaultModel"])

    with provider when is_map(provider) <- providers[provider_name],
         true <-
           Enum.any?(provider["models"], &(&1["id"] == model_name)) or
             Keyword.has_key?(opts, :model) do
      adapter =
        Ear.Model.OpenAI.new(
          endpoint: Keyword.get(opts, :endpoint, endpoint(provider["baseUrl"])),
          model: model_name,
          api_key: System.get_env(provider["apiEnvKey"])
        )

      configured = [
        adapter: adapter,
        provider: provider_name,
        api_env_key: provider["apiEnvKey"],
        stream: Map.get(settings, "stream", true),
        ansi: Map.get(settings, "ansi", true),
        fullscreen: Map.get(settings, "fullscreen", false),
        skill_roots: Map.get(settings, "skillRoots", [])
      ]

      configured =
        Enum.reduce(@run_limits, configured, fn {key, option}, acc ->
          if Map.has_key?(settings, key), do: Keyword.put(acc, option, settings[key]), else: acc
        end)

      {:ok, configured}
    else
      _ -> {:error, {:config, "settings.yaml", :unknown_provider_or_model}}
    end
  end

  defp endpoint(base_url) do
    base_url = String.trim_trailing(base_url, "/")

    if String.ends_with?(base_url, "/chat/completions"),
      do: base_url,
      else: base_url <> "/chat/completions"
  end

  defp validate_models(%{"providers" => providers})
       when is_map(providers) and map_size(providers) > 0 do
    if Enum.all?(providers, fn {name, provider} ->
         nonempty?(name) and valid_provider?(provider)
       end),
       do: :ok,
       else: {:error, {:config, "models.yaml", :invalid_provider}}
  end

  defp validate_models(_), do: {:error, {:config, "models.yaml", :invalid_providers}}

  defp valid_provider?(%{"baseUrl" => url, "apiEnvKey" => key, "models" => models} = provider) do
    nonempty?(url) and valid_url?(url) and nonempty?(key) and
      Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, key) and
      Map.get(provider, "api", "openai-completions") == "openai-completions" and
      is_list(models) and models != [] and
      Enum.all?(models, fn model -> is_map(model) and nonempty?(model["id"]) end) and
      length(models) == length(Enum.uniq_by(models, & &1["id"]))
  end

  defp valid_provider?(_), do: false

  defp valid_url?(url) do
    uri = URI.parse(url)
    uri.scheme in ["http", "https"] and nonempty?(uri.host) and is_nil(uri.userinfo)
  rescue
    _ -> false
  end

  defp validate_settings(settings) when is_map(settings) do
    valid? =
      nonempty?(settings["defaultProvider"]) and nonempty?(settings["defaultModel"]) and
        Enum.all?(["stream", "ansi", "fullscreen"], fn key ->
          not Map.has_key?(settings, key) or is_boolean(settings[key])
        end) and
        (not Map.has_key?(settings, "skillRoots") or
           (is_list(settings["skillRoots"]) and Enum.all?(settings["skillRoots"], &nonempty?/1))) and
        Enum.all?(@run_limits, fn {key, _} ->
          not Map.has_key?(settings, key) or (is_integer(settings[key]) and settings[key] >= 0)
        end)

    if valid?, do: :ok, else: {:error, {:config, "settings.yaml", :invalid_settings}}
  end

  defp validate_settings(_), do: {:error, {:config, "settings.yaml", :invalid_settings}}
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:config, :directory, reason}}
    end
  end

  defp create_missing(path, contents) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, file} ->
        result = IO.binwrite(file, contents)
        File.close(file)
        if result == :ok, do: :ok, else: {:error, {:config, Path.basename(path), :write_failed}}

      {:error, :eexist} ->
        :ok

      {:error, reason} ->
        {:error, {:config, Path.basename(path), reason}}
    end
  end

  defp read_yaml(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, document} <- YamlElixir.read_from_string(contents) do
      if inline_key?(document),
        do: {:error, {:config, Path.basename(path), :inline_api_key_not_supported}},
        else: {:ok, document}
    else
      _ -> {:error, {:config, Path.basename(path), :invalid_yaml}}
    end
  rescue
    _ -> {:error, {:config, Path.basename(path), :invalid_yaml}}
  end

  defp inline_key?(value) when is_map(value) do
    Enum.any?(value, fn {key, item} -> key in ["apiKey", "api_key"] or inline_key?(item) end)
  end

  defp inline_key?(value) when is_list(value), do: Enum.any?(value, &inline_key?/1)
  defp inline_key?(_), do: false

  defp models_yaml(%{"providers" => providers}) do
    [{name, provider}] = Map.to_list(providers)
    model = hd(provider["models"])

    """
    # Provider credentials are read from apiEnvKey; never put API keys here.
    providers:
      #{scalar(name)}:
        baseUrl: #{scalar(provider["baseUrl"])}
        api: openai-completions
        apiEnvKey: #{scalar(provider["apiEnvKey"])}
        models:
          - id: #{scalar(model["id"])}
            name: #{scalar(model["name"])}
    """
  end

  defp settings_yaml(settings) do
    fields =
      ["defaultProvider", "defaultModel", "stream", "ansi", "fullscreen", "skillRoots"] ++
        Enum.sort(Map.keys(@run_limits))

    fields
    |> Enum.filter(&Map.has_key?(settings, &1))
    |> Enum.map_join("", &"#{&1}: #{scalar(settings[&1])}\n")
  end

  defp scalar(value), do: value |> :json.encode() |> IO.iodata_to_binary()
end
