defmodule Ear.AdapterTest.CompleteOnly do
  @behaviour Ear.Model.Adapter
  defstruct text: "fallback"

  @impl true
  def complete(adapter, _request, _context) do
    text = if is_atom(adapter), do: "module fallback", else: adapter.text
    {:ok, %{text: text}}
  end
end

defmodule Ear.AdapterTest.ContextAdapter do
  defstruct [:owner]

  def complete(%__MODULE__{owner: owner}, _request, context) do
    send(owner, {:adapter_context, context})
    {:ok, %{text: "context"}}
  end
end

defmodule Ear.AdapterTest.LegacyModule do
  def complete(_request, _context), do: {:ok, %{text: "legacy"}}
end

defmodule Ear.AdapterTest.LegacyContext do
  def complete(_request, context), do: {:ok, %{text: context[:workspace] || "missing"}}
end

defmodule Ear.AdapterTest.LiveStream do
  def complete(_adapter, _request, _context), do: {:ok, %{text: "fallback"}}

  def stream(_adapter, _request, context) do
    send(context.tool_context[:test_pid], {:stream_started, context.stream_token})

    send(
      context.stream_owner,
      {:model_stream_chunk, context.stream_token, [%{type: :text_delta, text: "live"}]}
    )

    Process.sleep(50)
    {:ok, %{chunks: [%{type: :text_delta, text: "live"}]}}
  end
end

defmodule Ear.AdapterTest do
  use ExUnit.Case, async: false
  alias Ear.AdapterTest.CompleteOnly

  test "struct adapters fall back to complete when streaming is unavailable" do
    assert {:ok, %{text: "fallback"}, events} =
             Ear.run_with_events("hello", adapter: %CompleteOnly{}, stream: true)

    assert Enum.map(events, & &1.type) == [
             :run_started,
             :message_delta,
             :message_completed,
             :run_completed
           ]
  end

  test "module adapters fall back to complete when streaming is unavailable" do
    assert {:ok, %{text: "module fallback"}} =
             Ear.run("hello", adapter: CompleteOnly, stream: true)
  end

  test "model adapters receive run context" do
    adapter = %Ear.AdapterTest.ContextAdapter{owner: self()}

    assert {:ok, %{text: "context"}} =
             Ear.run("hello",
               adapter: adapter,
               workspace: "/tmp",
               tool_context: %{trace: "yes"}
             )

    assert_receive {:adapter_context,
                    %{run_id: run_id, workspace: "/tmp", tool_context: %{trace: "yes"}}}

    assert is_binary(run_id)
  end

  test "legacy module complete/2 adapters remain supported" do
    assert {:ok, %{text: "legacy"}} =
             Ear.run("hello", adapter: Ear.AdapterTest.LegacyModule)
  end

  test "legacy module adapters receive the run context" do
    assert {:ok, %{text: "/tmp"}} =
             Ear.run("hello",
               adapter: Ear.AdapterTest.LegacyContext,
               workspace: "/tmp"
             )
  end

  test "live adapter chunks reach subscribers before completion" do
    {:ok, run_id, _pid} =
      Ear.start_run("hello",
        adapter: Ear.AdapterTest.LiveStream,
        stream: true,
        tool_context: %{test_pid: self()},
        subscriber: self()
      )

    assert_receive {:stream_started, _token}, 1_000

    assert_receive {:ear, %{run_id: ^run_id, type: :message_delta, payload: %{text: "live"}}},
                   1_000

    assert_receive {:ear, %{run_id: ^run_id, type: :message_completed}}, 1_000
    assert_receive {:ear, %{run_id: ^run_id, type: :run_completed}}, 1_000
  end
end
