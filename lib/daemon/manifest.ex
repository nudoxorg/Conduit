defmodule Daemon.Manifest do
  @moduledoc """
  The program a client sends to the daemon.

  `entry` is the root op to execute. `routines` is a map of named sub-programs
  callable via `Invoke`. `personality` holds the system prompt and model config.
  """

  defstruct [:entry, :routines, :personality]

  @doc """
  Decodes the outer program envelope sent by clients.

  Expects the shape:
      %{"program" => %{"manifest" => %{"personality" => ...}, "body" => op_map}}

  Routines, if present, live under `program.manifest.routines` as a map of
  name → op map and are decoded individually.
  """
  @spec decode(map()) :: {:ok, %__MODULE__{}} | {:error, term()}
  def decode(%{"program" => program}) do
    manifest = program["manifest"] || %{}
    personality = Daemon.Personality.decode(manifest["personality"])
    raw_routines = manifest["routines"] || %{}

    with {:ok, entry} <- Daemon.Op.Decoder.decode(program["body"]),
         {:ok, routines} <- decode_routines(raw_routines) do
      {:ok, %__MODULE__{entry: entry, routines: routines, personality: personality}}
    end
  end

  def decode(other), do: {:error, {:invalid_program, other}}

  defp decode_routines(raw) when is_map(raw) do
    Enum.reduce_while(raw, {:ok, %{}}, fn {name, op_map}, {:ok, acc} ->
      case Daemon.Op.Decoder.decode(op_map) do
        {:ok, op} -> {:cont, {:ok, Map.put(acc, name, op)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
end
