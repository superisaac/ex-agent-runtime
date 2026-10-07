defmodule Ear.RunStore do
  @moduledoc "Supervised in-memory storage with a bounded number of run snapshots."
  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def put(snapshot, server \\ __MODULE__), do: GenServer.call(server, {:put, snapshot})
  def get(run_id, server \\ __MODULE__), do: GenServer.call(server, {:get, run_id})
  def list(limit \\ :all, server \\ __MODULE__), do: GenServer.call(server, {:list, limit})
  def delete(run_id, server \\ __MODULE__), do: GenServer.call(server, {:delete, run_id})
  def clear(server \\ __MODULE__), do: GenServer.call(server, :clear)

  @impl true
  def init(opts) do
    max_runs =
      Keyword.get(opts, :max_runs, Application.get_env(:ear, :max_stored_runs, 1000))

    if is_integer(max_runs) and max_runs >= 0 do
      table = :ets.new(:ear_runs, [:protected, read_concurrency: true])
      {:ok, %{table: table, max_runs: max_runs, order: []}}
    else
      {:stop, :invalid_max_stored_runs}
    end
  end

  @impl true
  def handle_call({:put, %{run_id: id} = snapshot}, _from, state) do
    :ets.insert(state.table, {id, snapshot})
    order = Enum.reject(state.order, &(&1 == id)) ++ [id]
    {expired, retained} = Enum.split(order, max(length(order) - state.max_runs, 0))
    Enum.each(expired, &:ets.delete(state.table, &1))
    {:reply, :ok, %{state | order: retained}}
  end

  def handle_call({:get, id}, _from, state) do
    result =
      case :ets.lookup(state.table, id) do
        [{^id, snapshot}] -> {:ok, snapshot}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  def handle_call({:list, limit}, _from, state) do
    if limit != :all and not (is_integer(limit) and limit >= 0) do
      {:reply, {:error, :invalid_limit}, state}
    else
      ids = state.order
      ids = if limit == :all, do: ids, else: Enum.take(ids, limit)

      snapshots =
        Enum.map(ids, fn id ->
          [{^id, snapshot}] = :ets.lookup(state.table, id)
          snapshot
        end)

      {:reply, snapshots, state}
    end
  end

  def handle_call({:delete, id}, _from, state) do
    :ets.delete(state.table, id)
    {:reply, true, %{state | order: Enum.reject(state.order, &(&1 == id))}}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, %{state | order: []}}
  end
end
