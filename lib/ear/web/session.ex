defmodule Ear.Web.Session do
  @moduledoc "Owns the local web conversation and consumes runtime events."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def state, do: GenServer.call(__MODULE__, :state)
  def prompt(prompt), do: GenServer.call(__MODULE__, {:prompt, prompt})
  def cancel, do: GenServer.call(__MODULE__, :cancel)
  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl true
  def init(opts) do
    {:ok,
     %{
       session: Ear.TUI.Session.new(run_opts: opts, subscriber: self()),
       workspace: opts[:workspace],
       model: model(opts[:adapter]),
       status: :idle,
       messages: [],
       partial: "",
       events: [],
       turns: 0,
       tool_calls: 0,
       usage: %{input: 0, output: 0, cached: 0},
       error: nil
     }}
  end

  @impl true
  def handle_call(:state, _from, state) do
    state = sync_metrics(state)

    public =
      Map.take(state, [
        :workspace,
        :model,
        :status,
        :messages,
        :partial,
        :events,
        :turns,
        :tool_calls,
        :usage,
        :error
      ])

    {:reply, Map.put(public, :run_id, state.session.run_id), state}
  end

  def handle_call({:prompt, prompt}, _from, state) do
    cond do
      state.status == :running ->
        {:reply, {:error, :run_in_progress}, state}

      String.trim(prompt) == "" ->
        {:reply, {:error, :empty_prompt}, state}

      true ->
        {session, result} = Ear.TUI.Session.handle(state.session, {:prompt, prompt})

        if result == :ok do
          state = %{
            state
            | session: session,
              status: :running,
              partial: "",
              events: [],
              turns: 0,
              tool_calls: 0,
              error: nil
          }

          {:reply, :ok, %{state | messages: state.messages ++ [%{role: :user, content: prompt}]}}
        else
          {:reply, result, state}
        end
    end
  end

  def handle_call(:cancel, _from, state) do
    result = if state.status == :running, do: Ear.cancel(state.session.run_id), else: :ok
    {:reply, result, state}
  end

  def handle_call(:clear, _from, %{status: :running} = state),
    do: {:reply, {:error, :run_in_progress}, state}

  def handle_call(:clear, _from, state) do
    {:reply, :ok,
     %{
       state
       | session: %{state.session | run_id: nil},
         status: :idle,
         messages: [],
         partial: "",
         events: [],
         turns: 0,
         tool_calls: 0,
         usage: %{input: 0, output: 0, cached: 0},
         error: nil
     }}
  end

  @impl true
  def handle_info({:ear, %{run_id: run_id} = event}, %{session: %{run_id: run_id}} = state) do
    state = consume(event, state)

    events =
      if event.type == :message_delta do
        state.events
      else
        [Ear.Events.Event.to_map(event) | state.events] |> Enum.take(100)
      end

    {:noreply, %{state | events: events}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp consume(%{type: :message_delta, payload: %{text: text}}, state),
    do: %{state | partial: state.partial <> text}

  defp consume(%{type: :message_completed, payload: %{text: text}}, state),
    do: %{
      state
      | partial: "",
        messages: state.messages ++ [%{role: :assistant, content: text}],
        turns: state.turns + 1
    }

  defp consume(%{type: :tool_call_started}, state),
    do: %{state | tool_calls: state.tool_calls + 1}

  defp consume(%{type: :run_completed, payload: payload}, state) do
    usage = normalize_usage(payload[:usage] || payload["usage"])
    %{state | status: :completed, usage: add_usage(state.usage, usage)}
  end

  defp consume(%{type: :run_cancelled}, state), do: %{state | status: :cancelled}

  defp consume(%{type: :run_failed, payload: payload}, state),
    do: %{state | status: :failed, error: inspect(payload[:reason])}

  defp consume(_event, state), do: state

  defp normalize_usage(nil), do: %{input: 0, output: 0, cached: 0}

  defp normalize_usage(usage) when is_map(usage) do
    details = usage[:prompt_tokens_details] || usage["prompt_tokens_details"] || %{}

    %{
      input: usage_value(usage, [:input_tokens, "input_tokens", :prompt_tokens, "prompt_tokens"]),
      output:
        usage_value(usage, [
          :output_tokens,
          "output_tokens",
          :completion_tokens,
          "completion_tokens"
        ]),
      cached:
        usage_value(details, [:cached_tokens, "cached_tokens"], nil) ||
          usage_value(
            usage,
            [
              :cached_tokens,
              "cached_tokens",
              :cache_read_input_tokens,
              "cache_read_input_tokens"
            ],
            0
          )
    }
  end

  defp normalize_usage(_usage), do: %{input: 0, output: 0, cached: 0}

  defp usage_value(usage, keys, default \\ 0),
    do: Enum.find_value(keys, default, &Map.get(usage, &1))

  defp add_usage(total, current) do
    %{
      input: total.input + current.input,
      output: total.output + current.output,
      cached: total.cached + current.cached
    }
  end

  defp sync_metrics(%{session: %{run_id: nil}} = state), do: state

  defp sync_metrics(state) do
    case Ear.get_run(state.session.run_id) do
      {:ok, run} -> %{state | turns: run.turns, tool_calls: run.tool_calls}
      _ -> state
    end
  end

  defp model(%{model: model}), do: model
  defp model(_), do: "Custom adapter"
end
