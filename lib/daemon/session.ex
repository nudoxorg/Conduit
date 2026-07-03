defmodule Daemon.Session do
  @moduledoc """
  GenServer for one active agent session.

  Holds session state and acts as the message hub between the interpreter Task,
  SSE subscribers, and parent/child sessions. Does not execute ops itself —
  spawns a Task that runs `Daemon.Interpreter.run/3` and communicates back
  via messages.
  """

  use GenServer

  defstruct [:id, :parent_id, :status, :interpreter_pid, :subscribers]

  # public API

  def start_link({id, parent_id}) do
    GenServer.start_link(__MODULE__, {id, parent_id}, name: via(id))
  end

  def run(session_id, manifest) do
    GenServer.cast(via(session_id), {:run, manifest})
  end

  def resume(session_id, value) do
    GenServer.cast(via(session_id), {:resume, value})
  end

  def subscribe(session_id, pid) do
    GenServer.cast(via(session_id), {:subscribe, pid})
  end

  # callbacks
  @impl true
  def init({id, parent_id}) do
    state = %__MODULE__{
      id: id,
      parent_id: parent_id,
      status: :idle,
      interpreter_pid: nil,
      subscribers: []
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:run, manifest}, state) do
    session_pid = self()

    task =
      Task.start_link(fn ->
        Daemon.Interpreter.run(manifest, session_pid, state.id)
      end)

    {:ok, interpreter_pid} = task

    {:noreply, %{state | status: :running, interpreter_pid: interpreter_pid}}
  end

  def handle_cast({:resume, value}, state) do
    send(state.interpreter_pid, {:resume, value})
    {:noreply, state}
  end

  def handle_cast({:subscribe, pid}, state) do
    {:noreply, %{state | subscribers: [pid | state.subscribers]}}
  end

  @impl true
  def handle_info({:event, event}, state) do
    Enum.each(state.subscribers, &send(&1, {:event, event}))
    {:noreply, state}
  end

  def handle_info({:finished, result}, state) do
    if state.parent_id do
      [{parent_pid, _}] = Registry.lookup(Daemon.SessionRegistry, state.parent_id)
      send(parent_pid, {:child_finished, state.id, result})
    end

    {:noreply, %{state | status: :finished}}
  end

  def handle_info({:error, reason}, state) do
    {:noreply, %{state | status: {:error, reason}}}
  end

  # private

  defp via(id), do: {:via, Registry, {Daemon.SessionRegistry, id}}
end
