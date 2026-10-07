defmodule Ear.AuthTest do
  use ExUnit.Case, async: false

  test "blank environment credentials are rejected" do
    name = "EAR_AUTH_BLANK_TEST_API_KEY"
    previous = System.get_env(name)
    System.put_env(name, "   ")

    on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)

    assert {:error, {:missing_credential, ^name}} =
             Ear.Auth.Env.login("ear_auth_blank_test", %{})
  end

  test "trims provider names before resolving credentials" do
    name = "EAR_AUTH_TRIM_TEST_API_KEY"
    previous = System.get_env(name)
    System.put_env(name, "credential")

    on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)

    assert {:ok, %{provider: "ear_auth_trim_test"}} =
             Ear.Auth.Env.login(" ear_auth_trim_test ", %{})
  end

  test "rejects non-string providers" do
    assert {:error, :invalid_provider} = Ear.Auth.Env.login(nil, %{})
    assert {:error, :invalid_provider} = Ear.Auth.Noop.login(nil, %{})
    assert {:error, :invalid_provider} = Ear.Auth.Env.login("   ", %{})
    assert {:error, :invalid_provider} = Ear.Auth.Noop.login("   ", %{})
  end

  test "noop authentication trims provider names" do
    assert {:ok, %{provider: "openai", authenticated: true}} =
             Ear.Auth.Noop.login(" openai ", %{})
  end
end
