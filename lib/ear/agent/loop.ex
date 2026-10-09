defmodule Ear.Agent.Loop do
  use GenServer
  alias Ear.{Conversation.Message, Conversation.Transcript, Events.Event}

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :run_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  def start_link(opts),
    do:
      GenServer.start_link(__MODULE__, opts,
        name: {:via, Registry, {Ear.RunRegistry, Keyword.fetch!(opts, :run_id)}}
      )

  def subscribe(pid, subscriber), do: GenServer.cast(pid, {:subscribe, subscriber})
  def unsubscribe(pid, subscriber), do: GenServer.cast(pid, {:unsubscribe, subscriber})
  def cancel(pid), do: GenServer.cast(pid, :cancel)
  def snapshot(pid), do: GenServer.call(pid, :snapshot)
  @impl true
  def init(opts) do
    request = Keyword.fetch!(opts, :request)

    transcript =
      case request[:messages] do
        messages when is_list(messages) and messages != [] -> %Transcript{messages: messages}
        _ -> Transcript.append(Transcript.new(), Message.new(:user, request[:prompt] || ""))
      end

    state = %{
      run_id: Keyword.fetch!(opts, :run_id),
      adapter: Keyword.fetch!(opts, :adapter),
      request: request,
      transcript: transcript,
      tools: Keyword.get(opts, :tools, %{}),
      workspace: Keyword.get(opts, :workspace, File.cwd!()),
      tool_context: Keyword.get(opts, :tool_context, %{}),
      stream: Keyword.get(opts, :stream, false),
      subscribers: MapSet.new(),
      subscriber_refs: %{},
      seq: 0,
      status: :running,
      cancelled: false,
      turns: 0,
      max_turns: opts[:max_turns] || 8,
      tool_calls: 0,
      max_tool_calls: opts[:max_tool_calls] || 16,
      max_output_chars: opts[:max_output_chars] || 100_000,
      tool_timeout_ms: opts[:tool_timeout_ms] || 30_000,
      started_at: System.monotonic_time(:millisecond),
      max_elapsed_ms: opts[:max_elapsed_ms],
      allowed_tools: opts[:allowed_tools] || :all,
      approve_tool: Keyword.get(opts, :approve_tool, fn _name, _args -> :allow end),
      deadline_ref: nil,
      model_task: nil,
      stream_token: nil,
      stream_chunks: [],
      stream_text_emitted: false,
      tool_task: nil,
      tool_timer: nil,
      tool_token: nil,
      tool_phase: nil,
      current_tool: nil,
      pending_tools: [],
      tool_results: [],
      deadline_expired: opts[:max_elapsed_ms] == 0
    }

    state =
      opts
      |> Keyword.get(:subscriber)
      |> List.wrap()
      |> Enum.filter(&is_pid/1)
      |> Enum.reduce(state, fn subscriber, acc -> add_subscriber(acc, subscriber) end)

    state = emit_to_subscribers(state, :run_started, %{run_id: state.run_id})

    state =
      Enum.reduce(Keyword.get(opts, :request)[:skills] || [], state, fn name, acc ->
        emit_to_subscribers(acc, :skill_loaded, %{name: name})
      end)

    state =
      Enum.reduce(Keyword.get(opts, :request)[:skill_errors] || [], state, fn error, acc ->
        emit_to_subscribers(acc, :skill_error, %{error: error})
      end)

    state = schedule_deadline(state, opts[:max_elapsed_ms])
    send(self(), :run)
    {:ok, state}
  end

  @impl true
  def handle_cast({:subscribe, subscriber}, state),
    do: {:noreply, add_subscriber(state, subscriber)}

  def handle_cast({:unsubscribe, subscriber}, state),
    do: {:noreply, remove_subscriber(state, subscriber)}

  def handle_cast(:cancel, state), do: finish(state, :run_cancelled, %{reason: :cancelled})
  @impl true
  def handle_call(:snapshot, _from, state),
    do: {:reply, Map.take(state, [:run_id, :status, :turns, :tool_calls]), state}

  @impl true
  def handle_info(:run, %{cancelled: true} = state),
    do: finish(state, :run_cancelled, %{reason: :cancelled})

  def handle_info(:run, %{deadline_expired: true} = state),
    do: finish(state, :run_failed, %{reason: :timeout})

  def handle_info(:deadline, state),
    do: finish(state, :run_failed, %{reason: :timeout})

  def handle_info(:run, %{turns: turns, max_turns: max} = state) when turns >= max,
    do: finish(state, :run_failed, %{reason: :max_turns})

  def handle_info(:run, state) do
    token = make_ref()
    owner = self()

    task =
      Task.Supervisor.async_nolink(Ear.TaskSupervisor, fn ->
        invoke_adapter_with_context(state, token, owner)
      end)

    {:noreply, %{state | model_task: task, stream_token: token, stream_chunks: []}}
  end

  def handle_info({:model_stream_chunk, token, chunks}, %{stream_token: token} = state) do
    if valid_chunks?(chunks) do
      receive_stream_chunks(chunks, state)
    else
      finish(state, :run_failed, %{reason: :malformed_model_response})
    end
  end

  def handle_info({:model_stream_chunk, _token, _chunks}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{model_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    streamed_chunks = state.stream_chunks
    state = %{state | model_task: nil, stream_token: nil}

    case result do
      {:ok, response, adapter} ->
        dispatch_response(
          response,
          %{state | adapter: adapter, turns: state.turns + 1},
          streamed_chunks
        )

      {:ok, response} ->
        dispatch_response(response, %{state | turns: state.turns + 1}, streamed_chunks)

      {:error, reason} ->
        finish(state, :run_failed, %{reason: reason})

      _ ->
        finish(state, :run_failed, %{reason: :malformed_adapter_response})
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{model_task: %Task{ref: ref}} = state),
    do: finish(%{state | model_task: nil}, :run_failed, %{reason: :adapter_crashed})

  def handle_info({ref, result}, %{tool_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    complete_tool(%{state | tool_task: nil}, result)
  end

  def handle_info({:tool_execution, token}, %{tool_token: token} = state),
    do: {:noreply, %{state | tool_phase: :execution}}

  def handle_info({:tool_timeout, token}, %{tool_token: token, tool_task: %Task{} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    reason = if state.tool_phase == :approval, do: :tool_denied, else: :tool_timeout
    complete_tool(%{state | tool_task: nil}, {:error, reason})
  end

  def handle_info({:tool_timeout, _token}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{tool_task: %Task{ref: ref}} = state) do
    result =
      if state.tool_phase == :approval,
        do: {:error, :tool_denied},
        else: {:error, {:exit, reason}}

    complete_tool(%{state | tool_task: nil}, result)
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.subscriber_refs, pid) do
      ^ref -> {:noreply, remove_subscriber(state, pid)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({_ref, _result}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.deadline_ref, do: Process.cancel_timer(state.deadline_ref)
    if state.model_task, do: Task.shutdown(state.model_task, :brutal_kill)
    if state.tool_timer, do: Process.cancel_timer(state.tool_timer)
    if state.tool_task, do: Task.shutdown(state.tool_task, :brutal_kill)
    :ok
  end

  defp receive_stream_chunks(chunks, state) do
    text_size = stream_text_size(chunks)
    current_size = stream_text_size(state.stream_chunks)

    if current_size + text_size > state.max_output_chars do
      finish(state, :run_failed, %{reason: :max_output_chars, size: current_size + text_size})
    else
      state =
        case Enum.map_join(chunks, "", fn
               %{type: :text_delta, text: text} -> text
               _ -> ""
             end) do
          "" -> state
          text -> emit_to_subscribers(state, :message_delta, %{text: text})
        end

      {:noreply,
       %{
         state
         | stream_chunks: state.stream_chunks ++ chunks,
           stream_text_emitted: state.stream_text_emitted or text_size > 0
       }}
    end
  end

  defp stream_text_size(chunks) do
    Enum.reduce(chunks, 0, fn
      %{type: :text_delta, text: text}, size -> size + String.length(text)
      _, size -> size
    end)
  end

  defp invoke_adapter_with_context(state, token, owner),
    do:
      invoke_adapter(state, %{
        run_id: state.run_id,
        workspace: state.workspace,
        tool_context: state.tool_context,
        stream_owner: owner,
        stream_token: token
      })

  defp invoke_adapter(%{adapter: module, request: request, stream: true}, context)
       when is_atom(module) do
    Code.ensure_loaded(module)

    if function_exported?(module, :stream, 3),
      do: module.stream(module, request, context),
      else: invoke_module_complete(module, request, context)
  end

  defp invoke_adapter(%{adapter: module, request: request}, context) when is_atom(module),
    do: invoke_module_complete(module, request, context)

  defp invoke_adapter(
         %{adapter: %{__struct__: module} = adapter, request: request, stream: true},
         context
       ) do
    Code.ensure_loaded(module)

    if function_exported?(module, :stream, 3),
      do: apply(module, :stream, [adapter, request, context]),
      else: apply(module, :complete, [adapter, request, context])
  end

  defp invoke_adapter(%{adapter: %{__struct__: module} = adapter, request: request}, context) do
    apply(module, :complete, [adapter, request, context])
  end

  defp invoke_adapter(_, _), do: {:error, :invalid_adapter}

  defp invoke_module_complete(module, request, context) do
    Code.ensure_loaded(module)

    cond do
      function_exported?(module, :complete, 3) -> module.complete(module, request, context)
      function_exported?(module, :complete, 2) -> module.complete(request, context)
      true -> {:error, :invalid_adapter}
    end
  end

  defp dispatch_response(response, state, streamed_chunks) do
    if valid_response?(response) do
      dispatch_valid_response(response, state, streamed_chunks)
    else
      finish(state, :run_failed, %{reason: :malformed_model_response})
    end
  end

  defp dispatch_valid_response(response, state, streamed_chunks)

  defp dispatch_valid_response(%{tool_calls: calls} = response, state, _streamed_chunks)
       when is_list(calls) and calls != [],
       do: handle_tool_response(calls, state, response[:text] || "")

  defp dispatch_valid_response(%{chunks: chunks}, state, streamed_chunks) when is_list(chunks),
    do:
      handle_chunk_response(
        if(streamed_chunks == [], do: chunks, else: streamed_chunks),
        state,
        streamed_chunks == []
      )

  defp dispatch_valid_response(%{text: _text}, state, streamed_chunks) when streamed_chunks != [],
    do: handle_chunk_response(streamed_chunks, state, false)

  defp dispatch_valid_response(response, state, _streamed_chunks),
    do: handle_response(response, state)

  defp handle_tool_response(calls, state, text) do
    cond do
      not valid_tool_calls?(calls) ->
        finish(state, :run_failed, %{reason: :malformed_model_response})

      String.length(text) > state.max_output_chars ->
        finish(state, :run_failed, %{reason: :max_output_chars, size: String.length(text)})

      state.tool_calls + length(calls) > state.max_tool_calls ->
        finish(state, :run_failed, %{reason: :max_tool_calls})

      true ->
        handle_tool_calls(calls, %{state | tool_calls: state.tool_calls + length(calls)}, text)
    end
  end

  defp handle_tool_calls(calls, state, assistant_text) do
    state =
      if assistant_text != "" and not state.stream_text_emitted do
        emit_to_subscribers(state, :message_delta, %{text: assistant_text})
      else
        state
      end

    state = %{
      state
      | transcript:
          Transcript.append(
            state.transcript,
            Message.new(:assistant, assistant_text, tool_calls: calls)
          )
    }

    next_tool(%{
      state
      | pending_tools: calls,
        tool_results: [],
        stream_text_emitted: false,
        stream_chunks: []
    })
  end

  defp next_tool(%{pending_tools: [call | rest]} = state) do
    if elapsed?(state) do
      finish(state, :run_failed, %{reason: :timeout})
    else
      name = call[:name] || call["name"]
      args = call[:args] || call["args"]
      id = call[:id] || call["id"] || "tool"
      state = emit_to_subscribers(state, :tool_call_started, %{name: name}, tool_call_id: id)
      owner = self()
      token = make_ref()

      task =
        Task.Supervisor.async_nolink(Ear.TaskSupervisor, fn ->
          if tool_allowed?(state.allowed_tools, name) and
               tool_approved?(state.approve_tool, name, args) do
            send(owner, {:tool_execution, token})

            Ear.Tools.Executor.execute(
              state.tools,
              name,
              args,
              Map.merge(state.tool_context, %{run_id: state.run_id, workspace: state.workspace})
            )
          else
            {:error, :tool_denied}
          end
        end)

      timer = Process.send_after(self(), {:tool_timeout, token}, state.tool_timeout_ms)

      {:noreply,
       %{
         state
         | pending_tools: rest,
           current_tool: call,
           tool_task: task,
           tool_token: token,
           tool_timer: timer,
           tool_phase: :approval
       }}
    end
  end

  defp next_tool(%{pending_tools: []} = state) do
    state = %{
      state
      | request:
          refresh_request(state.request, state.transcript, Enum.reverse(state.tool_results))
    }

    if elapsed?(state) do
      finish(state, :run_failed, %{reason: :timeout})
    else
      if state.turns >= state.max_turns do
        finish(state, :run_failed, %{reason: :max_turns})
      else
        send(self(), :run)
        {:noreply, state}
      end
    end
  end

  defp complete_tool(state, result) do
    if state.tool_timer, do: Process.cancel_timer(state.tool_timer)
    call = state.current_tool
    id = call[:id] || call["id"] || "tool"
    name = call[:name] || call["name"]
    result = bound_tool_result(result, state.max_output_chars)
    type = if match?({:ok, _}, result), do: :tool_call_completed, else: :tool_call_failed
    state = emit_to_subscribers(state, type, %{name: name, result: result}, tool_call_id: id)

    transcript =
      Transcript.append(state.transcript, Message.new(:tool, inspect(result), tool_call_id: id))

    next_tool(%{
      state
      | transcript: transcript,
        tool_results: [result | state.tool_results],
        current_tool: nil,
        tool_timer: nil,
        tool_token: nil,
        tool_phase: nil
    })
  end

  defp handle_chunk_response(chunks, state, emit_text?) do
    tool_calls = merge_tool_call_chunks(chunks)

    if tool_calls != [] do
      text =
        Enum.map_join(chunks, "", fn
          %{type: :text_delta, text: value} -> value
          _ -> ""
        end)

      handle_tool_response(tool_calls, state, text)
    else
      text =
        Enum.map_join(chunks, "", fn
          %{type: :text_delta, text: value} -> value
          _ -> ""
        end)

      if String.length(text) > state.max_output_chars do
        finish(state, :run_failed, %{reason: :max_output_chars, size: String.length(text)})
      else
        state =
          if emit_text? do
            Enum.reduce(chunks, state, fn
              %{type: :text_delta, text: value}, acc ->
                emit_to_subscribers(acc, :message_delta, %{text: value})

              _, acc ->
                acc
            end)
          else
            state
          end

        transcript = Transcript.append(state.transcript, Message.new(:assistant, text))
        state = emit_to_subscribers(state, :message_completed, %{text: text})

        payload = %{text: text}

        payload =
          if usage = usage_from_chunks(chunks), do: Map.put(payload, :usage, usage), else: payload

        finish(
          %{
            state
            | transcript: transcript,
              stream_chunks: [],
              request: refresh_request(state.request, transcript, nil)
          },
          :run_completed,
          payload
        )
      end
    end
  end

  defp merge_tool_call_chunks(chunks) do
    chunks
    |> Enum.filter(&(&1[:type] == :tool_call_delta))
    |> Enum.group_by(& &1[:index])
    |> Enum.sort_by(fn {index, _} -> index end)
    |> Enum.map(fn {_index, parts} ->
      args = Enum.map_join(parts, & &1[:arguments])

      %{
        id: Enum.find_value(parts, & &1[:id]),
        name: Enum.find_value(parts, & &1[:name]),
        args: decode_tool_arguments(args)
      }
    end)
  end

  defp usage_from_chunks(chunks) do
    case Enum.find(chunks, &(&1[:type] == :usage)) do
      %{usage: usage} when is_map(usage) -> usage
      _ -> nil
    end
  end

  defp decode_tool_arguments(value) do
    case :json.decode(value) do
      decoded when is_map(decoded) -> decoded
      _ -> value
    end
  rescue
    _ -> value
  end

  defp handle_response(%{text: text} = response, state) do
    text = text || ""

    if String.length(text) > state.max_output_chars do
      finish(state, :run_failed, %{reason: :max_output_chars, size: String.length(text)})
    else
      state = emit_to_subscribers(state, :message_delta, %{text: text})
      transcript = Transcript.append(state.transcript, Message.new(:assistant, text))
      state = emit_to_subscribers(state, :message_completed, %{text: text})

      finish(
        %{
          state
          | transcript: transcript,
            stream_chunks: [],
            request: refresh_request(state.request, transcript, nil)
        },
        :run_completed,
        Map.take(response, [:text, :usage, :finish_reason])
      )
    end
  end

  defp handle_response(_, state),
    do: finish(state, :run_failed, %{reason: :malformed_model_response})

  defp finish(state, type, payload) do
    {state, payload} = preserve_partial_response(state, type, payload)
    event = Event.new(state.run_id, state.seq + 1, type, payload)

    snapshot =
      Map.take(%{state | status: type_to_status(type), seq: event.seq}, [
        :run_id,
        :status,
        :turns,
        :tool_calls,
        :transcript
      ])

    Ear.RunStore.put(snapshot)
    Enum.each(state.subscribers, &send(&1, {:ear, event}))
    {:stop, :normal, %{state | status: type_to_status(type), seq: event.seq}}
  end

  defp preserve_partial_response(state, :run_completed, payload), do: {state, payload}

  defp preserve_partial_response(%{stream_chunks: []} = state, _type, payload),
    do: {state, payload}

  defp preserve_partial_response(state, _type, payload) do
    text =
      Enum.map_join(state.stream_chunks, "", fn
        %{type: :text_delta, text: text} -> text
        _ -> ""
      end)

    tool_deltas = Enum.filter(state.stream_chunks, &(&1.type == :tool_call_delta))

    if text == "" and tool_deltas == [] do
      {state, payload}
    else
      message =
        Message.new(:assistant, text,
          metadata: %{partial: true, reason: payload[:reason], tool_call_deltas: tool_deltas}
        )

      state = %{
        state
        | transcript: Transcript.append(state.transcript, message),
          stream_chunks: []
      }

      state = emit_to_subscribers(state, :message_completed, %{text: text, partial: true})
      partial = %{text: text, message_id: message.id, tool_call_deltas: tool_deltas}
      {state, Map.put(payload, :partial_result, partial)}
    end
  end

  defp valid_response?(response) when is_map(response) do
    recognized? =
      Map.has_key?(response, :text) or Map.has_key?(response, :chunks) or
        (is_list(response[:tool_calls]) and response[:tool_calls] != [])

    recognized? and
      (not Map.has_key?(response, :text) or is_binary(response[:text])) and
      (not Map.has_key?(response, :chunks) or valid_chunks?(response[:chunks])) and
      (not Map.has_key?(response, :tool_calls) or valid_tool_calls?(response[:tool_calls]))
  end

  defp valid_response?(_), do: false

  defp valid_tool_calls?(calls) when is_list(calls) do
    Enum.all?(calls, fn
      call when is_map(call) ->
        id = call[:id] || call["id"]
        name = call[:name] || call["name"]

        is_binary(id) and id != "" and is_binary(name) and name != "" and
          (Map.has_key?(call, :args) or Map.has_key?(call, "args"))

      _ ->
        false
    end) and
      length(calls) == length(Enum.uniq_by(calls, &(&1[:id] || &1["id"])))
  end

  defp valid_tool_calls?(_), do: false

  defp valid_chunks?(chunks) when is_list(chunks), do: Enum.all?(chunks, &valid_chunk?/1)
  defp valid_chunks?(_), do: false

  defp valid_chunk?(%{type: :text_delta, text: text}), do: is_binary(text)

  defp valid_chunk?(%{type: :tool_call_delta, index: index, arguments: arguments} = chunk) do
    is_integer(index) and index >= 0 and is_binary(arguments) and
      Enum.all?([:id, :name], &(is_nil(chunk[&1]) or is_binary(chunk[&1])))
  end

  defp valid_chunk?(%{type: :usage, usage: usage}), do: is_map(usage)
  defp valid_chunk?(%{type: :finish_reason, reason: reason}), do: is_binary(reason)
  defp valid_chunk?(%{type: :provider_metadata, metadata: metadata}), do: is_map(metadata)
  defp valid_chunk?(_), do: false

  defp emit_to_subscribers(state, type, payload),
    do: emit_to_subscribers(state, type, payload, [])

  defp emit_to_subscribers(state, type, payload, attrs) do
    event = Event.new(state.run_id, state.seq + 1, type, payload, attrs)
    Enum.each(state.subscribers, &send(&1, {:ear, event}))
    %{state | seq: event.seq}
  end

  defp add_subscriber(state, subscriber) do
    if is_pid(subscriber) and Map.has_key?(state.subscriber_refs, subscriber) do
      state
    else
      ref = Process.monitor(subscriber)

      %{
        state
        | subscribers: MapSet.put(state.subscribers, subscriber),
          subscriber_refs: Map.put(state.subscriber_refs, subscriber, ref)
      }
    end
  end

  defp remove_subscriber(state, subscriber) do
    case Map.pop(state.subscriber_refs, subscriber) do
      {nil, _} ->
        state

      {ref, refs} ->
        Process.demonitor(ref, [:flush])

        %{
          state
          | subscribers: MapSet.delete(state.subscribers, subscriber),
            subscriber_refs: refs
        }
    end
  end

  defp refresh_request(request, transcript, results) do
    request
    |> Map.put(:messages, Transcript.to_list(transcript))
    |> then(fn request ->
      if results, do: Map.put(request, :tool_results, results), else: request
    end)
  end

  defp schedule_deadline(state, nil), do: state

  defp schedule_deadline(state, milliseconds)
       when is_integer(milliseconds) and milliseconds >= 0 do
    %{state | deadline_ref: Process.send_after(self(), :deadline, milliseconds)}
  end

  defp schedule_deadline(state, _), do: state

  defp tool_allowed?(:all, _name), do: true
  defp tool_allowed?(allowed, name) when is_list(allowed), do: name in allowed
  defp tool_allowed?(_, _), do: false

  defp tool_approved?(approval, name, args) when is_function(approval, 2) do
    approval.(name, args) in [:allow, true]
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp tool_approved?(_, _, _), do: false

  defp elapsed?(%{max_elapsed_ms: nil}), do: false

  defp elapsed?(state),
    do: System.monotonic_time(:millisecond) - state.started_at >= state.max_elapsed_ms

  defp bound_tool_result({:ok, value}, limit) do
    text = inspect(value)

    if String.length(text) > limit,
      do: {:ok, String.slice(text, 0, limit) <> "…"},
      else: {:ok, value}
  end

  defp bound_tool_result(result, _limit), do: result

  defp type_to_status(:run_completed), do: :completed
  defp type_to_status(:run_cancelled), do: :cancelled
  defp type_to_status(_), do: :failed
end
