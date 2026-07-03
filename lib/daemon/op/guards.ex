defmodule Op.Guard do
  defstruct [:phase, :check, :feedback, :max_attempts, :on_exhausted, :body]
end
