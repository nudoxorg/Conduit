defmodule Daemon.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Daemon.PubSub},
      {Registry, keys: :unique, name: Daemon.SessionRegistry},
      {DynamicSupervisor, name: Daemon.SessionSupervisor, strategy: :one_for_one},
      {Bandit, plug: Daemon.HTTP.Router, port: 4000}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Daemon.Supervisor)
  end
end
