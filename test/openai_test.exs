defmodule Littleagent.OpenAITest do
  use ExUnit.Case, async: true

  test "normalizes invalid HTTP timeout configuration" do
    assert Littleagent.Model.OpenAI.new(timeout: -1).timeout == 30_000
    assert Littleagent.Model.OpenAI.new(timeout: "fast").timeout == 30_000
    assert Littleagent.Model.OpenAI.new(timeout: 0).timeout == 0
  end

  test "normalizes empty endpoint and model configuration" do
    adapter = Littleagent.Model.OpenAI.new(endpoint: "", model: " gpt-test ")
    assert adapter.endpoint == "https://api.openai.com/v1/chat/completions"
    assert adapter.model == "gpt-test"
  end

  test "normalizes malformed endpoints" do
    assert Littleagent.Model.OpenAI.new(endpoint: "localhost:4000").endpoint ==
             "https://api.openai.com/v1/chat/completions"

    assert Littleagent.Model.OpenAI.new(endpoint: "ftp://example.com").endpoint ==
             "https://api.openai.com/v1/chat/completions"
  end

  test "normalizes non-string message content" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_ip, port}} = :inet.sockname(listener)
    owner = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {headers, initial} = read_headers(socket, "")
        [_h, length] = Regex.run(~r/content-length: (\d+)/i, headers)
        request_body = read_body(socket, initial, String.to_integer(length))
        send(owner, {:request_body, :json.decode(request_body)})
        body = ~s({"choices":[{"message":{"content":[{"type":"text","text":"hello"}]}}]})

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
          )

        :gen_tcp.close(socket)
      end)

    adapter =
      Littleagent.Model.OpenAI.new(
        api_key: "test",
        endpoint: "http://127.0.0.1:#{port}/v1/chat/completions"
      )

    assert {:ok, %{text: "hello"}} =
             Littleagent.Model.OpenAI.complete(adapter, %{messages: [], prompt: "hello"}, %{})

    assert_receive {:request_body,
                    %{
                      "messages" => [
                        %{"role" => "system"},
                        %{"role" => "user", "content" => "hello"}
                      ]
                    }}

    Task.await(server)
  end

  test "treats blank API keys as missing" do
    adapter = Littleagent.Model.OpenAI.new(api_key: "  ")
    assert adapter.api_key == nil
    assert {:error, :missing_api_key} = Littleagent.Model.OpenAI.complete(adapter, %{}, %{})
  end

  test "tool continuation sends system instructions and JSON string arguments" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_ip, port}} = :inet.sockname(listener)
    owner = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {headers, initial_body} = read_headers(socket, "")
        [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)
        body = read_body(socket, initial_body, String.to_integer(length))
        send(owner, {:request_body, :json.decode(body)})

        response =
          ~s({"choices":[{"message":{"content":"done"},"finish_reason":"stop"}],"usage":{"total_tokens":3}})

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(response)}\r\nConnection: close\r\n\r\n#{response}"
          )

        :gen_tcp.close(socket)
      end)

    alias Littleagent.Conversation.Message

    request = %{
      system_prompt: "Keep the skill instructions.",
      messages: [
        Message.new(:system, "Keep the skill instructions."),
        Message.new(:user, "echo"),
        Message.new(:assistant, "",
          tool_calls: [
            %{id: "call-1", name: "echo", args: %{"text" => "hello"}},
            :malformed_tool_call
          ]
        ),
        Message.new(:tool, "hello", tool_call_id: "call-1")
      ]
    }

    adapter =
      Littleagent.Model.OpenAI.new(
        api_key: "test",
        endpoint: "http://127.0.0.1:#{port}/v1/chat/completions"
      )

    assert {:ok, %{text: "done"}} = Littleagent.Model.OpenAI.complete(adapter, request, %{})
    assert_receive {:request_body, payload}
    [system, user, assistant, tool] = payload["messages"]
    assert system == %{"role" => "system", "content" => request.system_prompt}
    assert user["role"] == "user"

    assert [
             %{"id" => "call-1", "function" => function},
             %{"id" => "nil", "function" => %{"name" => "nil", "arguments" => "null"}}
           ] = assistant["tool_calls"]

    assert is_binary(function["arguments"])
    assert :json.decode(function["arguments"]) == %{"text" => "hello"}
    assert tool["tool_call_id"] == "call-1"
    Task.await(server)
  end

  test "serializes string-keyed message maps" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_ip, port}} = :inet.sockname(listener)
    owner = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {headers, initial_body} = read_headers(socket, "")
        [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)
        body = read_body(socket, initial_body, String.to_integer(length))
        send(owner, {:request_body, :json.decode(body)})
        response = ~s({"choices":[{"message":{"content":"ok"}}]})

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(response)}\r\nConnection: close\r\n\r\n#{response}"
          )

        :gen_tcp.close(socket)
      end)

    adapter =
      Littleagent.Model.OpenAI.new(
        api_key: "test",
        endpoint: "http://127.0.0.1:#{port}/v1/chat/completions"
      )

    request = %{messages: [%{"role" => "user", "content" => "hello"}]}

    assert {:ok, %{text: "ok"}} = Littleagent.Model.OpenAI.complete(adapter, request, %{})

    assert_receive {:request_body,
                    %{
                      "messages" => [
                        %{"role" => "system"},
                        %{"role" => "user", "content" => "hello"}
                      ]
                    }}

    Task.await(server)
  end

  test "stream parser preserves text and tool deltas from one event" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_ip, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {headers, initial} = read_headers(socket, "")
        [_h, length] = Regex.run(~r/content-length: (\d+)/i, headers)
        _ = read_body(socket, initial, String.to_integer(length))

        body =
          ~s(data: {"choices":[{"delta":{"content":"hi","tool_calls":[{"index":0,"id":"c1","function":{"name":"echo","arguments":"{}"}}]}}]}\r\n\r\ndata: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":[]}]}}]}\r\n\r\ndata:[DONE]\r\n\r\n)

        response =
          "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"

        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
      end)

    adapter =
      Littleagent.Model.OpenAI.new(
        api_key: "test",
        endpoint: "http://127.0.0.1:#{port}/v1/chat/completions"
      )

    assert {:ok, %{chunks: chunks}} =
             Littleagent.Model.OpenAI.stream(adapter, %{prompt: "hi"}, %{})

    assert %{type: :text_delta, text: "hi"} in chunks
    assert %{type: :tool_call_delta, index: 0, id: "c1", name: "echo", arguments: "{}"} in chunks
    Task.await(server)
  end

  test "live stream forwards chunks before HTTP response completes" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_ip, port}} = :inet.sockname(listener)
    owner = self()
    token = make_ref()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {headers, initial} = read_headers(socket, "")
        [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)
        _ = read_body(socket, initial, String.to_integer(length))

        first = ~s(data: {"choices":[{"delta":{"content":"hel"}}]}\r\n\r\n)
        second = ~s(data: {"choices":[{"delta":{"content":"lo"}}]}\r\n\r\ndata: [DONE]\r\n\r\n)
        total = byte_size(first) + byte_size(second)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Length: #{total}\r\nConnection: close\r\n\r\n"
          )

        :ok = :gen_tcp.send(socket, binary_part(first, 0, 12))
        Process.sleep(30)
        :ok = :gen_tcp.send(socket, binary_part(first, 12, byte_size(first) - 12))
        Process.sleep(80)
        :ok = :gen_tcp.send(socket, second)
        :gen_tcp.close(socket)
      end)

    adapter =
      Littleagent.Model.OpenAI.new(
        api_key: "test",
        endpoint: "http://127.0.0.1:#{port}/v1/chat/completions"
      )

    task =
      Task.async(fn ->
        Littleagent.Model.OpenAI.stream(adapter, %{prompt: "hi"},
          stream_owner: owner,
          stream_token: token
        )
      end)

    assert_receive {:model_stream_chunk, ^token, [%{type: :text_delta, text: "hel"}]}, 1_000
    assert_receive {:model_stream_chunk, ^token, [%{type: :text_delta, text: "lo"}]}, 1_000
    assert {:ok, %{chunks: chunks}} = Task.await(task, 1_000)
    assert Enum.map(chunks, & &1[:text]) == ["hel", "lo"]
    Task.await(server)
  end

  defp read_headers(socket, data) do
    case String.split(data, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        {headers, body}

      _ ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 5000)
        read_headers(socket, data <> more)
    end
  end

  defp read_body(_socket, data, size) when byte_size(data) >= size, do: binary_part(data, 0, size)

  defp read_body(socket, data, size) do
    {:ok, more} = :gen_tcp.recv(socket, 0, 5000)
    read_body(socket, data <> more, size)
  end
end

defmodule Littleagent.OpenAITest.CompleteOnlyAdapter do
  @behaviour Littleagent.Model.Adapter
  def complete(_adapter, _request, _context), do: {:ok, %{text: "ok"}}
end
