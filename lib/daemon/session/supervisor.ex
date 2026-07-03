defmodule Daemon.Session.Supervisor do
  @moduledoc """
  Creates and supervises GenServer sessions at runtime. 
  """

  use DynamicSupervisor

  def start_link(_), do: DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)

  def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_session(id, parent_id \\ nil) do
    DynamicSupervisor.start_child(__MODULE__, {Daemon.Session, {id, parent_id}})
  end
end
