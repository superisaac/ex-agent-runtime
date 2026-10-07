defmodule Ear.TUITest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  test "injected input loop can stop from the handler" do
    assert :ok =
             Ear.TUI.Input.read_loop(
               fn {:prompt, "exit"} -> :stop end,
               fn _prompt -> "exit\n" end
             )
  end

  test "input loop preserves the injected reader across multiple prompts" do
    inputs = start_supervised!({Agent, fn -> ["first\n", "second\n"] end})
    owner = self()

    assert :finished =
             Ear.TUI.Input.read_loop(
               fn
                 {:prompt, "first"} -> send(owner, :first_prompt)
                 {:prompt, "second"} -> {:stop, :finished}
               end,
               fn _prompt ->
                 Agent.get_and_update(inputs, fn [head | tail] -> {head, tail} end)
               end
             )

    assert_received :first_prompt
    assert Agent.get(inputs, & &1) == []
  end

  test "renderer prints assistant output only once" do
    output =
      capture_io(fn ->
        Ear.TUI.Renderer.render(%{type: :message_delta, payload: %{text: "hello"}})
        Ear.TUI.Renderer.render(%{type: :message_completed, payload: %{text: "hello"}})
        Ear.TUI.Renderer.render(%{type: :run_completed, payload: %{text: "hello"}})
      end)

    assert output == "hello\n"
  end

  test "renderer reports skill lifecycle events" do
    output =
      capture_io(fn ->
        Ear.TUI.Renderer.render(%{type: :skill_loaded, payload: %{name: "demo"}})
        Ear.TUI.Renderer.render(%{type: :skill_error, payload: %{error: :invalid}})
      end)

    assert output == "[skill] demo loaded\n[skill] failed: :invalid\n"
  end

  test "renderer handles failed events without a reason" do
    assert capture_io(fn -> Ear.TUI.Renderer.render(%{type: :run_failed}) end) ==
             "\nError: run failed\n"
  end

  test "renderer handles incomplete tool events" do
    output =
      capture_io(fn ->
        Ear.TUI.Renderer.render(%{type: :tool_call_started})
        Ear.TUI.Renderer.render(%{type: :tool_call_completed})
        Ear.TUI.Renderer.render(%{type: :tool_call_failed})
      end)

    assert output == "\n[tool] started\n\n[tool] completed\n\n[tool] failed\n"
  end

  test "renderer handles incomplete skill events" do
    output =
      capture_io(fn ->
        Ear.TUI.Renderer.render(%{type: :skill_loaded})
        Ear.TUI.Renderer.render(%{type: :skill_error})
      end)

    assert output == "[skill] loaded\n[skill] failed\n"
  end

  test "renderer reports run start" do
    assert capture_io(fn -> Ear.TUI.Renderer.render(%{type: :run_started}) end) ==
             "[run] started\n"
  end

  test "fullscreen editor supports grapheme insertion, navigation and submit" do
    state = Ear.TUI.Fullscreen.new(ansi: false)
    {state, :none} = Ear.TUI.Fullscreen.handle_key(state, "hel")
    {state, :none} = Ear.TUI.Fullscreen.handle_key(state, :left)
    {state, :none} = Ear.TUI.Fullscreen.handle_key(state, "X")
    assert {state, {:submit, "heXl"}} = Ear.TUI.Fullscreen.handle_key(state, :enter)
    assert state.input == ""
  end

  test "fullscreen key parser and frame include scrollable status" do
    assert Ear.TUI.Fullscreen.parse_key("\e[A") == :up
    assert Ear.TUI.Fullscreen.parse_key(<<3>>) == :ctrl_c

    state =
      Ear.TUI.Fullscreen.new(ansi: false, height: 5)
      |> Ear.TUI.Fullscreen.handle_event(%{
        type: :message_delta,
        payload: %{text: "hello"}
      })
      |> Ear.TUI.Fullscreen.handle_event(%{type: :run_started})

    frame = Ear.TUI.Fullscreen.render_frame(state)
    assert frame =~ "hello"
    assert frame =~ "[Running]"
    assert frame =~ "❯"
  end

  test "fullscreen decoder preserves partial escape sequences" do
    assert {[], "\e["} = Ear.TUI.Fullscreen.decode_keys("\e[")
    assert {[:up], ""} = Ear.TUI.Fullscreen.decode_keys("\e[A")
    assert {[:delete], ""} = Ear.TUI.Fullscreen.decode_keys("\e[3~")
  end

  test "fullscreen mode accepts injected keys and exits on EOF" do
    keys = Agent.start_link(fn -> ["h", "i", "\r", :eof] end) |> elem(1)

    assert :ok =
             Ear.TUI.start(
               fullscreen: true,
               ansi: false,
               adapter: Ear.Model.Scripted.new([%{text: "ok"}]),
               key_input: fn ->
                 Agent.get_and_update(keys, fn
                   [head | tail] -> {head, tail}
                   [] -> {:eof, []}
                 end)
               end
             )

    Agent.stop(keys)
  end

  test "help commands render in sorted order" do
    counter = Agent.start_link(fn -> 0 end) |> elem(1)

    output =
      capture_io(fn ->
        Ear.TUI.start(
          ansi: false,
          input: fn _prompt ->
            case Agent.get_and_update(counter, fn
                   0 -> {"/help\n", 1}
                   _ -> {"/exit\n", 1}
                 end) do
              value -> value
            end
          end,
          renderer: fn _event -> :ok end
        )
      end)

    Agent.stop(counter)
    assert [first | _] = String.split(output, "\n", trim: true)
    assert first == "/cancel - Cancel the active run"
  end

  test "clear command supports ANSI-disabled output" do
    parent = self()
    counter = Agent.start_link(fn -> 0 end) |> elem(1)

    output =
      capture_io(fn ->
        Ear.TUI.start(
          ansi: false,
          input: fn _prompt ->
            case Agent.get_and_update(counter, fn
                   0 -> {"/clear\n", 1}
                   _ -> {"/exit\n", 1}
                 end) do
              value -> value
            end
          end,
          renderer: fn _event -> send(parent, :unexpected_event) end
        )
      end)

    Agent.stop(counter)
    assert output =~ "--- screen cleared ---"
    refute output =~ "\e[2J"
    refute_received :unexpected_event
  end

  for {label, input, expected} <- [
        {"exit command", "/exit\n", :ok},
        {"EOF", :eof, :ok},
        {"input error", {:error, :closed}, {:error, :closed}}
      ] do
    test "TUI stops its custom renderer on #{label}" do
      owner = self()

      task =
        Task.async(fn ->
          Ear.TUI.start(
            adapter: Ear.Model.Scripted.new([%{text: "hello"}]),
            renderer: fn event -> send(owner, {:rendered, self(), event}) end,
            input: fn _prompt ->
              send(owner, {:input_requested, self()})

              receive do
                {:input, value} -> value
              end
            end
          )
        end)

      assert_receive {:input_requested, tui}
      send(tui, {:input, "hello\n"})
      assert_receive {:rendered, renderer, %{type: :run_started}}
      renderer_ref = Process.monitor(renderer)
      assert_receive {:rendered, ^renderer, %{type: :message_delta, payload: %{text: "hello"}}}
      assert_receive {:rendered, ^renderer, %{type: :message_completed}}
      assert_receive {:rendered, ^renderer, %{type: :run_completed}}
      assert_receive {:input_requested, ^tui}
      send(tui, {:input, unquote(Macro.escape(input))})
      assert Task.await(task) == unquote(Macro.escape(expected))
      assert_receive {:DOWN, ^renderer_ref, :process, ^renderer, :normal}
    end
  end

  test "renderer exits when the TUI owner crashes" do
    owner = self()

    tui =
      spawn(fn ->
        Ear.TUI.start(
          adapter: Ear.Model.Scripted.new([%{text: "hello"}]),
          renderer: fn event -> send(owner, {:rendered, self(), event}) end,
          input: fn _ ->
            receive do
              {:input, value} -> value
            end
          end
        )
      end)

    send(tui, {:input, "hello\n"})
    assert_receive {:rendered, renderer, %{type: :run_started}}
    renderer_ref = Process.monitor(renderer)
    Process.exit(tui, :kill)
    assert_receive {:DOWN, ^renderer_ref, :process, ^renderer, :normal}
  end

  test "exit waits for an active run to stop" do
    owner = self()
    inputs = Agent.start_link(fn -> ["work\n", "/exit\n"] end) |> elem(1)

    task =
      Task.async(fn ->
        Ear.TUI.start(
          adapter: %Ear.TestSupport.BlockingAdapter{owner: owner},
          input: fn _ -> Agent.get_and_update(inputs, fn [head | tail] -> {head, tail} end) end,
          renderer: fn _ -> :ok end
        )
      end)

    assert_receive {:model_started, worker}, 1000
    worker_ref = Process.monitor(worker)
    assert Task.await(task, 2000) == :ok
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}
    Agent.stop(inputs)
  end
end
