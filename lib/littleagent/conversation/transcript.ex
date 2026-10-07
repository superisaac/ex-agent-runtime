defmodule Littleagent.Conversation.Transcript do
  defstruct messages: []
  def new, do: %__MODULE__{}

  def append(%__MODULE__{messages: messages} = t, message),
    do: %{t | messages: messages ++ [message]}

  def last(%__MODULE__{messages: []}), do: nil
  def last(%__MODULE__{messages: messages}), do: List.last(messages)
  def to_list(%__MODULE__{messages: messages}), do: messages

  def estimate_chars(%__MODULE__{messages: messages}),
    do: Enum.reduce(messages, 0, &(String.length(to_string(&1.content)) + &2))
end
