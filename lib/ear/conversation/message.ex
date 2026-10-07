defmodule Ear.Conversation.Message do
  @enforce_keys [:role, :content]
  defstruct [:id, :role, :content, :tool_calls, :tool_call_id, metadata: %{}]
  @type t :: %__MODULE__{}
  def new(role, content, attrs \\ []) when role in [:system, :user, :assistant, :tool] do
    struct!(
      __MODULE__,
      Keyword.merge(
        [id: "msg_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)],
        attrs ++ [role: role, content: content]
      )
    )
  end
end
