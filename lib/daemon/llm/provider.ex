defmodule Daemon.LLM.Provider do
  @moduledoc """
  Behaviour for LLM provider implementations.

  A **plan** is a plain map the agent loop builds from the session personality:

      %{
        provider: :anthropic | :openai,
        model:    "claude-opus-4-7",
        system:   "You are a helpful assistant...",
        tools:    ["shell", "read", "write"]   # names registered in Daemon.Tool
      }

  Each provider's `stream/3` must:

    1. Open a streaming request to the upstream API.
    2. Call `on_chunk.(text)` for every text delta as it arrives.
    3. Accumulate tool call data from the stream.
    4. Return `{:ok, %Response{}}` when the turn ends, with `finish_reason`
       set to `:end_turn` or `:tool_calls` accordingly.

  `dispatch/3` routes by `plan.provider`, defaulting to Anthropic.
  """

  alias Daemon.LLM.{Response, Error}

  @type plan :: %{
          required(:provider) => :anthropic | :openai,
          required(:model) => String.t(),
          required(:system) => String.t(),
          required(:tools) => [String.t()]
        }

  @callback stream(plan(), [map()], on_chunk :: (String.t() -> any())) :: {:ok, Response.t()} | {:error, Error.t()}

  @callback available?() :: boolean()

  @spec dispatch(plan(), [map()], (String.t() -> any())) :: {:ok, Response.t()} | {:error, Error.t()}
  def dispatch(plan, messages, on_chunk) do
    provider_mod(plan[:provider]).stream(plan, messages, on_chunk)
  end

  defp provider_mod(:openai), do: Daemon.LLM.OpenAI
  defp provider_mod(_), do: Daemon.LLM.Anthropic
end
