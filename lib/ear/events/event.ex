defmodule Ear.Events.Event do
  defstruct [:run_id, :seq, :type, :occurred_at, :payload, :tool_call_id, :parent_id]
  @terminal [:run_completed, :run_failed, :run_cancelled]
  def new(run_id, seq, type, payload \\ %{}, attrs \\ []),
    do:
      struct!(
        __MODULE__,
        Keyword.merge(
          [
            run_id: run_id,
            seq: seq,
            type: type,
            occurred_at: DateTime.utc_now(),
            payload: payload
          ],
          attrs
        )
      )

  def terminal?(%__MODULE__{type: type}), do: type in @terminal

  def to_map(%__MODULE__{} = event) do
    event
    |> Map.from_struct()
    |> Map.update!(:occurred_at, &DateTime.to_iso8601/1)
    |> Map.update!(:type, &Atom.to_string/1)
    |> Map.update!(:payload, &json_safe/1)
  end

  defp json_safe(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value

  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)

  defp json_safe(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&json_safe/1)

  defp json_safe(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_safe(item)} end)

  defp json_safe(value), do: inspect(value)
end
