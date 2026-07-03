defmodule Op.Timeout do
  defstruct [:ms, :body]
end

defmodule Op.Delay do
  defstruct [:ms]
end

defmodule Op.TryUndo do
  defstruct [:body, :undo]
end
