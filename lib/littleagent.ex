defmodule Littleagent do
  alias Littleagent.Agent.Loop
  alias Littleagent.Agent.Config

  def start_run(prompt, opts \\ [])

  def start_run(prompt, opts) when is_binary(prompt) do
    with :ok <- Config.validate(prompt, opts), do: do_start_run(prompt, opts)
  end

  def start_run(_prompt, _opts), do: {:error, :invalid_prompt}

  defp do_start_run(prompt, opts) do
    tools = Keyword.get(opts, :tool_modules, [])
    registry = Keyword.get(opts, :tools, %{})

    with :ok <- Littleagent.Tools.Registry.validate(tools),
         :ok <- Littleagent.Tools.Registry.validate(registry),
         :ok <- Littleagent.Tools.Registry.validate(Map.values(registry) ++ tools) do
      do_start_run_with_tools(prompt, opts, merge_tools(registry, tools))
    end
  end

  defp do_start_run_with_tools(prompt, opts, configured_tools) do
    run_id =
      Keyword.get(
        opts,
        :run_id,
        "run_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
      )

    adapter =
      Keyword.get(
        opts,
        :adapter,
        Littleagent.Model.OpenAI.new()
      )

    {skills, skill_errors} =
      Littleagent.Skills.Loader.discover_report(Keyword.get(opts, :skill_roots, []))

    selected_skills =
      case Keyword.get(opts, :skills) do
        nil -> skills
        names -> Enum.filter(skills, &(&1.name in names))
      end

    system_prompt = Littleagent.Skills.Prompt.build(selected_skills)
    tool_registry = configured_tools

    child =
      {Loop,
       [
         run_id: run_id,
         adapter: adapter,
         request: %{
           prompt: prompt,
           messages:
             Keyword.get(opts, :messages, []) ++
               [Littleagent.Conversation.Message.new(:user, prompt)],
           system_prompt: system_prompt,
           skills: Enum.map(selected_skills, & &1.name),
           skill_errors: skill_errors,
           tools: Littleagent.Tools.Registry.descriptions(tool_registry)
         },
         max_turns: Keyword.get(opts, :max_turns, 8),
         subscriber: Keyword.get(opts, :subscriber),
         tools: tool_registry,
         workspace: Keyword.get(opts, :workspace, File.cwd!()),
         tool_context: Keyword.get(opts, :tool_context, %{}),
         stream: Keyword.get(opts, :stream, false),
         max_tool_calls: Keyword.get(opts, :max_tool_calls, 16),
         max_output_chars: Keyword.get(opts, :max_output_chars, 100_000),
         tool_timeout_ms: Keyword.get(opts, :tool_timeout_ms, 30_000),
         allowed_tools: Keyword.get(opts, :allowed_tools, :all),
         approve_tool: Keyword.get(opts, :approve_tool, fn _name, _args -> :allow end),
         max_elapsed_ms: Keyword.get(opts, :max_elapsed_ms)
       ]}

    case DynamicSupervisor.start_child(Littleagent.RunSupervisor, child) do
      {:ok, pid} -> {:ok, run_id, pid}
      error -> error
    end
  end

  defp merge_tools(registry, []), do: registry

  defp merge_tools(registry, modules),
    do: Map.merge(registry, Littleagent.Tools.Registry.new(modules))

  def subscribe(run_id, subscriber \\ self()) do
    if not is_pid(subscriber) do
      {:error, :invalid_subscriber}
    else
      case Registry.lookup(Littleagent.RunRegistry, run_id) do
        [{pid, _}] ->
          Loop.subscribe(pid, subscriber)
          :ok

        [] ->
          {:error, :not_found}
      end
    end
  end

  def unsubscribe(run_id, subscriber \\ self()) do
    if not is_pid(subscriber) do
      {:error, :invalid_subscriber}
    else
      case Registry.lookup(Littleagent.RunRegistry, run_id) do
        [{pid, _}] ->
          Loop.unsubscribe(pid, subscriber)
          :ok

        [] ->
          {:error, :not_found}
      end
    end
  end

  def cancel(run_id) do
    case Registry.lookup(Littleagent.RunRegistry, run_id) do
      [{pid, _}] -> Loop.cancel(pid)
      [] -> {:error, :not_found}
    end
  end

  def get_run(run_id) do
    case Registry.lookup(Littleagent.RunRegistry, run_id) do
      [{pid, _}] ->
        try do
          {:ok, Loop.snapshot(pid)}
        catch
          :exit, _ -> stored_run(run_id)
        end

      [] ->
        stored_run(run_id)
    end
  end

  defp stored_run(run_id), do: Littleagent.RunStore.get(run_id)

  def list_runs do
    Littleagent.RunStore.list()
  end

  def list_runs(limit) when is_integer(limit) and limit >= 0 do
    Littleagent.RunStore.list(limit)
  end

  def list_runs(_limit), do: {:error, :invalid_limit}

  def delete_run(run_id), do: Littleagent.RunStore.delete(run_id)

  def clear_runs do
    Littleagent.RunStore.clear()
  end

  def run(prompt, opts \\ []) do
    case run_with_events(prompt, opts) do
      {:ok, payload, _events} -> {:ok, payload}
      {:error, payload, _events} -> {:error, payload}
      error -> error
    end
  end

  def run_with_events(prompt, opts \\ []) do
    with {:ok, run_id, _pid} <- start_run(prompt, Keyword.put(opts, :subscriber, self())) do
      deadline = System.monotonic_time(:millisecond) + (Keyword.get(opts, :timeout) || 30_000)
      collect(run_id, [], deadline)
    end
  end

  defp collect(run_id, events, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:littleagent, %{run_id: ^run_id} = event} ->
        if Littleagent.Events.Event.terminal?(event),
          do: terminal_result(event, Enum.reverse([event | events])),
          else: collect(run_id, [event | events], deadline)
    after
      remaining ->
        cancel(run_id)
        {:error, %{reason: :timeout}, Enum.reverse(events)}
    end
  end

  defp terminal_result(%{type: :run_completed, payload: payload}, events),
    do: {:ok, payload, events}

  defp terminal_result(%{payload: payload}, events), do: {:error, payload, events}
end
