defmodule Daemon.Session.Loop do
  alias Daemon.Session.Executor, as: Executor
  require Logger

  def run(session_id, program, history, _user_message) do
    plan = Daemon.Op.Interpreter.build(program)
    personality = program.manifest.personality

    state = %{session_id: session_id, slots: plan.slots}

    Logger.info("session=#{session_id} executing op tree")
    {result, _final_state} = Executor.exec(program.body, state)
    Logger.info("session=#{session_id} op tree complete result=#{inspect(result)}")

    if personality.use_llm do
      llm_plan = %{
        provider: :anthropic,
        model: "claude-sonnet-4-6",
        system: personality.starter_prompt,
        tools: plan.tools
      }

      messages = history ++ [%{role: :user, content: to_string(result)}]
      agent_loop(session_id, llm_plan, messages, 0)
    else
      broadcast(session_id, %{type: :finished, content: to_string(result)})
      {:ok, history}
    end
  end

  @max_iterations 20

  defp agent_loop(session_id, _plan, _messages, iterations) when iterations >= @max_iterations do
    Logger.error(
      "session=#{session_id} agent loop hit max iterations (#{@max_iterations}), forcing stop"
    )

    broadcast(session_id, %{
      type: :finished,
      content: "Agent stopped: exceeded #{@max_iterations} iterations"
    })

    {:error, :max_iterations}
  end

  defp agent_loop(session_id, plan, messages, iterations) do
    Logger.info(
      "session=#{session_id} calling LLM provider=#{plan.provider} model=#{plan.model} messages=#{length(messages)} iteration=#{iterations + 1}/#{@max_iterations}"
    )

    case Daemon.LLM.Client.complete(plan, messages) do
      {:ok, %{finish_reason: :end_turn, content: content}} ->
        Logger.info("session=#{session_id} LLM end_turn content_length=#{String.length(content)}")
        broadcast(session_id, %{type: :finished, content: content})
        {:ok, messages ++ [%{role: :assistant, content: content}]}

      {:ok, %{finish_reason: :tool_calls, content: content, tool_calls: tool_calls}} ->
        Logger.info(
          "session=#{session_id} LLM tool_calls count=#{length(tool_calls)} tools=#{Enum.map_join(tool_calls, ", ", & &1.name)}"
        )

        tool_results =
          Enum.map(tool_calls, fn call ->
            broadcast(session_id, %{type: :tool_started, name: call.name})

            output =
              case Daemon.Tool.execute(call.name, call.args) do
                {:ok, str} -> str
                {:error, reason} -> "Error: #{inspect(reason)}"
              end

            broadcast(session_id, %{type: :tool_completed, name: call.name, result: output})
            %{role: :tool, tool_use_id: call.id, name: call.name, content: output}
          end)

        updated =
          messages ++
            [%{role: :assistant, content: content, tool_calls: tool_calls}] ++
            tool_results

        agent_loop(session_id, plan, updated, iterations + 1)

      {:error, reason} ->
        Logger.error("session=#{session_id} LLM error reason=#{inspect(reason)}")
        broadcast(session_id, %{type: :finished, content: "Error: #{inspect(reason)}"})
        {:error, reason}
    end
  end

  defp broadcast(session_id, event) do
    Phoenix.PubSub.broadcast(Daemon.PubSub, "session:#{session_id}", event)
  end
end
