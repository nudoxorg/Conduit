defmodule Daemon.LLM.Message do
  @moduledoc """
  Normalizes input into the internal chat message format used across providers.

  The internal format is string-keyed maps:

      %{"role" => "user",      "content" => "..."}
      %{"role" => "assistant", "content" => "...", "tool_calls" => [...]}
      %{"role" => "tool",      "tool_call_id" => "...", "content" => "..."}

  Accepts strings, atom-keyed maps, or string-keyed maps. Provider modules
  are responsible for any further translation to their wire format (e.g.
  Anthropic wraps tool results in user-role content blocks).
  """

  @type role :: :system | :user | :assistant | :tool
  @type t :: %{required(String.t()) => term()}

  @doc """
  Normalizes a string or list of messages into a list of message maps.

  A bare string becomes a single user message. An empty list falls back
  to a single empty user message.
  """
  @spec normalize(String.t() | [map()] | term()) :: [t()]
  def normalize(input) when is_binary(input) do
    [%{"role" => "user", "content" => input}]
  end

  def normalize(input) when is_list(input) do
    case input |> Enum.filter(&valid?/1) |> Enum.map(&normalize_message/1) do
      [] -> normalize("")
      messages -> messages
    end
  end

  def normalize(input), do: normalize(to_string(input))

  @doc """
  Returns `true` if the map looks like a valid chat message.

  Accepts both atom-keyed and string-keyed maps with a recognized role.
  """
  @spec valid?(map()) :: boolean()
  def valid?(%{role: role, content: content})
      when role in [:system, :user, :assistant, :tool] and is_binary(content),
      do: true

  def valid?(%{"role" => role, "content" => content}) when is_binary(content),
    do: role in ["system", "user", "assistant", "tool"]

  def valid?(_), do: false

  # --- private ---

  defp normalize_message(%{role: :tool, content: content} = msg) do
    base = %{"role" => "tool", "content" => content}

    case Map.get(msg, :tool_call_id) do
      nil -> base
      id -> Map.put(base, "tool_call_id", id)
    end
  end

  defp normalize_message(%{"role" => "tool", "content" => content} = msg) do
    base = %{"role" => "tool", "content" => content}

    case Map.get(msg, "tool_call_id") do
      nil -> base
      id -> Map.put(base, "tool_call_id", id)
    end
  end

  defp normalize_message(%{role: role, content: content}) do
    %{"role" => to_string(role), "content" => content}
  end

  defp normalize_message(%{"role" => role, "content" => content}) do
    %{"role" => role, "content" => content}
  end
end
