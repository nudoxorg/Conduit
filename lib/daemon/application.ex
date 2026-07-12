defmodule Daemon.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("ACD starting on port 4000")

    children = [
      {Finch, name: Daemon.Finch},
      {Phoenix.PubSub, name: Daemon.PubSub},
      {Registry, keys: :unique, name: Daemon.SessionRegistry},
      Daemon.Session.Supervisor,
      {Bandit, plug: Daemon.HTTP.Router, port: 4000}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Daemon.Supervisor)
  end
end
