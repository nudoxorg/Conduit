defmodule Daemon.Interpreter.Context do
  @moduledoc """
  Execution state struct.
  """

  defstruct [
    :session_id,
    :session_pid,
    :manifest,
    :personality,
    slots: %{},
    params: %{},
    history: [],
    allowed_tools: :all,
    token_budget: :unlimited
  ]
end
