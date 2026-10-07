defmodule Ear.TUI.Session do
  @moduledoc "Small line-oriented interactive session over the agent API."
  alias Ear.TUI.{Command, Renderer}

  defstruct run_id: nil,
            skills: [],
            auth: nil,
            auth_adapter: Ear.Auth.Env,
            subscriber: nil,
            run_opts: [],
            skill_errors: [],
            running: true,
            renderer: Renderer

  def new(opts \\ []), do: struct!(__MODULE__, opts)

  def handle(%__MODULE__{} = session, {:prompt, prompt}) do
    if active_run?(session.run_id) do
      {session, {:error, :run_in_progress}}
    else
      subscriber = session.subscriber || self()

      run_opts =
        session.run_opts
        |> with_previous_messages(session.run_id)
        |> Keyword.put(:subscriber, subscriber)

      case Ear.start_run(prompt, run_opts) do
        {:ok, run_id, _pid} -> {%{session | run_id: run_id}, :ok}
        error -> {session, error}
      end
    end
  end

  def handle(%__MODULE__{} = session, {:command, "exit", _args}) do
    if session.run_id, do: Ear.cancel(session.run_id)
    {%{session | running: false}, :exit}
  end

  def handle(%__MODULE__{} = session, {:command, "quit", args}),
    do: handle(session, {:command, "exit", args})

  def handle(%__MODULE__{} = session, {:command, "cancel", _args}) do
    case session.run_id do
      nil ->
        {session, :ok}

      run_id ->
        result = Ear.cancel(run_id)

        if result == :ok, do: {session, :ok}, else: {%{session | run_id: nil}, :ok}
    end
  end

  def handle(%__MODULE__{} = session, {:command, "login", args}) do
    provider = if args == "", do: Keyword.get(session.run_opts, :provider, "default"), else: args
    configured_provider = Keyword.get(session.run_opts, :provider)
    configured? = provider == "default" or provider == configured_provider
    auth_opts = if configured?, do: %{api_env_key: session.run_opts[:api_env_key]}, else: %{}

    case safe_authenticate(session.auth_adapter, provider, auth_opts) do
      {:ok, auth} ->
        run_opts =
          if configured? or String.downcase(provider) == "openai" do
            adapter =
              case session.run_opts[:adapter] do
                %Ear.Model.OpenAI{} = adapter when configured? ->
                  %{
                    adapter
                    | api_key: System.get_env(session.run_opts[:api_env_key] || "OPENAI_API_KEY")
                  }

                _ ->
                  Ear.Model.OpenAI.new()
              end

            Keyword.put(session.run_opts, :adapter, adapter)
          else
            session.run_opts
          end

        {%{session | auth: auth, run_opts: run_opts}, {:message, "Logged in to #{provider}."}}

      {:error, reason} ->
        {session, {:error, reason}}
    end
  end

  def handle(session, {:command, "help", _}), do: {session, {:help, Command.help()}}

  def handle(%__MODULE__{run_id: run_id} = session, {:command, "clear", _}) do
    if active_run?(run_id), do: {session, :clear}, else: {%{session | run_id: nil}, :clear}
  end

  def handle(session, {:command, "skills", args}) when is_binary(args) do
    name = String.trim(args)

    skills =
      if name == "",
        do: session.skills,
        else: Enum.filter(session.skills, &(String.downcase(&1.name) == String.downcase(name)))

    {session, {:skills, skills, session.skill_errors}}
  end

  def handle(session, {:command, "skills", _args}), do: {session, {:error, :invalid_input}}

  def handle(session, {:command, "reload-skills", _args}) do
    roots = Keyword.get(session.run_opts, :skill_roots, [])
    {discovered, errors} = Ear.Skills.Loader.discover_report(roots)

    skills =
      case Keyword.get(session.run_opts, :skills) do
        nil -> discovered
        names -> Enum.filter(discovered, &(&1.name in names))
      end

    {%{session | skills: skills, skill_errors: errors}, {:skills, skills, errors}}
  end

  def handle(%__MODULE__{run_id: nil} = session, {:command, "status", _}),
    do: {session, {:status, :idle}}

  def handle(%__MODULE__{run_id: run_id} = session, {:command, "status", _}),
    do: {session, {:status, Ear.get_run(run_id)}}

  def handle(%__MODULE__{run_id: nil} = session, {:command, "history", args}) do
    case history_limit(args) do
      {:ok, _limit} -> {session, {:history, []}}
      :error -> {session, {:error, :invalid_history_limit}}
    end
  end

  def handle(%__MODULE__{run_id: run_id} = session, {:command, "history", args}) do
    case history_limit(args) do
      :error -> {session, {:error, :invalid_history_limit}}
      {:ok, limit} -> history_for(session, run_id, limit)
    end
  end

  def handle(session, {:command, "runs", ""}), do: {session, {:runs, Ear.list_runs()}}

  def handle(session, {:command, "runs", args}) when is_binary(args) do
    case Integer.parse(String.trim(args)) do
      {limit, ""} when limit >= 0 -> {session, {:runs, Ear.list_runs(limit)}}
      _ -> {session, {:error, :invalid_run_limit}}
    end
  end

  def handle(session, {:command, "runs", _args}), do: {session, {:error, :invalid_run_limit}}

  def handle(session, {:command, "clear-runs", _}), do: {session, Ear.clear_runs()}

  def handle(session, {:command, name, _}), do: {session, {:error, {:unknown_command, name}}}
  def handle(session, _), do: {session, {:error, :invalid_input}}
  def render_event(event), do: Renderer.render(event)

  defp authenticate(adapter, provider, opts) when is_atom(adapter),
    do: adapter.login(provider, opts)

  defp authenticate(adapter, provider, opts) when is_function(adapter, 2),
    do: adapter.(provider, opts)

  defp authenticate(_adapter, _provider, _opts), do: {:error, :invalid_auth_adapter}

  defp safe_authenticate(adapter, provider, opts) do
    authenticate(adapter, provider, opts)
  rescue
    exception -> {:error, {:auth_exception, exception}}
  catch
    :exit, reason -> {:error, {:auth_exit, reason}}
    :throw, value -> {:error, {:auth_throw, value}}
  end

  defp with_previous_messages(opts, nil), do: opts

  defp with_previous_messages(opts, run_id) do
    case Ear.get_run(run_id) do
      {:ok, %{transcript: %{messages: messages}}} -> Keyword.put(opts, :messages, messages)
      _ -> opts
    end
  end

  defp active_run?(nil), do: false

  defp active_run?(run_id) do
    case Ear.get_run(run_id) do
      {:ok, %{status: status}} when status in [:running, :pending] -> true
      _ -> false
    end
  end

  defp history_limit(""), do: {:ok, :all}

  defp history_limit(args) when is_binary(args) do
    case Integer.parse(String.trim(args)) do
      {limit, ""} when limit >= 0 -> {:ok, limit}
      _ -> :error
    end
  end

  defp history_limit(_args), do: :error

  defp history_for(session, run_id, :all) do
    case Ear.get_run(run_id) do
      {:ok, %{transcript: %{messages: messages}}} -> {session, {:history, messages}}
      _ -> {session, {:history, []}}
    end
  end

  defp history_for(session, run_id, limit) do
    case Ear.get_run(run_id) do
      {:ok, %{transcript: %{messages: messages}}} ->
        {session, {:history, Enum.take(messages, -limit)}}

      _ ->
        {session, {:history, []}}
    end
  end
end
