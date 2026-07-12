defmodule Daemon.Session do
  @moduledoc """
  GenServer for one active agent session.

  Holds session state and acts as the message hub between the interpreter Task,
  SSE subscribers, and parent/child sessions. Does not execute ops itself —
  spawns a Task that runs `Daemon.Interpreter.run/3` and communicates back
  via messages. When the interpreter finishes, Session decides whether to
  feed the result into `Daemon.LLM.Loop` based on the run's personality.
  """

  use GenServer

  # `event_log` holds every event emitted for the current run so late-joining
  # subscribers (e.g. an SSE stream that dropped and reconnected mid-response)
  # can be replayed the events they missed. Cleared when a new run starts.
  defstruct [
    :id,
    :parent_id,
    :status,
    :interpreter_pid,
    subscribers: [],
    event_log: [],
    messages: []
  ]

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
      interpreter_pid: nil
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

    {:noreply, %{state | status: :running, interpreter_pid: interpreter_pid, event_log: []}}
  end

  def handle_cast({:resume, value}, state) do
    send(state.interpreter_pid, {:resume, value})
    {:noreply, state}
  end

  def handle_cast({:subscribe, pid}, state) do
    Enum.each(Enum.reverse(state.event_log), &send(pid, &1))
    {:noreply, %{state | subscribers: [pid | state.subscribers]}}
  end

  @impl true
  def handle_info({:op_result, result, personality}, state) do
    session_pid = self()

    case personality do
      %Daemon.Personality{use_llm: true} ->
        history = state.messages
        Task.start(fn -> Daemon.LLM.Loop.run(result, personality, session_pid, history) end)
        {:noreply, state}

      _ ->
        send(session_pid, {:finished, result})
        {:noreply, state}
    end
  end

  def handle_info({:event, _} = msg, state) do
    Enum.each(state.subscribers, &send(&1, msg))
    {:noreply, %{state | event_log: [msg | state.event_log]}}
  end

  def handle_info({:finished, _} = msg, state) do
    Enum.each(state.subscribers, &send(&1, msg))
    {:noreply, %{state | status: :finished, event_log: [msg | state.event_log]}}
  end

  def handle_info({:error, reason} = msg, state) do
    Enum.each(state.subscribers, &send(&1, msg))
    {:noreply, %{state | status: {:error, reason}, event_log: [msg | state.event_log]}}
  end

  def handle_info({:messages, msgs}, state) do
    {:noreply, %{state | messages: msgs}}
  end

  def handle_info({:suspend, :interrupt, id, prompt}, state) do
    msg = {:event, {:interrupt, id, prompt}}
    Enum.each(state.subscribers, &send(&1, msg))
    {:noreply, %{state | event_log: [msg | state.event_log]}}
  end

  # private

  defp via(id), do: {:via, Registry, {Daemon.SessionRegistry, id}}
end
