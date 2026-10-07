defmodule Littleagent.RunStoreTest do
  use ExUnit.Case, async: false

  test "list_runs accepts a nonnegative limit" do
    Littleagent.clear_runs()
    Littleagent.RunStore.put(%{run_id: "a", status: :completed})
    Littleagent.RunStore.put(%{run_id: "b", status: :completed})
    assert [%{run_id: "a"}] = Littleagent.list_runs(1)
    assert [] = Littleagent.list_runs(0)
    Littleagent.delete_run("a")
    Littleagent.delete_run("b")
  end

  test "list_runs rejects invalid limits" do
    assert {:error, :invalid_limit} = Littleagent.list_runs(-1)
    assert {:error, :invalid_limit} = Littleagent.list_runs(:all)
  end

  test "lists snapshots in insertion order" do
    {:ok, store} = Littleagent.RunStore.start_link(max_runs: 10, name: nil)
    Littleagent.RunStore.put(%{run_id: "z", status: :completed}, store)
    Littleagent.RunStore.put(%{run_id: "a", status: :completed}, store)

    assert [%{run_id: "z"}, %{run_id: "a"}] = Littleagent.RunStore.list(:all, store)
    GenServer.stop(store)
  end

  test "a custom store evicts older snapshots" do
    {:ok, store} = Littleagent.RunStore.start_link(max_runs: 1, name: nil)
    Littleagent.RunStore.put(%{run_id: "old", status: :completed}, store)
    Littleagent.RunStore.put(%{run_id: "new", status: :completed}, store)
    assert {:error, :not_found} = Littleagent.RunStore.get("old", store)
    assert [%{run_id: "new"}] = Littleagent.RunStore.list(:all, store)
    GenServer.stop(store)
  end
end
