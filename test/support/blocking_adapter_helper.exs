defmodule Littleagent.TestSupport.BlockingAdapter do
  defstruct [:owner]

  def complete(adapter, _request, _context) do
    send(adapter.owner, {:model_started, self()})

    receive do
      :release -> {:ok, %{text: "released"}}
    end
  end
end

defmodule Littleagent.TestSupport.HangingTool do
  @behaviour Littleagent.Tools.Tool
  def name, do: "hang"
  def description, do: "Hang forever"
  def validate(_), do: :ok

  def execute(_, _) do
    Process.sleep(:infinity)
    {:ok, :done}
  end
end
