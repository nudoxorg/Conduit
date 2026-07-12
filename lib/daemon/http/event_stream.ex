defmodule Daemon.HTTP.EventStream do
  @moduledoc """
  SSE handler for a session event stream.

  Subscribes the calling process to the session's event feed, then holds
  the HTTP connection open and writes each event as a `data: <json>` SSE
  frame. The connection stays open across `finished` and `error` events so
  the same stream can serve subsequent runs on the session. It only ends
  if the client disconnects (`Plug.Conn.chunk/2` returns `{:error, _}`).

  A keepalive comment is sent every 30 seconds so load balancers and
  clients don't consider the connection stale.
  """

  @keepalive_ms 30_000

  def call(conn, session_id) do
    Daemon.Session.subscribe(session_id, self())

    conn
    |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
    |> Plug.Conn.put_resp_header("cache-control", "no-cache")
    |> Plug.Conn.put_resp_header("access-control-allow-origin", "*")
    |> Plug.Conn.send_chunked(200)
    |> loop()
  end

  # --- private ---

  defp loop(conn) do
    receive do
      {:finished, result} ->
        continue(conn, %{type: "finished", content: to_string(result)})

      {:error, reason} ->
        continue(conn, %{type: "error", reason: inspect(reason)})

      {:event, event} ->
        continue(conn, format(event))

      _ ->
        loop(conn)
    after
      @keepalive_ms ->
        case Plug.Conn.chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> loop(conn)
          {:error, _} -> conn
        end
    end
  end

  defp continue(conn, payload) do
    case Plug.Conn.chunk(conn, "data: #{Jason.encode!(payload)}\n\n") do
      {:ok, conn} -> loop(conn)
      {:error, _} -> conn
    end
  end

  # --- event formatters ---

  defp format({:thought, text}),
    do: %{type: "thought", text: text}

  defp format({:checkpoint, name}),
    do: %{type: "checkpoint", name: name}

  defp format({:tool_started, name}),
    do: %{type: "tool_started", name: name}

  defp format({:tool_completed, name, result}),
    do: %{type: "tool_completed", name: name, result: result}

  defp format({:interrupt, id, prompt}),
    do: %{type: "intervention_required", id: id, prompt: prompt}

  # agent loop events
  defp format({:text_delta, text}),
    do: %{type: "text_delta", content: text}

  defp format({:agent_spawned, agent_id}),
    do: %{type: "agent_spawned", agent_id: agent_id}

  defp format({:agent_finished, agent_id, result}),
    do: %{type: "agent_finished", agent_id: agent_id, result: result}

  defp format(unknown),
    do: %{type: "unknown", payload: inspect(unknown)}
end
