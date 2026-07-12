defmodule Daemon.LLM.ToolCall do
  @moduledoc """
  A single tool invocation requested by the LLM.

  Built up during stream collection and passed back through `Daemon.LLM.Response`
  to the agent loop, which dispatches the call and feeds results back.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          args: map()
        }

  defstruct [:id, :name, :args]
end

defmodule Daemon.LLM.Response do
  @moduledoc """
  Unified response returned by all provider `stream/3` calls.

  `finish_reason` drives the agent loop:

    * `:end_turn`   — the model finished naturally; `content` holds the reply
    * `:tool_calls` — the model wants tools; `tool_calls` holds what to run

  Both fields are always present. When `finish_reason` is `:end_turn`,
  `tool_calls` is `[]`. When `:tool_calls`, `content` may be empty or hold
  any text the model emitted before requesting the tools.
  """

  @type finish_reason :: :end_turn | :tool_calls

  @type t :: %__MODULE__{
          content: String.t(),
          finish_reason: finish_reason(),
          tool_calls: [Daemon.LLM.ToolCall.t()],
          model: String.t() | nil,
          usage: map() | nil
        }

  defstruct [
    :model,
    :usage,
    content: "",
    finish_reason: :end_turn,
    tool_calls: []
  ]
end
