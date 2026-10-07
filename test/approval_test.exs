defmodule Littleagent.ApprovalTest do
  use ExUnit.Case, async: false

  test "a blocked approval callback is treated as a denial" do
    adapter =
      Littleagent.Model.Scripted.new([
        %{tool_calls: [%{id: "approval", name: "echo", args: "x"}]},
        %{text: "continued"}
      ])

    tools = Littleagent.Tools.Registry.new([Littleagent.Tools.Echo])

    assert {:ok, %{text: "continued"}, events} =
             Littleagent.run_with_events("approve",
               adapter: adapter,
               tools: tools,
               approve_tool: fn _name, _args -> Process.sleep(500) end,
               tool_timeout_ms: 10
             )

    assert Enum.any?(
             events,
             &(&1.type == :tool_call_failed and &1.payload.result == {:error, :tool_denied})
           )
  end
end
