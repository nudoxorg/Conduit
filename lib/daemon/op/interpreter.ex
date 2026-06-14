defmodule Daemon.Op.Interpreter do
  defstruct [:personality, slots: %{}, tools: []]

  def build(%Daemon.Op.Program{manifest: manifest}) do
    slots =
      manifest.slots
      |> Enum.map(&{&1.name, nil})
      |> Map.new()

    %__MODULE__{
      personality: manifest.personality,
      slots: slots,
      tools: manifest.personality.tools
    }
  end
end
