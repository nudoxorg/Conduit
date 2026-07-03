defmodule Op.Shadow do
  defstruct [:threshold, :body]
end

defmodule Op.Ensemble do
  defstruct [:count, :body, :voter]
end

defmodule Op.Sample do
  defstruct [:choices]
end

defmodule Op.OnChunk do
  defstruct [:body]
end
