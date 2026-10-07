defmodule Ear.RunStoreTest do
  use ExUnit.Case, async: false

  test "list_runs accepts a nonnegative limit" do
    Ear.clear_runs()
    Ear.RunStore.put(%{run_id: "a", status: :completed})
    Ear.RunStore.put(%{run_id: "b", status: :completed})
    assert [%{run_id: "a"}] = Ear.list_runs(1)
    assert [] = Ear.list_runs(0)
    Ear.delete_run("a")
    Ear.delete_run("b")
  end

  test "list_runs rejects invalid limits" do
    assert {:error, :invalid_limit} = Ear.list_runs(-1)
    assert {:error, :invalid_limit} = Ear.list_runs(:all)
  end

  test "lists snapshots in insertion order" do
    {:ok, store} = Ear.RunStore.start_link(max_runs: 10, name: nil)
    Ear.RunStore.put(%{run_id: "z", status: :completed}, store)
    Ear.RunStore.put(%{run_id: "a", status: :completed}, store)

    assert [%{run_id: "z"}, %{run_id: "a"}] = Ear.RunStore.list(:all, store)
    GenServer.stop(store)
  end

  test "a custom store evicts older snapshots" do
    {:ok, store} = Ear.RunStore.start_link(max_runs: 1, name: nil)
    Ear.RunStore.put(%{run_id: "old", status: :completed}, store)
    Ear.RunStore.put(%{run_id: "new", status: :completed}, store)
    assert {:error, :not_found} = Ear.RunStore.get("old", store)
    assert [%{run_id: "new"}] = Ear.RunStore.list(:all, store)
    GenServer.stop(store)
  end
end
