defmodule Littleagent.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Littleagent.RunStore,
      {Task.Supervisor, name: Littleagent.TaskSupervisor},
      {Registry, keys: :unique, name: Littleagent.RunRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Littleagent.RunSupervisor}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :rest_for_one, name: Littleagent.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
