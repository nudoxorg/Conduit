defmodule Daemon.MixProject do
  use Mix.Project

  def project do
    [
      app: :daemon,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Daemon.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # HTTP server
      {:bandit, "~> 1.8"},
      {:plug, "~> 1.16"},
      # HTTP client (llm calls)
      {:req, "~> 0.5"},
      {:finch, "~> 0.18"},
      {:castore, "~> 1.0"},
      # JSON
      {:jason, "~> 1.4"},
      # event fan-out for SSE
      {:phoenix_pubsub, "~> 2.2"}
    ]
  end
end
