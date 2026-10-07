defmodule Ear.PartialResponseTest.Adapter do
  defstruct [:owner, chunks: [%{type: :text_delta, text: "hello"}]]

  def complete(_adapter, _request, _context), do: {:error, :stream_required}

  def stream(adapter, _request, context) do
    send(context.stream_owner, {:model_stream_chunk, context.stream_token, adapter.chunks})
    send(adapter.owner, {:stream_worker, self()})
    await_result(context)
  end

  defp await_result(context) do
    receive do
      {:return, result} ->
        result

      {:emit, chunks} ->
        send(context.stream_owner, {:model_stream_chunk, context.stream_token, chunks})
        await_result(context)

      :crash ->
        Process.exit(self(), :kill)
    end
  end
end

defmodule Ear.PartialResponseTest do
  use ExUnit.Case, async: false
  alias Ear.{Conversation.Transcript, Events.Event}
  alias Ear.PartialResponseTest.Adapter

  test "cancellation preserves streamed text in the snapshot and terminal event" do
    {run_id, worker} = start_stream()
    monitor = Process.monitor(worker)
    assert :ok = Ear.cancel(run_id)
    assert_partial(run_id, :run_cancelled, :cancelled)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
  end

  test "provider failure preserves text received before the error" do
    {run_id, worker} = start_stream()
    send(worker, {:return, {:error, :provider_unavailable}})
    assert_partial(run_id, :run_failed, :provider_unavailable)
  end

  test "multiple live batches are accumulated in order" do
    {run_id, worker} = start_stream()
    send(worker, {:emit, [%{type: :text_delta, text: " world"}]})
    assert_receive {:ear, %{run_id: ^run_id, type: :message_delta, payload: %{text: " world"}}}
    send(worker, {:return, {:error, :provider_unavailable}})
    assert_partial(run_id, :run_failed, :provider_unavailable, "hello world")
  end

  test "malformed adapter return preserves text received before the error" do
    {run_id, worker} = start_stream()
    send(worker, {:return, :invalid_return})
    assert_partial(run_id, :run_failed, :malformed_adapter_response)
  end

  test "model worker crash preserves streamed text" do
    {run_id, worker} = start_stream()
    send(worker, :crash)
    assert_partial(run_id, :run_failed, :adapter_crashed)
  end

  test "elapsed deadline preserves streamed text" do
    {run_id, _worker} = start_stream(max_elapsed_ms: 200)
    assert_partial(run_id, :run_failed, :timeout)
  end

  test "output limit preserves accepted chunks without emitting the oversized chunk" do
    {run_id, worker} = start_stream(max_output_chars: 5)
    send(worker, {:emit, [%{type: :text_delta, text: "overflow"}]})
    events = assert_partial(run_id, :run_failed, :max_output_chars)
    refute Enum.any?(events, &(&1.type == :message_delta))
  end

  test "invalid live chunks fail safely and retain prior text" do
    for chunks <- [:invalid, [%{type: :text_delta, text: 42}], [%{type: :unknown}], [nil]] do
      {run_id, worker} = start_stream()
      send(worker, {:emit, chunks})
      assert_partial(run_id, :run_failed, :malformed_model_response)
    end
  end

  test "malformed successful responses are failures rather than empty completions" do
    for response <- [
          %{},
          :invalid,
          %{text: 42},
          %{text: nil},
          %{chunks: :invalid},
          %{chunks: [%{type: :text_delta, text: nil}]},
          %{tool_calls: [nil]},
          %{tool_calls: [%{id: "one", name: "echo"}]},
          %{tool_calls: [%{id: "", name: "echo", args: "x"}]},
          %{tool_calls: [%{id: "one", name: nil, args: "x"}]},
          %{tool_calls: List.duplicate(%{id: "one", name: "echo", args: "x"}, 2)}
        ] do
      assert {:error, %{reason: :malformed_model_response}, events} =
               Ear.run_with_events("test", adapter: Ear.Model.Scripted.new([response]))

      assert Enum.count(events, &Event.terminal?/1) == 1
      refute Enum.any?(events, &(&1.type == :tool_call_started))
      run_id = hd(events).run_id
      assert {:ok, %{status: :failed}} = Ear.get_run(run_id)
    end
  end

  test "malformed final response retains text already delivered by the live stream" do
    {run_id, worker} = start_stream()
    send(worker, {:return, {:ok, %{}}})
    assert_partial(run_id, :run_failed, :malformed_model_response)
  end

  test "incomplete tool deltas are preserved without executing them" do
    delta = %{type: :tool_call_delta, index: 0, id: "call", arguments: "{\"path\":"}
    adapter = %Adapter{owner: self(), chunks: [%{type: :text_delta, text: "hello"}, delta]}
    {run_id, worker} = start_stream(adapter: adapter)
    send(worker, {:return, {:ok, %{chunks: adapter.chunks}}})
    events = assert_partial(run_id, :run_failed, :malformed_model_response)
    assert List.last(events).payload.partial_result.tool_call_deltas == [delta]
    refute Enum.any?(events, &(&1.type == :tool_call_started))
  end

  test "a stream containing only tool fragments is preserved on failure" do
    delta = %{type: :tool_call_delta, index: 0, id: "call", arguments: "{"}
    adapter = %Adapter{owner: self(), chunks: [delta]}

    assert {:ok, run_id, _pid} =
             Ear.start_run("test", adapter: adapter, stream: true, subscriber: self())

    assert_receive {:stream_worker, worker}
    send(worker, {:return, {:error, :provider_unavailable}})
    events = assert_partial(run_id, :run_failed, :provider_unavailable, "")
    assert List.last(events).payload.partial_result.tool_call_deltas == [delta]
    refute Enum.any?(events, &(&1.type == :tool_call_started))
  end

  test "tool continuation does not duplicate the prior streamed assistant message" do
    {run_id, worker} = start_stream(tools: Ear.Tools.Registry.new([Ear.Tools.Echo]))

    send(worker, {
      :return,
      {:ok, %{text: "hello", tool_calls: [%{id: "call", name: "echo", args: "result"}]}}
    })

    assert_receive {:ear, %{run_id: ^run_id, type: :tool_call_completed}}
    assert_receive {:stream_worker, next_worker}
    assert_receive {:ear, %{run_id: ^run_id, type: :message_delta, payload: %{text: "hello"}}}
    send(next_worker, {:return, {:error, :provider_unavailable}})
    events = collect_terminal(run_id)
    assert List.last(events).payload.partial_result.text == "hello"
    assert {:ok, %{transcript: transcript}} = Ear.get_run(run_id)
    messages = Transcript.to_list(transcript)
    assert Enum.map(messages, & &1.role) == [:user, :assistant, :tool, :assistant]
    refute Enum.at(messages, 1).metadata[:partial]
    assert List.last(messages).metadata.partial
  end

  test "successful streams are stored once without partial metadata" do
    {run_id, worker} = start_stream()
    send(worker, {:return, {:ok, %{text: "hello"}}})
    events = collect_terminal(run_id)
    assert List.last(events).type == :run_completed
    refute Map.has_key?(List.last(events).payload, :partial_result)
    assert {:ok, %{transcript: transcript}} = Ear.get_run(run_id)
    assert Enum.map(Transcript.to_list(transcript), & &1.content) == ["test", "hello"]
    refute Transcript.last(transcript).metadata[:partial]
  end

  test "empty text remains a valid explicit completion" do
    assert {:ok, %{text: ""}} =
             Ear.run("test", adapter: Ear.Model.Scripted.new([%{text: ""}]))
  end

  defp start_stream(opts \\ []) do
    opts =
      Keyword.merge(
        [adapter: %Adapter{owner: self()}, stream: true, subscriber: self()],
        opts
      )

    assert {:ok, run_id, _pid} = Ear.start_run("test", opts)
    assert_receive {:stream_worker, worker}, 1_000

    assert_receive {:ear, %{run_id: ^run_id, type: :message_delta, payload: %{text: "hello"}}},
                   1_000

    {run_id, worker}
  end

  defp assert_partial(run_id, type, reason, text \\ "hello") do
    events = collect_terminal(run_id)
    terminal = List.last(events)
    assert terminal.type == type
    assert terminal.payload.reason == reason
    assert %{text: ^text, message_id: message_id} = terminal.payload.partial_result
    assert Enum.count(events, &Event.terminal?/1) == 1
    seqs = Enum.map(events, & &1.seq)
    assert seqs == Enum.sort(Enum.uniq(seqs))

    assert Enum.count(events, fn event ->
             event.type == :message_completed and event.payload[:partial] == true
           end) == 1

    assert {:ok, %{transcript: transcript}} = Ear.get_run(run_id)
    assert Enum.map(Transcript.to_list(transcript), & &1.content) == ["test", text]
    message = Transcript.last(transcript)
    assert message.id == message_id
    assert message.metadata.partial
    assert message.metadata.reason == reason
    refute_receive {:ear, %{run_id: ^run_id}}, 20
    events
  end

  defp collect_terminal(run_id, events \\ []) do
    receive do
      {:ear, %{run_id: ^run_id} = event} ->
        if Event.terminal?(event),
          do: Enum.reverse([event | events]),
          else: collect_terminal(run_id, [event | events])
    after
      1_000 -> flunk("run did not emit a terminal event")
    end
  end
end
