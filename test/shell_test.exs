defmodule Ear.ShellTest do
  use ExUnit.Case, async: false

  test "host environment is removed and explicit variables are preserved" do
    name = "EAR_HOST_SECRET_TEST"
    original = System.get_env(name)
    System.put_env(name, "host-only-value")

    on_exit(fn ->
      if original, do: System.put_env(name, original), else: System.delete_env(name)
    end)

    assert {:ok, "unset:explicit"} =
             Ear.Tools.Shell.execute(
               %{
                 "command" =>
                   ~s(printf '%s:%s' "${EAR_HOST_SECRET_TEST-unset}" "$EAR_EXPLICIT_TEST")
               },
               %{env: [{"EAR_EXPLICIT_TEST", "explicit"}]}
             )
  end

  test "stops collecting output once the limit is exceeded" do
    assert {:error, {:output_too_large, nil}} =
             Ear.Tools.Shell.execute(
               %{"command" => "printf 1234567890"},
               %{max_output_bytes: 3}
             )
  end

  test "rejects unknown isolation policies" do
    assert {:error, :invalid_shell_isolation} =
             Ear.Tools.Shell.execute(%{"command" => "printf ok"}, %{
               shell_isolation: :unknown
             })
  end

  test "legacy mode remains explicitly available" do
    assert {:ok, "ok"} =
             Ear.Tools.Shell.execute(%{"command" => "printf ok"}, %{
               shell_isolation: :none
             })
  end

  test "strict mode refuses execution when isolation is unavailable" do
    unless Ear.Tools.Shell.isolation_available?(:strict) do
      backend = if :os.type() == {:unix, :linux}, do: :bubblewrap, else: :sandbox_exec

      assert {:error, {:isolation_unavailable, ^backend}} =
               Ear.Tools.Shell.execute(%{"command" => "printf must-not-run"}, %{
                 shell_isolation: :strict
               })
    end
  end
end
