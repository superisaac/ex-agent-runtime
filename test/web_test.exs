defmodule Ear.WebTest do
  use ExUnit.Case, async: false

  defmodule RecordingAdapter do
    defstruct [:owner]

    def complete(adapter, request, _context) do
      send(adapter.owner, {:request, request})
      {:ok, %{text: "Hello <script>"}, adapter}
    end
  end

  defmodule StreamingAdapter do
    defstruct [:owner]
    def complete(_adapter, _request, _context), do: {:error, :expected_stream}

    def stream(adapter, _request, context) do
      chunks = List.duplicate(%{type: :text_delta, text: "x"}, 150)
      send(context.stream_owner, {:model_stream_chunk, context.stream_token, chunks})
      send(adapter.owner, {:stream_started, self()})

      receive do
        :release -> {:ok, %{text: String.duplicate("x", 150)}, adapter}
      end
    end
  end

  setup do
    start_supervised!(
      {Ear.Web, config: false, port: 0, adapter: %RecordingAdapter{owner: self()}}
    )

    :ok
  end

  test "serves the page and static assets, with CSRF protection on mutations" do
    page = call(:get, "/")
    assert page.status == 200
    assert page.resp_body =~ "Conversation"
    refute page.resp_body =~ "__CSRF_TOKEN__"
    assert call(:get, "/app.js").status == 200
    assert call(:get, "/app.css").status == 200
    assert call(:get, "/icons/plus.svg").status == 200

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      call(:post, "/api/prompt", %{prompt: "Hello"})
    end

    [_, token] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, page.resp_body)
    cookie = page |> Plug.Conn.get_resp_header("set-cookie") |> hd() |> String.split(";") |> hd()

    response =
      Plug.Test.conn(:post, "/api/prompt", Jason.encode!(%{prompt: "Hello"}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("cookie", cookie)
      |> Plug.Conn.put_req_header("x-csrf-token", token)
      |> Ear.Web.Endpoint.call(Ear.Web.Endpoint.init([]))

    assert response.status == 200
    await_status(:completed)
    state = call(:get, "/api/state") |> Map.fetch!(:resp_body) |> Jason.decode!()
    assert state["workspace"] == File.cwd!()
    assert state["status"] == "completed"
    assert List.last(state["messages"])["content"] == "Hello <script>"
    assert state["turns"] == 1
  end

  test "retains conversation context and clears it for a new conversation" do
    assert {:error, :empty_prompt} = Ear.Web.Session.prompt("  ")
    assert :ok = Ear.Web.Session.prompt("First")
    assert_receive {:request, request}
    assert Enum.map(request.messages, & &1.content) == ["First"]
    await_status(:completed)

    assert :ok = Ear.Web.Session.prompt("Second")
    assert_receive {:request, request}
    assert Enum.map(request.messages, & &1.content) == ["First", "Hello <script>", "Second"]
    await_status(:completed)
    assert :ok = Ear.Web.Session.clear()
    assert %{status: :idle, messages: [], run_id: nil} = Ear.Web.Session.state()
  end

  test "rejects concurrent prompts and cancels an active run" do
    stop_supervised(Ear.Web)

    start_supervised!(
      {Ear.Web, config: false, port: 0, adapter: %Ear.TestSupport.BlockingAdapter{owner: self()}}
    )

    assert :ok = Ear.Web.Session.prompt("Wait")
    assert_receive {:model_started, _pid}
    assert {:error, :run_in_progress} = Ear.Web.Session.prompt("Another")
    assert {:error, :run_in_progress} = Ear.Web.Session.clear()
    assert :ok = Ear.Web.Session.cancel()
    await_status(:cancelled)
  end

  test "shows streamed output and terminal errors" do
    stop_supervised(Ear.Web)

    start_supervised!(
      {Ear.Web,
       config: false, port: 0, adapter: Ear.Model.Scripted.new([%{text: "Streamed reply"}])}
    )

    assert :ok = Ear.Web.Session.prompt("Stream")
    state = await_status(:completed)
    assert List.last(state.messages).content == "Streamed reply"
    assert state.partial == ""
    assert Enum.any?(state.events, &(&1.type == "message_completed"))

    stop_supervised(Ear.Web)
    start_supervised!({Ear.Web, config: false, port: 0, adapter: Ear.Model.Scripted.new([])})
    assert :ok = Ear.Web.Session.prompt("Fail")
    assert await_status(:failed).error == ":no_scripted_response"
  end

  test "displays live partial output without displacing lifecycle events" do
    stop_supervised(Ear.Web)

    start_supervised!(
      {Ear.Web, config: false, port: 0, adapter: %StreamingAdapter{owner: self()}}
    )

    assert :ok = Ear.Web.Session.prompt("Stream slowly")
    assert_receive {:stream_started, pid}
    state = await_partial()
    assert state.status == :running
    assert state.partial == String.duplicate("x", 150)
    assert Enum.any?(state.events, &(&1.type == "run_started"))
    send(pid, :release)
    assert await_status(:completed).partial == ""
  end

  test "validates workspace and task arguments" do
    assert {:error, {:invalid_workspace, _}} =
             Ear.Web.start_link(config: false, workspace: "/nonexistent/ear-web-workspace")

    assert_raise Mix.Error, fn -> Mix.Tasks.Ear.Web.run(["--port", "0"]) end
    assert_raise Mix.Error, fn -> Mix.Tasks.Ear.Web.run(["--unknown"]) end
  end

  defp call(method, path, body \\ nil) do
    conn = Plug.Test.conn(method, path, if(body, do: Jason.encode!(body), else: nil))

    conn =
      if body, do: Plug.Conn.put_req_header(conn, "content-type", "application/json"), else: conn

    Ear.Web.Endpoint.call(conn, Ear.Web.Endpoint.init([]))
  end

  defp await_status(status, attempts \\ 100)
  defp await_status(_status, 0), do: flunk("Run did not reach the expected status")

  defp await_status(status, attempts) do
    state = Ear.Web.Session.state()

    if state.status == status do
      state
    else
      Process.sleep(10)
      await_status(status, attempts - 1)
    end
  end

  defp await_partial(attempts \\ 100)
  defp await_partial(0), do: flunk("Stream did not produce partial output")

  defp await_partial(attempts) do
    state = Ear.Web.Session.state()

    if state.partial != "" do
      state
    else
      Process.sleep(10)
      await_partial(attempts - 1)
    end
  end
end
