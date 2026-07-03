defmodule Op.Retry do
  defstruct [:policy, :body]
end

defmodule Op.Recover do
  defstruct [:body, :fallback]
end

defmodule Op.Skip do
  defstruct [:body]
end
