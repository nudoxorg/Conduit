defmodule Op.Then do
  defstruct [:first, :second, :keep]
end

defmodule Op.Map do
  defstruct [:inner, :transform]
end

defmodule Op.Choice do
  defstruct [:branches]
end

defmodule Op.Repeated do
  defstruct [:inner, :min, :max]
end

defmodule Op.Ignore do
  defstruct [:inner]
end

defmodule Op.Label do
  defstruct [:label, :body]
end

defmodule Op.Thought do
  defstruct [:text]
end

defmodule Op.Checkpoint do
  defstruct [:name]
end
