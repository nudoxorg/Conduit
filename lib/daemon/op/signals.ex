defmodule Op.Emit do
  defstruct [:topic, :payload]
end

defmodule Op.AwaitSignal do
  defstruct [:topic]
end

defmodule Op.OnSignal do
  defstruct [:topic, :param, :body]
end
