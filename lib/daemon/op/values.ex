defmodule Op.Constant do
  defstruct [:ty, :value]
end

defmodule Op.Nop do
  defstruct []
end

defmodule Op.SlotGet do
  defstruct [:slot]
end

defmodule Op.SlotSet do
  defstruct [:slot, :value]
end

defmodule Op.ParamGet do
  defstruct [:param]
end

defmodule Op.Literal do
  defstruct [:value]
end
