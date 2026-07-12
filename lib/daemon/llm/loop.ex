defmodule Daemon.LLM.Loop do
  @moduledoc """
  The agent loop — feeds op tree output into an LLM provider and drives the
  tool-call / respond cycle until the model reaches end_turn.

  Called by the interpreter when the session personality has `use_llm: true`.
  The entry op's result becomes the first user message; the loop continues
  until the provider signals `:end_turn`, then sends `{:finished, text}` to
  the session process.

  Events emitted to `session_pid` during the loop:
    `{:event, {:text_delta, text}}` — streaming text chunk
    `{:event, {:tool_started, name}}` — tool dispatch starting
    `{:event, {:tool_completed, name, result}}` — tool result
    `{:finished, text}` — final answer
    `{:error, reason}` — unrecoverable provider error
  """

  require Logger

  alias Daemon.LLM.{Provider, Response, ToolCall}

  @spec run(term(), map() | nil, pid(), [map()]) :: :ok
  def run(initial_message, personality, session_pid, history \\ []) do
    plan = build_plan(personality)

    Logger.info(
      "llm_loop starting provider=#{plan.provider} model=#{plan.model} history=#{length(history)}"
    )

    messages = history ++ [%{"role" => "user", "content" => to_string(initial_message)}]
    agent_loop(plan, messages, session_pid)
  end

  # --- private ---

  defp agent_loop(plan, messages, session_pid) do
    on_chunk = fn text -> send(session_pid, {:event, {:text_delta, text}}) end

    case Provider.dispatch(plan, messages, on_chunk) do
      {:ok, %Response{finish_reason: :end_turn, content: text}} ->
        Logger.info("llm_loop end_turn content_length=#{byte_size(text)}")
        final = messages ++ [%{"role" => "assistant", "content" => text}]
        send(session_pid, {:messages, final})
        send(session_pid, {:finished, text})

      {:ok, %Response{finish_reason: :tool_calls, tool_calls: calls, content: text}} ->
        assistant_msg = %{"role" => "assistant", "content" => text, "tool_calls" => calls}
        tool_msgs = Enum.map(calls, &dispatch_tool(&1, session_pid))
        agent_loop(plan, messages ++ [assistant_msg | tool_msgs], session_pid)

      {:error, error} ->
        Logger.error("agent_loop provider error: #{inspect(error)}")
        send(session_pid, {:error, error})
    end
  end

  defp dispatch_tool(%ToolCall{id: id, name: name, args: args}, session_pid) do
    send(session_pid, {:event, {:tool_started, name}})

    result =
      case Daemon.Tool.execute(name, args) do
        {:ok, output} -> output
        {:error, reason} -> "error: #{inspect(reason)}"
      end

    send(session_pid, {:event, {:tool_completed, name, result}})
    %{"role" => "tool", "tool_call_id" => id, "content" => result}
  end

  defp build_plan(%Daemon.Personality{} = p) do
    %{
      provider: p.provider,
      model: p.model || default_model(p.provider),
      system: p.system,
      tools: p.tools
    }
  end

  defp build_plan(other), do: build_plan(Daemon.Personality.decode(other))

  defp default_model(:openai), do: "gpt-4o"
  defp default_model(_), do: "claude-opus-4-7"
end
