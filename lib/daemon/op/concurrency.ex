defmodule Op.Par do
  defstruct [:branches]
end

defmodule Op.Race do
  defstruct [:branches]
end

defmodule Op.FanOut do
  defstruct [:over, :param, :body, :join]
end
