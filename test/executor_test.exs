defmodule Ear.ExecutorTest.FailingTool do
  def name, do: "failing"
  def description, do: "Exercise tool failure handling."
  def validate(_), do: :ok
  def execute(%{"kind" => "exit"}, _), do: exit(:boom)
  def execute(%{"kind" => "throw"}, _), do: throw(:boom)
  def execute(%{"kind" => "kill"}, _), do: Process.exit(self(), :kill)

  def execute(%{"kind" => "block"}, %{owner: owner}) do
    send(owner, {:tool_worker, self()})

    receive do
      :release -> {:ok, "released"}
    end
  end
end

defmodule Ear.ExecutorTest do
  use ExUnit.Case, async: false

  test "converts exits and throws to errors" do
    registry = %{"failing" => Ear.ExecutorTest.FailingTool}

    assert {:error, {:exit, :boom}} =
             Ear.Tools.Executor.execute(registry, "failing", %{"kind" => "exit"})

    assert {:error, {:throw, :boom}} =
             Ear.Tools.Executor.execute(registry, "failing", %{"kind" => "throw"})
  end

  test "converts task exits from a worker" do
    registry = %{"failing" => Ear.ExecutorTest.FailingTool}

    assert {:error, {:exit, :boom}} =
             Ear.Tools.Executor.execute_with_timeout(
               registry,
               "failing",
               %{"kind" => "exit"},
               %{},
               100
             )
  end

  test "an untrappable worker exit does not kill its caller" do
    assert {:error, {:exit, :killed}} =
             Ear.Tools.Executor.execute_with_timeout(
               %{"failing" => Ear.ExecutorTest.FailingTool},
               "failing",
               %{"kind" => "kill"},
               %{},
               1000
             )

    refute_receive {:DOWN, _, :process, _, _}
  end

  test "a timed out worker is terminated" do
    assert {:error, :tool_timeout} =
             Ear.Tools.Executor.execute_with_timeout(
               %{"failing" => Ear.ExecutorTest.FailingTool},
               "failing",
               %{"kind" => "block"},
               %{owner: self()},
               100
             )

    assert_receive {:tool_worker, worker}
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :noproc}
  end

  test "the agent continues after an untrappable tool exit" do
    adapter =
      Ear.Model.Scripted.new([
        %{tool_calls: [%{id: "killed-tool", name: "failing", args: %{"kind" => "kill"}}]},
        %{text: "recovered"}
      ])

    assert {:ok, %{text: "recovered"}, events} =
             Ear.run_with_events("try the tool",
               adapter: adapter,
               tool_modules: [Ear.ExecutorTest.FailingTool]
             )

    assert Enum.any?(events, fn event ->
             event.type == :tool_call_failed and event.tool_call_id == "killed-tool" and
               event.payload.result == {:error, {:exit, :killed}}
           end)
  end
end
