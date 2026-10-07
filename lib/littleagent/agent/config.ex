defmodule Littleagent.Agent.Config do
  @limits [
    :max_turns,
    :max_tool_calls,
    :max_output_chars,
    :max_elapsed_ms,
    :tool_timeout_ms,
    :timeout
  ]

  def validate(prompt, opts) when is_binary(prompt) do
    cond do
      String.trim(prompt) == "" ->
        {:error, :empty_prompt}

      Enum.any?(@limits, &invalid_limit?(opts, &1)) ->
        {:error, :invalid_limit}

      Keyword.get(opts, :allowed_tools, :all) != :all and
          not is_list(Keyword.get(opts, :allowed_tools)) ->
        {:error, :invalid_allowed_tools}

      Keyword.has_key?(opts, :tool_context) and not is_map(Keyword.get(opts, :tool_context)) ->
        {:error, :invalid_tool_context}

      Keyword.has_key?(opts, :workspace) and not is_binary(Keyword.get(opts, :workspace)) ->
        {:error, :invalid_workspace}

      Keyword.has_key?(opts, :approve_tool) and
          not is_function(Keyword.get(opts, :approve_tool), 2) ->
        {:error, :invalid_approval_callback}

      Keyword.has_key?(opts, :skills) and
          not (is_list(Keyword.get(opts, :skills)) and
                   Enum.all?(Keyword.get(opts, :skills), &is_binary/1)) ->
        {:error, :invalid_skills}

      Keyword.has_key?(opts, :skill_roots) and
          not (is_list(Keyword.get(opts, :skill_roots)) and
                   Enum.all?(Keyword.get(opts, :skill_roots), &is_binary/1)) ->
        {:error, :invalid_skill_roots}

      Keyword.has_key?(opts, :messages) and not is_list(Keyword.get(opts, :messages)) ->
        {:error, :invalid_messages}

      Keyword.has_key?(opts, :run_id) and
          not (is_binary(Keyword.get(opts, :run_id)) and Keyword.get(opts, :run_id) != "") ->
        {:error, :invalid_run_id}

      Keyword.has_key?(opts, :adapter) and not valid_adapter?(Keyword.get(opts, :adapter)) ->
        {:error, :invalid_adapter}

      true ->
        :ok
    end
  end

  def validate(_, _), do: {:error, :invalid_prompt}

  defp invalid_limit?(opts, key) do
    case Keyword.get(opts, key) do
      nil -> false
      value -> not (is_integer(value) and value >= 0)
    end
  end

  defp valid_adapter?(adapter) when is_atom(adapter) do
    Code.ensure_loaded(adapter)
    function_exported?(adapter, :complete, 3) or function_exported?(adapter, :complete, 2)
  end

  defp valid_adapter?(%{__struct__: module}) when is_atom(module) do
    Code.ensure_loaded(module)
    function_exported?(module, :complete, 3)
  end

  defp valid_adapter?(_), do: false
end
