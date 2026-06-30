defmodule Daemon.Llm.Gemini do
  @behaviour Daemon.LLM.Provider
  require Logger

  @impl true
  def complete(_plan, _messages), do: {:error, :not_implemented}

  @impl true
  def stream(_plan, _messages, _on_chunk), do: {:error, :not_implemented}
end
