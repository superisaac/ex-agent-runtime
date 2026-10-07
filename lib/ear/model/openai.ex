defmodule Ear.Model.OpenAI do
  @behaviour Ear.Model.Adapter
  @moduledoc "OpenAI-compatible chat completion adapter using OTP HTTP clients."
  defstruct endpoint: "https://api.openai.com/v1/chat/completions",
            api_key: nil,
            model: "gpt-4o-mini",
            timeout: 30_000

  def new(opts \\ []) do
    %__MODULE__{
      endpoint:
        normalize_endpoint(
          Keyword.get(
            opts,
            :endpoint,
            System.get_env(
              "EAR_OPENAI_ENDPOINT",
              "https://api.openai.com/v1/chat/completions"
            )
          )
        ),
      api_key: normalize_api_key(Keyword.get(opts, :api_key, System.get_env("OPENAI_API_KEY"))),
      model:
        normalize_model(Keyword.get(opts, :model, System.get_env("EAR_MODEL", "gpt-4o-mini"))),
      timeout: normalize_timeout(Keyword.get(opts, :timeout, 30_000))
    }
  end

  def complete(%__MODULE__{api_key: key} = adapter, request, _context)
      when is_binary(key) and key != "" do
    :inets.start()
    :ssl.start()
    payload = %{"model" => adapter.model, "messages" => messages(request)}

    payload =
      if request[:tools] in [nil, []],
        do: payload,
        else: Map.put(payload, "tools", tool_definitions(request[:tools]))

    body = :json.encode(payload)

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"authorization", String.to_charlist("Bearer " <> key)}
    ]

    case :httpc.request(
           :post,
           {String.to_charlist(adapter.endpoint), headers, ~c"application/json", body},
           [{:timeout, adapter.timeout}],
           [{:body_format, :binary}]
         ) do
      {:ok, {{_, 200, _}, _headers, response}} ->
        decode_response(response)

      {:ok, {{_, status, _}, _headers, response}} ->
        {:error, {:provider, status, provider_error(response)}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  def complete(%__MODULE__{}, _request, _context), do: {:error, :missing_api_key}

  def stream(adapter, request, context) do
    if not (is_binary(adapter.api_key) and adapter.api_key != "") do
      {:error, :missing_api_key}
    else
      stream_request(adapter, request, context)
    end
  end

  defp stream_request(adapter, request, context) do
    :inets.start()
    :ssl.start()
    payload = %{"model" => adapter.model, "messages" => messages(request), "stream" => true}

    payload =
      if request[:tools] in [nil, []],
        do: payload,
        else: Map.put(payload, "tools", tool_definitions(request[:tools]))

    body = :json.encode(payload)

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"authorization", String.to_charlist("Bearer " <> adapter.api_key)}
    ]

    options = [{:body_format, :binary}]

    case live_stream?(context) do
      true -> stream_request_live(adapter, request, context, headers, body)
      false -> stream_request_buffered(adapter, request, context, headers, body, options)
    end
  end

  defp stream_request_buffered(adapter, _request, _context, headers, body, options) do
    case :httpc.request(
           :post,
           {String.to_charlist(adapter.endpoint), headers, ~c"application/json", body},
           [{:timeout, adapter.timeout}],
           options
         ) do
      {:ok, {{_, 200, _}, _headers, response}} ->
        {:ok, %{chunks: parse_sse(response)}}

      {:ok, {{_, status, _}, _headers, response}} ->
        {:error, {:provider, status, provider_error(response)}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp stream_request_live(adapter, _request, context, headers, body) do
    owner = context[:stream_owner]
    token = context[:stream_token]

    case :httpc.request(
           :post,
           {String.to_charlist(adapter.endpoint), headers, ~c"application/json", body},
           [{:timeout, adapter.timeout}],
           [{:sync, false}, {:stream, :self}]
         ) do
      {:ok, request_id} -> receive_stream(request_id, owner, token, <<>>, [], nil)
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  defp receive_stream(request_id, owner, token, buffer, chunks, status) do
    receive do
      message -> receive_stream_message(message, request_id, owner, token, buffer, chunks, status)
    after
      60_000 -> {:error, {:transport, :timeout}}
    end
  end

  defp receive_stream_message(
         {:http, {request_id, :stream_start, headers}},
         request_id,
         owner,
         token,
         buffer,
         chunks,
         _status
       ) do
    receive_stream(request_id, owner, token, buffer, chunks, stream_status(headers))
  end

  defp receive_stream_message(
         {:http, {request_id, :stream, data}},
         request_id,
         owner,
         token,
         buffer,
         chunks,
         status
       )
       when is_binary(data) do
    {new_buffer, new_chunks} = parse_stream_chunk(buffer <> data, chunks)

    if new_chunks != chunks,
      do: send(owner, {:model_stream_chunk, token, Enum.drop(new_chunks, length(chunks))})

    receive_stream(request_id, owner, token, new_buffer, new_chunks, status)
  end

  defp receive_stream_message(
         {:http, {request_id, :stream_end, _headers}},
         request_id,
         owner,
         token,
         buffer,
         chunks,
         status
       ) do
    {_buffer, final_chunks} = parse_stream_chunk(buffer <> "\n", chunks)

    if final_chunks != chunks,
      do: send(owner, {:model_stream_chunk, token, Enum.drop(final_chunks, length(chunks))})

    case status do
      200 -> {:ok, %{chunks: final_chunks}}
      nil -> {:error, {:transport, :missing_status}}
      code -> {:error, {:provider, code, %{}}}
    end
  end

  defp receive_stream_message(
         {:http, {request_id, :error, reason}},
         request_id,
         _owner,
         _token,
         _buffer,
         _chunks,
         _status
       ),
       do: {:error, {:transport, reason}}

  defp receive_stream_message(
         {:http, {request_id, {:error, reason}}},
         request_id,
         _owner,
         _token,
         _buffer,
         _chunks,
         _status
       ),
       do: {:error, {:transport, reason}}

  defp receive_stream_message(_message, request_id, owner, token, buffer, chunks, status),
    do: receive_stream(request_id, owner, token, buffer, chunks, status)

  defp parse_stream_chunk(data, chunks) do
    lines = String.split(data, "\n")
    {complete, [tail]} = Enum.split(lines, -1)

    additions =
      complete
      |> Enum.map(&String.trim_trailing(&1, "\r"))
      |> Enum.flat_map(&sse_data/1)
      |> Enum.reject(&(&1 == "[DONE]"))
      |> Enum.flat_map(fn line ->
        case decode_json(line) do
          {:ok, %{"choices" => [%{"delta" => delta} | _]}} -> delta_chunks(delta)
          _ -> []
        end
      end)

    {tail, chunks ++ additions}
  end

  defp live_stream?(context), do: is_pid(context[:stream_owner]) and context[:stream_token] != nil

  defp stream_status({status, _headers}) when is_integer(status), do: status
  defp stream_status({{_version, status, _reason}, _headers}) when is_integer(status), do: status
  defp stream_status(status) when is_integer(status), do: status
  defp stream_status(_), do: 200

  defp parse_sse(body) do
    body
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(&sse_data/1)
    |> Enum.reject(&(&1 == "[DONE]"))
    |> Enum.flat_map(fn line ->
      case decode_json(line) do
        {:ok, %{"choices" => [%{"delta" => delta} | _]}} ->
          delta_chunks(delta)

        _ ->
          []
      end
    end)
  end

  defp sse_data(line) do
    case String.split(line, ":", parts: 2) do
      ["data", value] -> [String.trim_leading(value, " ")]
      _ -> []
    end
  end

  defp delta_chunks(delta) when is_map(delta) do
    text_chunks =
      case delta["content"] do
        content when is_binary(content) -> [%{type: :text_delta, text: content}]
        _ -> []
      end

    tool_chunks =
      case delta["tool_calls"] do
        calls when is_list(calls) -> Enum.map(calls, &tool_call_chunk/1)
        _ -> []
      end

    text_chunks ++ tool_chunks
  end

  defp delta_chunks(_delta), do: []

  defp tool_call_chunk(%{"index" => index, "id" => id, "function" => function})
       when is_map(function),
       do: %{
         type: :tool_call_delta,
         index: index,
         id: id,
         name: function["name"],
         arguments: function["arguments"] || ""
       }

  defp tool_call_chunk(%{"index" => index, "function" => function}) when is_map(function),
    do: %{
      type: :tool_call_delta,
      index: index,
      name: function["name"],
      arguments: function["arguments"] || ""
    }

  defp tool_call_chunk(_), do: %{type: :tool_call_delta, index: 0, arguments: ""}

  defp messages(request) do
    case request[:messages] do
      messages when is_list(messages) and messages != [] ->
        history = Enum.map(messages, &map_message/1)

        if Enum.any?(history, &(message_value(&1, :role) in [:system, "system"])),
          do: history,
          else: [
            %{
              "role" => "system",
              "content" => request[:system_prompt] || "You are a helpful coding assistant."
            }
            | history
          ]

      _ ->
        legacy_messages(request)
    end
  end

  defp map_message(message) do
    role = message_value(message, :role) || "user"
    content = message_value(message, :content) || ""
    tool_call_id = message_value(message, :tool_call_id)
    tool_calls = message_value(message, :tool_calls)

    role = if is_atom(role), do: Atom.to_string(role), else: to_string(role)
    base = %{"role" => role, "content" => to_string(content)}

    base =
      if tool_call_id,
        do: Map.put(base, "tool_call_id", tool_call_id),
        else: base

    if tool_calls do
      Map.put(
        base,
        "tool_calls",
        Enum.map(tool_calls, fn call ->
          %{
            "id" => call_value(call, :id),
            "type" => "function",
            "function" => %{
              "name" => call_value(call, :name),
              "arguments" =>
                call
                |> tool_arguments()
                |> json_value()
                |> :json.encode()
                |> IO.iodata_to_binary()
            }
          }
        end)
      )
    else
      base
    end
  end

  defp message_value(message, key) when is_map(message) do
    Map.get(message, key, Map.get(message, Atom.to_string(key)))
  end

  defp message_value(_message, _key), do: nil

  defp tool_arguments(call) do
    call_value(call, :args)
  end

  defp call_value(call, key) when is_map(call),
    do: Map.get(call, key, Map.get(call, Atom.to_string(key)))

  defp call_value(_call, _key), do: nil

  defp json_value(nil), do: :null

  defp json_value(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, json_value(item)} end)

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value), do: value

  defp legacy_messages(request) do
    system = request[:system_prompt] || "You are a helpful coding assistant."

    messages = [
      %{"role" => "system", "content" => system},
      %{"role" => "user", "content" => request[:prompt] || ""}
    ]

    case request[:tool_results] do
      nil -> messages
      results -> messages ++ Enum.map(results, &%{"role" => "tool", "content" => inspect(&1)})
    end
  end

  defp decode_response(body) do
    with {:ok, data} <- decode_json(body),
         true <- is_map(data),
         [%{"message" => message} = choice | _] <- data["choices"],
         true <- is_map(message) do
      response = response_message(message)
      response = if data["usage"], do: Map.put(response, :usage, data["usage"]), else: response

      response =
        if choice["finish_reason"],
          do: Map.put(response, :finish_reason, choice["finish_reason"]),
          else: response

      {:ok, response}
    else
      _ -> {:error, {:malformed_response, body}}
    end
  end

  defp response_message(%{"tool_calls" => calls} = message) when is_list(calls) do
    %{
      text: normalize_content(message["content"]),
      tool_calls: Enum.map(calls, &normalize_tool_call/1)
    }
  end

  defp response_message(message), do: %{text: normalize_content(message["content"])}

  defp normalize_content(nil), do: ""
  defp normalize_content(content) when is_binary(content), do: content
  defp normalize_content([]), do: ""

  defp normalize_content(content) when is_list(content) do
    Enum.map_join(content, "", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{type: :text, text: text} when is_binary(text) -> text
      part -> inspect(part)
    end)
  end

  defp normalize_content(content), do: inspect(content)

  defp normalize_tool_call(%{"id" => id, "function" => %{"name" => name, "arguments" => args}}) do
    %{id: id, name: name, args: decode_arguments(args)}
  end

  defp normalize_tool_call(call), do: %{id: call["id"], name: nil, args: nil}

  defp decode_arguments(arguments) when is_binary(arguments) do
    case decode_json(arguments) do
      {:ok, value} -> value
      _ -> arguments
    end
  end

  defp decode_arguments(arguments), do: arguments

  defp tool_definitions(tools) do
    Enum.map(tools, fn tool ->
      %{
        "type" => "function",
        "function" => %{
          "name" => tool[:name] || tool["name"],
          "description" => tool[:description] || tool["description"],
          "parameters" => tool[:parameters] || %{"type" => "object"}
        }
      }
    end)
  end

  defp provider_error(body) do
    case decode_json(body) do
      {:ok, %{"error" => error}} -> error
      _ -> body
    end
  end

  defp decode_json(body) do
    {:ok, :json.decode(body)}
  rescue
    _ -> {:error, :invalid_json}
  end

  defp normalize_timeout(value) when is_integer(value) and value >= 0, do: value
  defp normalize_timeout(_value), do: 30_000

  defp normalize_endpoint(value) when is_binary(value) do
    value = String.trim(value)

    case URI.parse(value) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        value

      _ ->
        "https://api.openai.com/v1/chat/completions"
    end
  end

  defp normalize_endpoint(_value), do: "https://api.openai.com/v1/chat/completions"

  defp normalize_model(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: "gpt-4o-mini", else: value
  end

  defp normalize_model(_value), do: "gpt-4o-mini"

  defp normalize_api_key(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_api_key(_value), do: nil
end
