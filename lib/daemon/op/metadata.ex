defmodule Op.Strategy do
  defstruct [:strategy, :body]
end

defmodule Op.WithPersonality do
  defstruct [:personality, :body]
end

defmodule Op.Budget do
  defstruct [:tokens, :body]
end

defmodule Op.Sandbox do
  defstruct [:allowed_tools, :body]
end
