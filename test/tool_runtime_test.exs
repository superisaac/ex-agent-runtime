defmodule Ear.ToolRuntimeTest.BlockingTool do
  def name, do: "blocking"
  def description, do: "Wait for a test signal."
  def validate(_), do: :ok

  def execute(_, %{owner: owner}) do
    send(owner, {:tool_started, self()})

    receive do
      :release -> {:ok, "released"}
    end
  end
end

defmodule Ear.ToolRuntimeTest do
  use ExUnit.Case, async: false
  alias Ear.ToolRuntimeTest.BlockingTool

  defp run_opts(owner) do
    [
      adapter:
        Ear.Model.Scripted.new([
          %{
            tool_calls: [
              %{id: "blocked", name: "blocking", args: %{}},
              %{id: "next", name: "echo", args: "next"}
            ]
          },
          %{text: "done"}
        ]),
      tool_modules: [BlockingTool, Ear.Tools.Echo],
      tool_context: %{owner: owner},
      subscriber: owner,
      tool_timeout_ms: 30_000
    ]
  end

  test "cancel interrupts a blocked tool and does not start the next tool" do
    {:ok, run_id, run} = Ear.start_run("work", run_opts(self()))
    assert_receive {:tool_started, worker}
    worker_ref = Process.monitor(worker)
    run_ref = Process.monitor(run)
    assert {:ok, %{status: :running}} = Ear.get_run(run_id)
    assert :ok = Ear.cancel(run_id)
    assert_receive {:ear, %{run_id: ^run_id, type: :run_cancelled}}, 500
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 500
    assert_receive {:DOWN, ^run_ref, :process, ^run, :normal}, 500

    refute_receive {:ear, %{run_id: ^run_id, type: :tool_call_started, tool_call_id: "next"}}
  end

  test "cancel interrupts a blocked approval callback" do
    owner = self()

    approval = fn _, _ ->
      send(owner, {:approval_started, self()})

      receive do
        :approve -> :allow
      end
    end

    {:ok, run_id, _} =
      Ear.start_run("work", Keyword.put(run_opts(owner), :approve_tool, approval))

    assert_receive {:approval_started, worker}
    worker_ref = Process.monitor(worker)
    assert :ok = Ear.cancel(run_id)
    assert_receive {:ear, %{run_id: ^run_id, type: :run_cancelled}}, 500
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 500
    refute_receive {:tool_started, _}
  end

  test "deadline interrupts a blocked tool before its configured timeout" do
    {:ok, run_id, _} =
      Ear.start_run("work", Keyword.put(run_opts(self()), :max_elapsed_ms, 200))

    assert_receive {:tool_started, worker}
    worker_ref = Process.monitor(worker)

    assert_receive {:ear, %{run_id: ^run_id, type: :run_failed, payload: %{reason: :timeout}}},
                   1000

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 500

    refute_receive {:ear, %{run_id: ^run_id, type: :tool_call_started, tool_call_id: "next"}}
  end

  test "tool timeout records failure and continues the remaining calls" do
    opts = Keyword.put(run_opts(self()), :tool_timeout_ms, 100)
    assert {:ok, %{text: "done"}, events} = Ear.run_with_events("work", opts)

    assert Enum.any?(
             events,
             &(&1.type == :tool_call_failed and &1.payload.result == {:error, :tool_timeout})
           )

    assert Enum.any?(events, &(&1.type == :tool_call_completed and &1.tool_call_id == "next"))
    assert_receive {:tool_started, worker}
    refute Process.alive?(worker)
  end

  test "multiple tools retain call and transcript order" do
    opts = run_opts(self())
    {:ok, run_id, _} = Ear.start_run("work", opts)
    assert_receive {:tool_started, worker}
    send(worker, :release)
    assert_receive {:ear, %{run_id: ^run_id, type: :run_completed}}
    assert {:ok, snapshot} = Ear.get_run(run_id)
    tool_messages = Enum.filter(snapshot.transcript.messages, &(&1.role == :tool))
    assert Enum.map(tool_messages, & &1.tool_call_id) == ["blocked", "next"]

    assert Enum.map(tool_messages, & &1.content) == [
             inspect({:ok, "released"}),
             inspect({:ok, "next"})
           ]
  end
end
