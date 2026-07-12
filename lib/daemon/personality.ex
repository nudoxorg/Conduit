defmodule Daemon.Personality do
  @moduledoc """
  Behavioral and provider config for an agent session or op scope.

  Decoded once from the JSON `personality` object in a program's manifest
  (or from an `Op.WithPersonality` op). Every consumer downstream reads
  typed struct fields rather than reaching into a raw map.
  """

  defstruct use_llm: false,
            provider: :anthropic,
            model: nil,
            system: nil,
            tools: []

  @type t :: %__MODULE__{
          use_llm: boolean(),
          provider: :anthropic | :openai,
          model: String.t() | nil,
          system: String.t() | nil,
          tools: [String.t()]
        }

  @doc """
  Decodes a raw personality map (as sent by clients) into a struct.

  Accepts `nil` and returns defaults so callers don't need to guard.
  """
  @spec decode(map() | nil | t()) :: t()
  def decode(nil), do: %__MODULE__{}
  def decode(%__MODULE__{} = p), do: p

  def decode(raw) when is_map(raw) do
    %__MODULE__{
      use_llm: raw["use_llm"] == true,
      provider: decode_provider(raw["provider"]),
      model: raw["model"],
      system: raw["system"] || raw["starter_prompt"],
      tools: raw["tools"] || []
    }
  end

  defp decode_provider("openai"), do: :openai
  defp decode_provider(_), do: :anthropic
end
