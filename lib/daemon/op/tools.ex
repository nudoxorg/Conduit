defmodule Op.CallTool do
  defstruct [:name, :args, :output]
end

defmodule Op.LoadContext do
  defstruct [:source]
end

defmodule Op.CompactContext do
  defstruct []
end

defmodule Op.ForgetAfter do
  defstruct [:mark]
end

defmodule Op.Pin do
  defstruct [:fact]
end
