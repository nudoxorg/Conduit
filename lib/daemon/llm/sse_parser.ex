defmodule Daemon.LLM.SSEParser do
  @moduledoc """
  Parses Server-Sent Event lines from streaming LLM API responses.

  Handles the two wire formats used by Anthropic and OpenAI:
  `data: <json>` payloads and the `data: [DONE]` terminator.
  """

  @doc """
  Parses a single SSE line.

  Returns `{:ok, decoded_map}` for data lines with valid JSON,
  `:done` for the `[DONE]` terminator, or `:ignore` for everything else
  (blank lines, `event:` lines, comments, malformed JSON).
  """
  @spec parse_line(String.t()) :: {:ok, map()} | :done | :ignore
  def parse_line("data: [DONE]"), do: :done

  def parse_line("data: " <> json) do
    case Jason.decode(json) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> :ignore
    end
  end

  def parse_line(_), do: :ignore
end
