defmodule Littleagent.RuntimeTest do
  use ExUnit.Case, async: false
  alias Littleagent.TestSupport.BlockingAdapter, as: Blocking

  test "synchronous wrappers return validation errors" do
    assert {:error, :empty_prompt} = Littleagent.run(" ")
    assert {:error, :invalid_limit} = Littleagent.run_with_events("test", timeout: -1)
    assert {:error, :invalid_tool_context} = Littleagent.run("test", tool_context: :bad)
    assert {:error, :invalid_workspace} = Littleagent.run("test", workspace: :bad)
    assert {:error, :invalid_approval_callback} = Littleagent.run("test", approve_tool: :bad)
    assert {:error, :invalid_skills} = Littleagent.run("test", skills: [:coding])
    assert {:error, :invalid_skill_roots} = Littleagent.run("test", skill_roots: [:cwd])
    assert {:error, :invalid_messages} = Littleagent.run("test", messages: :bad)
    assert {:error, :invalid_run_id} = Littleagent.run("test", run_id: "")
    assert {:error, :invalid_adapter} = Littleagent.run("test", adapter: nil)
    assert {:error, :invalid_adapter} = Littleagent.run("test", adapter: 42)
  end

  test "event collection leaves other runs' events in the mailbox" do
    unrelated = Littleagent.Events.Event.new("other-run", 1, :run_completed, %{text: "other"})
    send(self(), {:littleagent, unrelated})

    assert {:ok, %{text: "own"}, events} =
             Littleagent.run_with_events("test",
               adapter: Littleagent.Model.Scripted.new([%{text: "own"}])
             )

    assert Enum.all?(events, &(&1.run_id != "other-run"))
    assert_receive {:littleagent, ^unrelated}
  end

  test "caller timeout cancels the run and stops its model worker" do
    assert {:error, %{reason: :timeout}, events} =
             Littleagent.run_with_events("test", adapter: %Blocking{owner: self()}, timeout: 100)

    assert_receive {:model_started, worker}
    monitor = Process.monitor(worker)
    run_id = hd(events).run_id
    assert_receive {:littleagent, %{run_id: ^run_id, type: :run_cancelled}}
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
  end

  test "cancels a blocked model request and stops its worker" do
    {:ok, run_id, run_pid} =
      Littleagent.start_run("test", adapter: %Blocking{owner: self()}, subscriber: self())

    assert_receive {:model_started, worker}
    monitor = Process.monitor(worker)
    run_monitor = Process.monitor(run_pid)

    assert {:ok, %{run_id: ^run_id, status: :running, turns: 0, tool_calls: 0}} =
             Littleagent.get_run(run_id)

    assert :ok = Littleagent.cancel(run_id)
    assert_receive {:littleagent, %{run_id: ^run_id, type: :run_cancelled}}
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    assert_receive {:DOWN, ^run_monitor, :process, ^run_pid, :normal}
    refute_receive {:littleagent, %{run_id: ^run_id, type: :run_completed}}
  end

  test "deadline interrupts a blocked model request" do
    {:ok, run_id, _pid} =
      Littleagent.start_run("test",
        adapter: %Blocking{owner: self()},
        subscriber: self(),
        max_elapsed_ms: 100
      )

    assert_receive {:model_started, worker}
    monitor = Process.monitor(worker)

    assert_receive {:littleagent,
                    %{run_id: ^run_id, type: :run_failed, payload: %{reason: :timeout}}},
                   1000

    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
  end
end
