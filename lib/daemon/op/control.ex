defmodule Op.Compare do
  defstruct [:kind, :lhs, :rhs]
end

defmodule Op.When do
  defstruct [:condition, :body]
end

defmodule Op.While do
  defstruct [:condition, :body]
end

defmodule Op.ForEach do
  defstruct [:over, :param, :body]
end
