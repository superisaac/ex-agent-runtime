defmodule LittleagentTest do
  use ExUnit.Case

  setup do
    Littleagent.clear_runs()
    :ok
  end

  test "parses slash commands" do
    assert Littleagent.TUI.Command.parse("/login openai") == {:command, "login", "openai"}
    assert Littleagent.TUI.Command.parse("/HELP") == {:command, "help", ""}
    assert Littleagent.TUI.Command.parse("hello") == {:prompt, "hello"}
    assert Littleagent.TUI.Command.parse(nil) == {:error, :invalid_input}
  end

  test "quit is an alias for exit" do
    {session, :exit} =
      Littleagent.TUI.Session.handle(Littleagent.TUI.Session.new(), {:command, "quit", ""})

    refute session.running
  end

  test "successful OpenAI login configures the session adapter" do
    session = Littleagent.TUI.Session.new(auth_adapter: Littleagent.Auth.Noop, run_opts: [])

    {session, {:message, _}} =
      Littleagent.TUI.Session.handle(session, {:command, "login", "openai"})

    assert %Littleagent.Model.OpenAI{} = Keyword.get(session.run_opts, :adapter)
  end

  test "login accepts an injected function adapter" do
    adapter = fn provider, _opts -> {:ok, %{provider: provider}} end
    session = Littleagent.TUI.Session.new(auth_adapter: adapter)

    {_session, {:message, "Logged in to openai."}} =
      Littleagent.TUI.Session.handle(session, {:command, "login", "openai"})
  end

  test "login converts auth adapter exceptions to errors" do
    adapter = fn _provider, _opts -> raise "auth failed" end
    session = Littleagent.TUI.Session.new(auth_adapter: adapter)

    {_session, {:error, {:auth_exception, %RuntimeError{}}}} =
      Littleagent.TUI.Session.handle(session, {:command, "login", "openai"})
  end

  test "runs a scripted response" do
    assert {:ok, %{text: "hello"}} =
             Littleagent.run("hi", adapter: Littleagent.Model.Scripted.new([%{text: "hello"}]))
  end

  test "emits lifecycle and text events" do
    {:ok, run_id, _pid} =
      Littleagent.start_run("hi",
        adapter: Littleagent.Model.Scripted.new([%{text: "hello"}]),
        subscriber: self()
      )

    assert_receive {:littleagent, %{type: :run_started, run_id: ^run_id}}
    assert_receive {:littleagent, %{type: :message_delta, payload: %{text: "hello"}}}
    assert_receive {:littleagent, %{type: :run_completed}}
  end

  test "loads selected skills into the model request" do
    root =
      Path.join(System.tmp_dir!(), "littleagent_skill_#{System.unique_integer([:positive])}/demo")

    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "SKILL.md"),
      "---\nname: demo\ndescription: Demo skill\n---\nUse demo rules."
    )

    adapter = Littleagent.Model.Scripted.new([%{text: "ok"}])

    assert {:ok, _id, _pid} =
             Littleagent.start_run("hi", adapter: adapter, skill_roots: [Path.dirname(root)])
  end

  test "executes a registered tool and continues the loop" do
    adapter =
      Littleagent.Model.Scripted.new([
        %{tool_calls: [%{id: "call-1", name: "echo", args: "from tool"}]},
        %{text: "done"}
      ])

    tools = Littleagent.Tools.Registry.new([Littleagent.Tools.Echo])

    {:ok, _run_id, _pid} =
      Littleagent.start_run("use echo", adapter: adapter, tools: tools, subscriber: self())

    assert_receive {:littleagent, %{type: :tool_call_started, tool_call_id: "call-1"}}

    assert_receive {:littleagent,
                    %{type: :tool_call_completed, payload: %{result: {:ok, "from tool"}}}}

    assert_receive {:littleagent, %{type: :run_completed, payload: %{text: "done"}}}
  end

  test "openai adapter fails clearly when credentials are missing" do
    assert {:error, :missing_api_key} =
             Littleagent.Model.OpenAI.complete(
               Littleagent.Model.OpenAI.new(api_key: nil),
               %{},
               %{}
             )
  end

  test "enforces output and tool-call limits" do
    assert {:error, %{reason: :max_output_chars}} =
             Littleagent.run("hello",
               adapter: Littleagent.Model.Scripted.new([%{text: "too long"}]),
               max_output_chars: 3
             )

    response = %{tool_calls: [%{id: "one", name: "echo", args: "x"}]}

    assert {:error, %{reason: :max_tool_calls}} =
             Littleagent.run("hello",
               adapter: Littleagent.Model.Scripted.new([response]),
               tools: Littleagent.Tools.Registry.new([Littleagent.Tools.Echo]),
               max_tool_calls: 0
             )

    mixed = %{text: "too long", tool_calls: [%{id: "one", name: "echo", args: "x"}]}

    assert {:error, %{reason: :max_output_chars}} =
             Littleagent.run("hello",
               adapter: Littleagent.Model.Scripted.new([mixed]),
               tools: Littleagent.Tools.Registry.new([Littleagent.Tools.Echo]),
               max_output_chars: 3
             )
  end

  test "enforces an elapsed-time limit" do
    assert {:error, %{reason: :timeout}} =
             Littleagent.run("hello",
               adapter: Littleagent.Model.Scripted.new([%{text: "hello"}]),
               max_elapsed_ms: 0
             )
  end

  test "reports invalid skills instead of silently dropping them" do
    root =
      Path.join(System.tmp_dir!(), "littleagent_invalid_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "broken"))
    File.write!(Path.join(root, "broken/SKILL.md"), "missing front matter")

    {skills, errors} = Littleagent.Skills.Loader.discover_report([root])
    assert skills == []
    assert [{:invalid_skill, _path}] = errors
  end

  test "run events include skill loading errors" do
    root =
      Path.join(
        System.tmp_dir!(),
        "littleagent_event_skill_#{System.unique_integer([:positive])}/broken"
      )

    File.mkdir_p!(root)
    File.write!(Path.join(root, "SKILL.md"), "invalid")

    assert {:ok, _payload, events} =
             Littleagent.run_with_events("hello",
               adapter: Littleagent.Model.Scripted.new([%{text: "ok"}]),
               skill_roots: [Path.dirname(root)]
             )

    assert Enum.any?(events, &(&1.type == :skill_error))
  end

  test "run events include loaded skills" do
    root =
      Path.join(
        System.tmp_dir!(),
        "littleagent_loaded_skill_#{System.unique_integer([:positive])}/demo"
      )

    File.mkdir_p!(root)
    File.write!(Path.join(root, "SKILL.md"), "---\nname: demo\ndescription: Demo\n---\nUse demo.")

    assert {:ok, _payload, events} =
             Littleagent.run_with_events("hello",
               adapter: Littleagent.Model.Scripted.new([%{text: "ok"}]),
               skill_roots: [Path.dirname(root)]
             )

    assert Enum.any?(events, &(&1.type == :skill_loaded and &1.payload.name == "demo"))
  end

  test "login reports missing environment credentials" do
    assert {:error, {:missing_credential, "OPENAI_API_KEY"}} =
             Littleagent.Auth.Env.login("openai", %{})
  end

  test "normalizes missing run and cancellation lookups" do
    assert {:error, :not_found} = Littleagent.cancel("missing-run")
    assert {:error, :not_found} = Littleagent.get_run("missing-run")
  end

  test "times out a hanging tool" do
    registry = Littleagent.Tools.Registry.new([Littleagent.TestSupport.HangingTool])

    assert {:error, :tool_timeout} =
             Littleagent.Tools.Executor.execute_with_timeout(registry, "hang", nil, %{}, 1)
  end

  test "denies tools outside the run allowlist" do
    adapter =
      Littleagent.Model.Scripted.new([
        %{tool_calls: [%{id: "x", name: "echo", args: "no"}]},
        %{text: "done"}
      ])

    tools = Littleagent.Tools.Registry.new([Littleagent.Tools.Echo])

    {:ok, _run_id, _pid} =
      Littleagent.start_run("test",
        adapter: adapter,
        tools: tools,
        allowed_tools: [],
        subscriber: self()
      )

    assert_receive {:littleagent,
                    %{type: :tool_call_failed, payload: %{result: {:error, :tool_denied}}}}
  end

  test "tui session exposes loaded skills without their contents" do
    skill = %{
      name: "demo",
      path: "/tmp/demo/SKILL.md",
      description: "Demo",
      content: "secret",
      enabled: true,
      priority: 0,
      tags: []
    }

    session = Littleagent.TUI.Session.new(skills: [skill])

    {_session, {:skills, [^skill], []}} =
      Littleagent.TUI.Session.handle(session, {:command, "skills", ""})

    {_session, {:skills, [^skill], []}} =
      Littleagent.TUI.Session.handle(session, {:command, "skills", "demo"})

    {_session, {:skills, [^skill], []}} =
      Littleagent.TUI.Session.handle(session, {:command, "skills", "DEMO"})

    {_session, {:skills, [], []}} =
      Littleagent.TUI.Session.handle(session, {:command, "skills", "missing"})
  end

  test "reload-skills rescans configured roots" do
    root =
      Path.join(System.tmp_dir!(), "littleagent_reload_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(Path.join(root, "demo"))

    File.write!(
      Path.join([root, "demo", "SKILL.md"]),
      "---\nname: demo\ndescription: Demo\n---\nUse demo."
    )

    File.mkdir_p!(Path.join(root, "other"))

    File.write!(
      Path.join([root, "other", "SKILL.md"]),
      "---\nname: other\ndescription: Other\n---\nUse other."
    )

    session = Littleagent.TUI.Session.new(run_opts: [skill_roots: [root], skills: ["demo"]])

    {session, {:skills, skills, []}} =
      Littleagent.TUI.Session.handle(session, {:command, "reload-skills", ""})

    assert Enum.map(skills, & &1.name) == ["demo"]
    assert Enum.map(session.skills, & &1.name) == ["demo"]
  end

  test "cancel clears the active tui run" do
    session = Littleagent.TUI.Session.new(run_id: "missing-run")
    {session, :ok} = Littleagent.TUI.Session.handle(session, {:command, "cancel", ""})
    assert session.run_id == nil
  end

  test "cancel keeps a running tui id until cancellation completes" do
    run_id = "cancel-pending"

    {:ok, ^run_id, _pid} =
      Littleagent.start_run("wait",
        run_id: run_id,
        adapter: %Littleagent.TestSupport.BlockingAdapter{owner: self()},
        subscriber: self()
      )

    assert_receive {:model_started, _worker}

    {session, :ok} =
      Littleagent.TUI.Session.handle(Littleagent.TUI.Session.new(run_id: run_id), {
        :command,
        "cancel",
        ""
      })

    assert session.run_id == run_id
    assert_receive {:littleagent, %{run_id: ^run_id, type: :run_cancelled}}
  end

  test "status reports idle when no run is active" do
    session = Littleagent.TUI.Session.new()

    {_session, {:status, :idle}} =
      Littleagent.TUI.Session.handle(session, {:command, "status", ""})
  end

  test "exit cancels an active run" do
    session = Littleagent.TUI.Session.new(run_id: "active")

    Littleagent.RunStore.put(%{run_id: "active", status: :running, turns: 0, tool_calls: 0})

    {_session, :exit} = Littleagent.TUI.Session.handle(session, {:command, "exit", ""})
    Littleagent.delete_run("active")
  end

  test "runs command returns stored runs" do
    session = Littleagent.TUI.Session.new()
    {_session, {:runs, runs}} = Littleagent.TUI.Session.handle(session, {:command, "runs", ""})
    assert is_list(runs)
  end

  test "runs command accepts a limit" do
    session = Littleagent.TUI.Session.new()
    {_session, {:runs, runs}} = Littleagent.TUI.Session.handle(session, {:command, "runs", "0"})
    assert runs == []

    {_session, {:error, :invalid_run_limit}} =
      Littleagent.TUI.Session.handle(session, {:command, "runs", "many"})
  end

  test "skills and history reject non-string command arguments" do
    session = Littleagent.TUI.Session.new()

    {_session, {:error, :invalid_input}} =
      Littleagent.TUI.Session.handle(session, {:command, "skills", nil})

    {_session, {:error, :invalid_history_limit}} =
      Littleagent.TUI.Session.handle(session, {:command, "history", nil})

    {_session, {:error, :invalid_run_limit}} =
      Littleagent.TUI.Session.handle(session, {:command, "runs", nil})
  end

  test "history command returns the latest transcript" do
    message = Littleagent.Conversation.Message.new(:user, "hello")

    Littleagent.RunStore.put(%{
      run_id: "history",
      status: :completed,
      transcript: %{messages: [message]}
    })

    session = Littleagent.TUI.Session.new(run_id: "history")

    {_session, {:history, [^message]}} =
      Littleagent.TUI.Session.handle(session, {:command, "history", ""})

    {_session, {:history, []}} =
      Littleagent.TUI.Session.handle(session, {:command, "history", "0"})

    {_session, {:error, :invalid_history_limit}} =
      Littleagent.TUI.Session.handle(session, {:command, "history", "many"})

    Littleagent.delete_run("history")
  end

  test "clear resets completed conversation context" do
    session = Littleagent.TUI.Session.new(run_id: "completed")
    Littleagent.RunStore.put(%{run_id: "completed", status: :completed})
    {session, :clear} = Littleagent.TUI.Session.handle(session, {:command, "clear", ""})
    assert session.run_id == nil
    Littleagent.delete_run("completed")
  end

  test "run store can be cleared" do
    assert :ok = Littleagent.clear_runs()
    assert Littleagent.list_runs() == []
  end

  test "event serialization produces JSON-safe values" do
    event =
      Littleagent.Events.Event.new("run", 1, :run_failed, %{
        reason: {:exit_status, 1},
        nested: %{ok: true}
      })

    encoded = Littleagent.Events.Event.to_map(event)
    assert encoded.type == "run_failed"
    assert encoded.payload == %{"reason" => ["exit_status", 1], "nested" => %{"ok" => true}}
    assert is_list(:json.encode(encoded))
  end

  test "tui rejects a second prompt while a run is active" do
    Littleagent.RunStore.put(%{run_id: "active", status: :running, turns: 0, tool_calls: 0})

    session = Littleagent.TUI.Session.new(run_id: "active")

    {_session, {:error, :run_in_progress}} =
      Littleagent.TUI.Session.handle(session, {:prompt, "second"})

    Littleagent.delete_run("active")
  end

  test "tool descriptions include provider parameters" do
    [description] =
      Littleagent.Tools.Registry.descriptions(
        Littleagent.Tools.Registry.new([Littleagent.Tools.Echo])
      )

    assert description.parameters["properties"]["text"]["type"] == "string"
  end

  test "validates run options before starting a process" do
    assert {:error, :empty_prompt} = Littleagent.start_run("   ")
    assert {:error, :invalid_limit} = Littleagent.start_run("hello", max_turns: -1)
    assert {:error, :invalid_allowed_tools} = Littleagent.start_run("hello", allowed_tools: :none)
  end

  test "validates tool modules and duplicate names" do
    assert :ok = Littleagent.Tools.Registry.validate([Littleagent.Tools.Echo])

    assert {:error, :duplicate_tool_name} =
             Littleagent.Tools.Registry.validate([Littleagent.Tools.Echo, Littleagent.Tools.Echo])

    assert {:error, :invalid_tool} = Littleagent.Tools.Registry.validate([NotATool])
  end

  test "run_with_events returns ordered events" do
    assert {:ok, %{text: "hello"}, events} =
             Littleagent.run_with_events("hello",
               adapter: Littleagent.Model.Scripted.new([%{text: "hello"}])
             )

    assert Enum.map(events, & &1.type) == [
             :run_started,
             :message_delta,
             :message_completed,
             :run_completed
           ]

    assert Enum.map(events, & &1.seq) == [1, 2, 3, 4]
  end

  test "scripted streaming emits incremental deltas" do
    assert {:ok, %{text: "hello"}, events} =
             Littleagent.run_with_events("hello",
               adapter: Littleagent.Model.Scripted.new([%{text: "hello"}]),
               stream: true
             )

    assert Enum.count(events, &(&1.type == :message_delta)) == 5
    assert Enum.take(events, -2) |> Enum.map(& &1.type) == [:message_completed, :run_completed]
    assert Enum.find(events, &(&1.type == :message_completed)).payload == %{text: "hello"}
  end

  test "scripted streaming advances after a tool call" do
    adapter =
      Littleagent.Model.Scripted.new([
        %{tool_calls: [%{id: "echo-stream", name: "echo", args: "hello"}]},
        %{text: "done"}
      ])

    assert {:ok, %{text: "done"}, events} =
             Littleagent.run_with_events("use echo",
               adapter: adapter,
               stream: true,
               tools: Littleagent.Tools.Registry.new([Littleagent.Tools.Echo])
             )

    assert Enum.count(events, &(&1.type == :tool_call_started)) == 1
    assert Enum.count(events, &(&1.type == :tool_call_completed)) == 1
    assert Enum.count(events, &(&1.type == :message_completed)) == 1
    assert {:ok, snapshot} = Littleagent.get_run(hd(events).run_id)
    assert snapshot.turns == 2

    assert Enum.map(snapshot.transcript.messages, & &1.role) == [
             :user,
             :assistant,
             :tool,
             :assistant
           ]
  end

  test "tool responses preserve assistant text" do
    adapter =
      Littleagent.Model.Scripted.new([
        %{text: "I will check", tool_calls: [%{id: "echo-text", name: "echo", args: "hi"}]},
        %{text: "done"}
      ])

    tools = Littleagent.Tools.Registry.new([Littleagent.Tools.Echo])

    assert {:ok, %{text: "done"}, events} =
             Littleagent.run_with_events("check", adapter: adapter, tools: tools)

    assert Enum.any?(events, &(&1.type == :message_delta and &1.payload.text == "I will check"))
    run_id = hd(events).run_id
    assert {:ok, snapshot} = Littleagent.get_run(run_id)
    assert Enum.at(snapshot.transcript.messages, 1).content == "I will check"
  end

  test "streaming output limit emits no deltas before failure" do
    assert {:error, %{reason: :max_output_chars}, events} =
             Littleagent.run_with_events("hello",
               adapter: Littleagent.Model.Scripted.new([%{text: "hello"}]),
               stream: true,
               max_output_chars: 3
             )

    refute Enum.any?(events, &(&1.type == :message_delta))
  end

  test "tool results are bounded before transcript insertion" do
    adapter =
      Littleagent.Model.Scripted.new([
        %{tool_calls: [%{id: "echo", name: "echo", args: String.duplicate("x", 20)}]},
        %{text: "done"}
      ])

    tools = Littleagent.Tools.Registry.new([Littleagent.Tools.Echo])

    {:ok, run_id, _pid} =
      Littleagent.start_run("tool",
        adapter: adapter,
        tools: tools,
        max_output_chars: 5,
        subscriber: self()
      )

    assert_receive {:littleagent,
                    %{
                      run_id: ^run_id,
                      type: :tool_call_completed,
                      payload: %{result: {:ok, bounded}}
                    }}

    assert String.length(bounded) <= 6
    assert_receive {:littleagent, %{run_id: ^run_id, type: :run_completed}}
  end

  test "completed run snapshots remain available" do
    {:ok, run_id, _pid} =
      Littleagent.start_run("hello",
        adapter: Littleagent.Model.Scripted.new([%{text: "hello"}]),
        subscriber: self()
      )

    assert_receive {:littleagent, %{run_id: ^run_id, type: :run_started}}
    assert_receive {:littleagent, %{run_id: ^run_id, type: :message_delta}}
    assert_receive {:littleagent, %{run_id: ^run_id, type: :run_completed}}
    assert {:ok, %{status: :completed, turns: 1}} = Littleagent.get_run(run_id)
  end

  test "list_runs returns stored snapshots" do
    {:ok, run_id, _pid} =
      Littleagent.start_run("hello",
        adapter: Littleagent.Model.Scripted.new([%{text: "hello"}]),
        subscriber: self()
      )

    assert_receive {:littleagent, %{run_id: ^run_id, type: :run_completed}}
    assert Enum.any?(Littleagent.list_runs(), &(&1.run_id == run_id))
  end

  test "supports injectable tool approval" do
    adapter =
      Littleagent.Model.Scripted.new([
        %{tool_calls: [%{id: "x", name: "echo", args: "no"}]},
        %{text: "done"}
      ])

    tools = Littleagent.Tools.Registry.new([Littleagent.Tools.Echo])
    approval = fn "echo", _args -> :deny end

    {:ok, _run_id, _pid} =
      Littleagent.start_run("test",
        adapter: adapter,
        tools: tools,
        approve_tool: approval,
        subscriber: self()
      )

    assert_receive {:littleagent,
                    %{type: :tool_call_failed, payload: %{result: {:error, :tool_denied}}}}
  end

  test "file_read is bounded to the workspace" do
    root = Path.join(System.tmp_dir!(), "littleagent_read_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "hello.txt"), "hello")

    assert {:ok, "hello"} =
             Littleagent.Tools.FileRead.execute(%{"path" => "hello.txt"}, workspace: root)

    assert {:error, :path_outside_workspace} =
             Littleagent.Tools.FileRead.execute(%{"path" => "../secret"}, workspace: root)

    assert {:error, :invalid_max_bytes} =
             Littleagent.Tools.FileRead.execute(%{"path" => "hello.txt"},
               workspace: root,
               max_bytes: -1
             )
  end

  test "file_read receives the run workspace" do
    root =
      Path.join(System.tmp_dir!(), "littleagent_run_read_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.write!(Path.join(root, "hello.txt"), "hello")

    adapter =
      Littleagent.Model.Scripted.new([
        %{tool_calls: [%{id: "read", name: "file_read", args: %{"path" => "hello.txt"}}]},
        %{text: "done"}
      ])

    tools = Littleagent.Tools.Registry.new([Littleagent.Tools.FileRead])

    assert {:ok, %{text: "done"}} =
             Littleagent.run("read it", adapter: adapter, tools: tools, workspace: root)
  end

  test "file tools reject symlinks that escape the workspace" do
    root =
      Path.join(System.tmp_dir!(), "littleagent-symlink-#{System.unique_integer([:positive])}")

    outside =
      Path.join(System.tmp_dir!(), "littleagent-outside-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "secret")
    File.ln_s!(outside, Path.join(root, "link"))

    assert {:error, :path_outside_workspace} =
             Littleagent.Tools.FileRead.execute(%{"path" => "link/secret.txt"}, workspace: root)

    assert {:error, :path_outside_workspace} =
             Littleagent.Tools.FileWrite.execute(%{"path" => "link/new.txt", "content" => "x"},
               workspace: root
             )

    assert {:ok, []} = Littleagent.Tools.FileList.execute(%{}, workspace: root)
    File.rm_rf!(root)
    File.rm_rf!(outside)
  end

  test "file_write stays inside the workspace" do
    root =
      Path.join(System.tmp_dir!(), "littleagent_run_write_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    assert {:ok, "written"} =
             Littleagent.Tools.FileWrite.execute(%{"path" => "new.txt", "content" => "hello"},
               workspace: root
             )

    assert {:ok, "written"} =
             Littleagent.Tools.FileWrite.execute(
               %{"path" => "nested/deep/new.txt", "content" => "hello"},
               workspace: root
             )

    assert File.read!(Path.join(root, "new.txt")) == "hello"

    assert {:error, :path_outside_workspace} =
             Littleagent.Tools.FileWrite.execute(%{"path" => "../bad", "content" => "x"},
               workspace: root
             )

    assert {:error, :invalid_max_bytes} =
             Littleagent.Tools.FileWrite.execute(
               %{"path" => "ok.txt", "content" => "x"},
               workspace: root,
               max_bytes: "large"
             )
  end

  test "file_write works through the agent loop" do
    root =
      Path.join(System.tmp_dir!(), "littleagent_loop_write_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    adapter =
      Littleagent.Model.Scripted.new([
        %{
          tool_calls: [
            %{id: "write", name: "file_write", args: %{"path" => "out.txt", "content" => "ok"}}
          ]
        },
        %{text: "done"}
      ])

    tools = Littleagent.Tools.Registry.new([Littleagent.Tools.FileWrite])

    assert {:ok, %{text: "done"}} =
             Littleagent.run("write", adapter: adapter, tools: tools, workspace: root)

    assert File.read!(Path.join(root, "out.txt")) == "ok"
  end

  test "file_list returns workspace-relative files" do
    root = Path.join(System.tmp_dir!(), "littleagent_list_#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "nested"))
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "nested/one.txt"), "one")

    assert {:ok, ["nested/one.txt"]} = Littleagent.Tools.FileList.execute(%{}, workspace: root)

    File.write!(Path.join(root, "z.txt"), "z")
    File.write!(Path.join(root, "a.txt"), "a")

    assert {:ok, ["a.txt", "nested/one.txt", "z.txt"]} =
             Littleagent.Tools.FileList.execute(%{}, workspace: root)

    assert {:error, :invalid_max_entries} =
             Littleagent.Tools.FileList.execute(%{}, workspace: root, max_entries: -1)
  end

  test "file_list terminates on directory symlink cycles" do
    root = Path.join(System.tmp_dir!(), "littleagent_cycle_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "nested"))
    File.write!(Path.join(root, "nested/one.txt"), "one")
    File.ln_s!(root, Path.join([root, "nested", "back"]))

    assert {:ok, files} = Littleagent.Tools.FileList.execute(%{}, workspace: root)
    assert "nested/one.txt" in files
    assert Enum.count(files) == 1
    File.rm_rf!(root)
  end

  test "shell runs in the configured workspace" do
    root = Path.join(System.tmp_dir!(), "littleagent_shell_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    assert {:ok, output} = Littleagent.Tools.Shell.execute(%{"command" => "pwd"}, workspace: root)
    assert Path.basename(String.trim(output)) == Path.basename(root)
  end

  test "shell accepts an explicit environment" do
    assert {:ok, "littleagent-test"} =
             Littleagent.Tools.Shell.execute(%{"command" => "printf $LITTLEAGENT_TEST"},
               env: [{"LITTLEAGENT_TEST", "littleagent-test"}]
             )
  end

  test "shell validates output limits" do
    assert {:error, :invalid_max_output_bytes} =
             Littleagent.Tools.Shell.execute(%{"command" => "printf ok"}, max_output_bytes: -1)
  end

  test "file_write rejects an empty path" do
    assert {:error, :expected_path_and_content} =
             Littleagent.Tools.FileWrite.validate(%{"path" => "", "content" => "text"})
  end

  test "run forwards tool context limits and environment" do
    adapter =
      Littleagent.Model.Scripted.new([
        %{tool_calls: [%{id: "shell", name: "shell", args: %{"command" => "printf $RUN_MODE"}}]},
        %{text: "done"}
      ])

    tools = Littleagent.Tools.Registry.new([Littleagent.Tools.Shell])

    assert {:ok, %{text: "done"}} =
             Littleagent.run("run",
               adapter: adapter,
               tools: tools,
               tool_context: %{env: [{"RUN_MODE", "test"}]}
             )
  end
end
