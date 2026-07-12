defmodule Daemon.LLM.Error do
  @moduledoc """
  Standardized error struct for all LLM providers.

  ## Error types

    * `:connection`     — network or transport failure
    * `:authentication` — missing or invalid API key
    * `:rate_limit`     — quota or rate limit exceeded
    * `:timeout`        — request or stream timed out
    * `:provider_error` — provider returned an error status

  ## Usage

      Error.new(:authentication, message: "ANTHROPIC_API_KEY not set", provider: :anthropic)
      Error.wrap(:provider_error, raw_body, message: "HTTP 500", provider: :openai)
  """

  @type error_type :: :connection | :authentication | :rate_limit | :timeout | :provider_error

  @type t :: %__MODULE__{
          type: error_type(),
          message: String.t() | nil,
          provider: atom() | nil,
          details: term() | nil
        }

  @enforce_keys [:type]
  defstruct [:type, :message, :provider, :details]

  @valid_types [:connection, :authentication, :rate_limit, :timeout, :provider_error]

  @spec new(error_type(), keyword()) :: t()
  def new(type, opts \\ []) when type in @valid_types do
    struct(__MODULE__, [{:type, type} | opts])
  end

  @spec wrap(error_type(), term(), keyword()) :: t()
  def wrap(type, original, opts \\ []) do
    new(type, Keyword.put(opts, :details, original))
  end
end
