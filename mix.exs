defmodule Ear.MixProject do
  use Mix.Project

  def project do
    [
      app: :ear,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {Ear.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:yaml_elixir, "~> 2.11"},
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.0"},
      {:bandit, "~> 1.0"},
      {:jason, "~> 1.4"}
    ]
  end
end
