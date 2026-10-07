defmodule Ear.UserConfigTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Ear.Config.User

  setup do
    dir = Path.join(System.tmp_dir!(), "ear-config-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "creates YAML files from environment values without persisting credentials", %{dir: dir} do
    env = %{
      "EAR_OPENAI_ENDPOINT" => "https://gateway.example/v1/chat/completions",
      "EAR_MODEL" => "custom-model",
      "EAR_API_ENV_KEY" => "GATEWAY_TOKEN",
      "GATEWAY_TOKEN" => "secret-never-written",
      "OPENAI_API_KEY" => "another-secret"
    }

    assert {:ok, config} = User.load(directory: dir, env: env)
    provider = config.models["providers"]["openai"]
    assert provider["baseUrl"] == env["EAR_OPENAI_ENDPOINT"]
    assert provider["apiEnvKey"] == "GATEWAY_TOKEN"
    assert provider["models"] == [%{"id" => "custom-model", "name" => "custom-model"}]
    assert config.settings["defaultProvider"] == "openai"
    assert config.settings["defaultModel"] == "custom-model"

    for file <- ["models.yaml", "settings.yaml"] do
      contents = File.read!(Path.join(dir, file))
      refute contents =~ "secret-never-written"
      refute contents =~ "another-secret"
      refute contents =~ "apiKey:"
      assert {:ok, _} = YamlElixir.read_from_string(contents)
    end
  end

  test "uses safe defaults and compatible OpenAI environment aliases", %{dir: dir} do
    assert {:ok, config} =
             User.load(
               directory: dir,
               env: %{
                 "OPENAI_BASE_URL" => "https://example.com/v1",
                 "OPENAI_MODEL" => "alias-model"
               }
             )

    assert config.models["providers"]["openai"]["baseUrl"] == "https://example.com/v1"
    assert config.settings["defaultModel"] == "alias-model"
    assert config.models["providers"]["openai"]["apiEnvKey"] == "OPENAI_API_KEY"
  end

  test "TUI gives project inspection enough tool-call budget by default", %{dir: dir} do
    assert {:ok, _} = User.load(directory: dir, env: %{})
    assert {:ok, opts} = User.prepare_tui(config_dir: dir)
    assert opts[:max_turns] == 16
    assert opts[:max_tool_calls] == 64
  end

  test "passes model timeout to the configured adapter", %{dir: dir} do
    assert {:ok, _} = User.load(directory: dir, env: %{})
    assert {:ok, opts} = User.prepare_tui(config_dir: dir, model_timeout: 120_000)
    assert opts[:adapter].timeout == 120_000
  end

  test "never replaces existing files when the environment changes", %{dir: dir} do
    assert {:ok, first} = User.load(directory: dir, env: %{})
    original = Map.new(["models.yaml", "settings.yaml"], &{&1, File.read!(Path.join(dir, &1))})
    assert {:ok, ^first} = User.load(directory: dir, env: %{"EAR_MODEL" => "different"})

    assert Enum.all?(original, fn {file, contents} ->
             File.read!(Path.join(dir, file)) == contents
           end)
  end

  test "initial settings reflect environment preferences and valid limits", %{dir: dir} do
    assert {:ok, config} =
             User.load(
               directory: dir,
               env: %{
                 "EAR_STREAM" => "false",
                 "EAR_ANSI" => "0",
                 "EAR_FULLSCREEN" => "true",
                 "EAR_MAX_TURNS" => "12",
                 "EAR_MAX_ELAPSED_MS" => "1000",
                 "EAR_MAX_TOOL_CALLS" => "invalid"
               }
             )

    refute config.settings["stream"]
    refute config.settings["ansi"]
    assert config.settings["fullscreen"]
    assert config.settings["maxTurns"] == 12
    assert config.settings["maxElapsedMs"] == 1000
    refute Map.has_key?(config.settings, "maxToolCalls")
  end

  test "creates missing settings based on an existing custom provider", %{dir: dir} do
    write_models(dir)
    original = File.read!(Path.join(dir, "models.yaml"))
    assert {:ok, config} = User.load(directory: dir, env: %{})
    assert config.settings["defaultProvider"] == "gateway"
    assert config.settings["defaultModel"] == "gateway-model"
    assert File.read!(Path.join(dir, "models.yaml")) == original
  end

  test "creates only missing models and preserves settings", %{dir: dir} do
    File.mkdir_p!(dir)
    settings = "defaultProvider: openai\ndefaultModel: preserved\nstream: false\n"
    File.write!(Path.join(dir, "settings.yaml"), settings)
    assert {:ok, _} = User.load(directory: dir, env: %{"EAR_MODEL" => "preserved"})
    assert File.read!(Path.join(dir, "settings.yaml")) == settings
    assert File.exists?(Path.join(dir, "models.yaml"))
  end

  test "resolves the configured environment key and applies settings", %{dir: dir} do
    write_models(dir)
    assert {:ok, _} = User.load(directory: dir, env: %{})

    with_env("EAR_CONFIG_TEST_TOKEN", "runtime-secret", fn ->
      assert {:ok, opts} = User.prepare_tui(config_dir: dir)

      assert %Ear.Model.OpenAI{
               model: "gateway-model",
               endpoint: "https://gateway.example/v1/chat/completions",
               api_key: "runtime-secret"
             } = opts[:adapter]

      assert opts[:stream]
      assert opts[:provider] == "gateway"
      assert opts[:api_env_key] == "EAR_CONFIG_TEST_TOKEN"
      refute File.read!(Path.join(dir, "models.yaml")) =~ "runtime-secret"
    end)
  end

  test "configuration overrides ambient model settings and explicit options override configuration",
       %{dir: dir} do
    write_models(dir)
    assert {:ok, _} = User.load(directory: dir, env: %{})

    with_env("EAR_MODEL", "ambient-model", fn ->
      assert {:ok, opts} = User.prepare_tui(config_dir: dir)
      assert opts[:adapter].model == "gateway-model"

      assert {:ok, overridden} =
               User.prepare_tui(
                 config_dir: dir,
                 model: "override",
                 endpoint: "https://override.example/chat/completions",
                 stream: false
               )

      assert overridden[:adapter].model == "override"
      assert overridden[:adapter].endpoint == "https://override.example/chat/completions"
      refute overridden[:stream]
      fake = Ear.Model.Scripted.new([%{text: "ok"}])
      assert {:ok, injected} = User.prepare_tui(config_dir: dir, adapter: fake)
      assert injected[:adapter] == fake
    end)
  end

  test "missing configured credential never falls back to another provider key", %{dir: dir} do
    write_models(dir)
    assert {:ok, _} = User.load(directory: dir, env: %{})

    with_env("EAR_CONFIG_TEST_TOKEN", nil, fn ->
      with_env("OPENAI_API_KEY", "wrong-provider-secret", fn ->
        assert {:ok, opts} = User.prepare_tui(config_dir: dir)
        assert is_nil(opts[:adapter].api_key)
        assert {:error, %{reason: :missing_api_key}} = Ear.run("test", adapter: opts[:adapter])
      end)
    end)
  end

  test "selects a model from multiple providers", %{dir: dir} do
    write_models(dir)
    path = Path.join(dir, "models.yaml")

    File.write!(
      path,
      File.read!(path) <>
        """
          other:
            baseUrl: https://other.example/api
            apiEnvKey: OTHER_TEST_KEY
            models:
              - id: other-model
        """
    )

    File.write!(
      Path.join(dir, "settings.yaml"),
      "defaultProvider: other\ndefaultModel: other-model\n"
    )

    assert {:ok, opts} = User.prepare_tui(config_dir: dir)
    assert opts[:provider] == "other"
    assert opts[:api_env_key] == "OTHER_TEST_KEY"
    assert opts[:adapter].endpoint == "https://other.example/api/chat/completions"
    assert opts[:adapter].model == "other-model"
  end

  test "reads manually edited YAML settings with comments and lists", %{dir: dir} do
    write_models(dir)

    File.write!(Path.join(dir, "settings.yaml"), """
    # Local preferences
    defaultProvider: gateway
    defaultModel: gateway-model
    stream: false
    ansi: false
    fullscreen: false
    skillRoots:
      - ./skills
    maxTurns: 3
    """)

    assert {:ok, opts} = User.prepare_tui(config_dir: dir)
    refute opts[:stream]
    refute opts[:ansi]
    assert opts[:skill_roots] == ["./skills"]
    assert opts[:max_turns] == 3
  end

  test "invalid YAML is reported without leaking contents or replacing the file", %{dir: dir} do
    File.mkdir_p!(dir)
    contents = "providers: [secret-invalid-yaml"
    File.write!(Path.join(dir, "models.yaml"), contents)
    assert {:error, error} = User.load(directory: dir, env: %{})
    assert error == {:config, "models.yaml", :invalid_yaml}
    refute inspect(error) =~ "secret-invalid-yaml"
    assert File.read!(Path.join(dir, "models.yaml")) == contents
  end

  test "rejects inline credentials and unknown model selections", %{dir: dir} do
    write_models(dir)
    path = Path.join(dir, "models.yaml")
    valid = File.read!(path)

    File.write!(
      path,
      String.replace(valid, "apiEnvKey:", "apiKey: inline-secret\n    apiEnvKey:")
    )

    assert {:error, {:config, "models.yaml", :inline_api_key_not_supported}} =
             User.load(directory: dir, env: %{})

    File.write!(path, valid)
    assert {:ok, _} = User.load(directory: dir, env: %{})

    File.write!(
      Path.join(dir, "settings.yaml"),
      "defaultProvider: gateway\ndefaultModel: missing\n"
    )

    assert {:error, {:config, "settings.yaml", :unknown_provider_or_model}} =
             User.prepare_tui(config_dir: dir)
  end

  test "invalid provider schemas and settings are rejected before terminal input", %{dir: dir} do
    for models <- [
          "providers: []\n",
          "providers:\n  bad:\n    apiEnvKey: BAD\n",
          "providers: {}\n"
        ] do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "models.yaml"), models)

      assert {:error, {:config, "models.yaml", _}} =
               Ear.TUI.start(config_dir: dir, input: fn _ -> flunk("input must not start") end)
    end

    write_models(dir)

    File.write!(
      Path.join(dir, "settings.yaml"),
      "defaultProvider: gateway\ndefaultModel: gateway-model\nstream: invalid\n"
    )

    assert {:error, {:config, "settings.yaml", :invalid_settings}} =
             User.prepare_tui(config_dir: dir)
  end

  test "both TUI modes create configuration before reading input", %{dir: dir} do
    for fullscreen <- [false, true] do
      config_dir = Path.join(dir, to_string(fullscreen))

      capture_io(fn ->
        assert :ok =
                 Ear.TUI.start(
                   config_dir: config_dir,
                   fullscreen: fullscreen,
                   ansi: false,
                   input: fn _ -> :eof end,
                   key_input: fn -> :eof end
                 )
      end)

      assert File.exists?(Path.join(config_dir, "models.yaml"))
      assert File.exists?(Path.join(config_dir, "settings.yaml"))
    end
  end

  test "login refreshes the selected provider key without discarding configured endpoint and model",
       %{dir: dir} do
    write_models(dir)
    assert {:ok, _} = User.load(directory: dir, env: %{})

    with_env("EAR_CONFIG_TEST_TOKEN", "initial", fn ->
      assert {:ok, opts} = User.prepare_tui(config_dir: dir)
      session = Ear.TUI.Session.new(run_opts: opts)
      System.put_env("EAR_CONFIG_TEST_TOKEN", "refreshed")
      {session, {:message, _}} = Ear.TUI.Session.handle(session, {:command, "login", ""})
      assert session.run_opts[:adapter].api_key == "refreshed"
      assert session.run_opts[:adapter].model == "gateway-model"
      assert session.run_opts[:adapter].endpoint == opts[:adapter].endpoint
    end)
  end

  defp write_models(dir) do
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "models.yaml"), """
    providers:
      gateway:
        baseUrl: https://gateway.example/v1
        api: openai-completions
        apiEnvKey: EAR_CONFIG_TEST_TOKEN
        models:
          - id: gateway-model
            name: Gateway model
    """)
  end

  defp with_env(name, value, fun) do
    previous = System.get_env(name)
    if value, do: System.put_env(name, value), else: System.delete_env(name)

    try do
      fun.()
    after
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end
  end
end
