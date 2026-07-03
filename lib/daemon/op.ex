defmodule Daemon.Op do
  @moduledoc """
  Union type covering all op variants in the ACD instruction set.

  Use `Daemon.Op.t()` in typespecs anywhere an op is accepted.
  Individual op structs live under `Op.*` in `lib/daemon/op/`.
  """

  @type t ::
          %Op.Constant{}
          | %Op.Nop{}
          | %Op.Literal{}
          | %Op.SlotGet{}
          | %Op.SlotSet{}
          | %Op.ParamGet{}
          | %Op.Timeout{}
          | %Op.Delay{}
          | %Op.TryUndo{}
          | %Op.Then{}
          | %Op.Map{}
          | %Op.Choice{}
          | %Op.Repeated{}
          | %Op.Ignore{}
          | %Op.Label{}
          | %Op.Thought{}
          | %Op.Checkpoint{}
          | %Op.Compare{}
          | %Op.When{}
          | %Op.While{}
          | %Op.ForEach{}
          | %Op.CallTool{}
          | %Op.LoadContext{}
          | %Op.CompactContext{}
          | %Op.ForgetAfter{}
          | %Op.Pin{}
          | %Op.Interrupt{}
          | %Op.Strategy{}
          | %Op.WithPersonality{}
          | %Op.Budget{}
          | %Op.Sandbox{}
          | %Op.Retry{}
          | %Op.Recover{}
          | %Op.Skip{}
          | %Op.Guard{}
          | %Op.Par{}
          | %Op.Race{}
          | %Op.FanOut{}
          | %Op.Invoke{}
          | %Op.Emit{}
          | %Op.AwaitSignal{}
          | %Op.OnSignal{}
          | %Op.Shadow{}
          | %Op.Ensemble{}
          | %Op.Sample{}
          | %Op.OnChunk{}
          | %Op.SpawnAgent{}
end
