defmodule Daemon.Manifest do
  @moduledoc """
  The program a client sends to the daemon.

  `entry` is the root op to execute. `routines` is a map of named sub-programs
  callable via `Invoke`. `personality` holds the system prompt and model config.
  """

  defstruct [:entry, :routines, :personality]
end
