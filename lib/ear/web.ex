defmodule Ear.Web do
  @moduledoc "Local Phoenix web interface for a shared agent conversation."
  use Supervisor

  def start_link(opts \\ []) do
    with {:ok, opts} <- Ear.Config.User.prepare_tui(opts) do
      workspace = Ear.TUI.workspace(opts)

      if File.dir?(workspace) do
        opts =
          opts
          |> Keyword.put(:workspace, workspace)
          |> Keyword.put_new(:stream, true)
          |> Keyword.put_new(:tool_modules, Ear.TUI.default_tool_modules())

        Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
      else
        {:error, {:invalid_workspace, workspace}}
      end
    end
  end

  @impl true
  def init(opts) do
    Application.put_env(:ear, Ear.Web.Endpoint,
      adapter: Bandit.PhoenixAdapter,
      http: [ip: {127, 0, 0, 1}, port: Keyword.get(opts, :port, 9000)],
      url: [host: "localhost"],
      server: true,
      secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64)),
      render_errors: [formats: [html: Ear.Web.ErrorHTML, json: Ear.Web.ErrorJSON], layout: false]
    )

    Supervisor.init([{Ear.Web.Session, opts}, Ear.Web.Endpoint], strategy: :one_for_one)
  end
end
