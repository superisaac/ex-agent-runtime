defmodule Littleagent.ShellTest do
  use ExUnit.Case, async: false

  test "host environment is removed and explicit variables are preserved" do
    name = "LITTLEAGENT_HOST_SECRET_TEST"
    original = System.get_env(name)
    System.put_env(name, "host-only-value")

    on_exit(fn ->
      if original, do: System.put_env(name, original), else: System.delete_env(name)
    end)

    assert {:ok, "unset:explicit"} =
             Littleagent.Tools.Shell.execute(
               %{
                 "command" =>
                   ~s(printf '%s:%s' "${LITTLEAGENT_HOST_SECRET_TEST-unset}" "$LITTLEAGENT_EXPLICIT_TEST")
               },
               %{env: [{"LITTLEAGENT_EXPLICIT_TEST", "explicit"}]}
             )
  end

  test "stops collecting output once the limit is exceeded" do
    assert {:error, {:output_too_large, nil}} =
             Littleagent.Tools.Shell.execute(
               %{"command" => "printf 1234567890"},
               %{max_output_bytes: 3}
             )
  end

  test "rejects unknown isolation policies" do
    assert {:error, :invalid_shell_isolation} =
             Littleagent.Tools.Shell.execute(%{"command" => "printf ok"}, %{
               shell_isolation: :unknown
             })
  end

  test "legacy mode remains explicitly available" do
    assert {:ok, "ok"} =
             Littleagent.Tools.Shell.execute(%{"command" => "printf ok"}, %{
               shell_isolation: :none
             })
  end
end
