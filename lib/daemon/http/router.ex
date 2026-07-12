defmodule Daemon.HTTP.Router do
  @moduledoc """
  HTTP router for the Agent Control Daemon.

  ## Endpoints

      GET  /health                   Liveness check
      POST /sessions/:id/run         Start or re-run a session with a program
      GET  /sessions/:id/events      SSE stream of session events
      POST /sessions/:id/resume      Reply to a suspended Interrupt op
  """

  use Plug.Router
  require Logger

  plug(Plug.Logger)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, ~s({"status":"ok"}))
  end

  post "/sessions/:id/run" do
    case Daemon.Manifest.decode(conn.body_params) do
      {:ok, manifest} ->
        ensure_session(id)
        Daemon.Session.run(id, manifest)
        Logger.info("session=#{id} run started")
        send_resp(conn, 200, ~s({"status":"ok"}))

      {:error, reason} ->
        Logger.warning("session=#{id} decode failed reason=#{inspect(reason)}")
        send_resp(conn, 400, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  get "/sessions/:id/events" do
    Logger.info("session=#{id} SSE stream opened")
    ensure_session(id)
    Daemon.HTTP.EventStream.call(conn, id)
  end

  post "/sessions/:id/resume" do
    value = conn.body_params["value"] || conn.body_params["reply"]
    Daemon.Session.resume(id, value)
    Logger.info("session=#{id} resumed value=#{inspect(value)}")
    send_resp(conn, 200, ~s({"status":"ok"}))
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp ensure_session(id) do
    case Daemon.Session.Supervisor.start_session(id) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise "failed to start session #{id}: #{inspect(reason)}"
    end
  end
end
