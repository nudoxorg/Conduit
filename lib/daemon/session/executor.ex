defmodule Daemon.Session.Executor do
  alias Daemon.Op, as: Op
  require Logger

  # state = %{session_id: "...", slots: %{}}

  @max_while_iterations 1000

  # --- chain ops ---

  def exec(%Op.Label{body: body}, state) do
    exec(body, state)
  end

  def exec(%Op.Then{first: first, second: second, keep: keep}, state) do
    {first_result, state} = exec(first, state)
    {second_result, state} = exec(second, state)

    result =
      case keep do
        "first" -> first_result
        "second" -> second_result
        _ -> second_result
      end

    {result, state}
  end

  def exec(%Op.When{condition: condition, body: body}, state) do
    {cond_result, state} = exec(condition, state)

    if cond_result do
      exec(body, state)
    else
      {nil, state}
    end
  end

  def exec(%Op.While{condition: condition, body: body}, state) do
    exec_while(condition, body, state, 0)
  end

  defp exec_while(_condition, _body, state, @max_while_iterations) do
    Logger.error(
      "session=#{state.session_id} while loop exceeded #{@max_while_iterations} iterations"
    )

    raise "While loop exceeded maximum iterations (#{@max_while_iterations})"
  end

  defp exec_while(condition, body, state, count) do
    {cond_result, state} = exec(condition, state)

    if cond_result do
      {_result, state} = exec(body, state)
      exec_while(condition, body, state, count + 1)
    else
      {nil, state}
    end
  end

  # --- comparison ops ---

  def exec(%Op.Eq{left: l, right: r}, state) do
    {lv, state} = exec(l, state)
    {rv, state} = exec(r, state)
    {lv == rv, state}
  end

  def exec(%Op.Lt{left: l, right: r}, state) do
    {lv, state} = exec(l, state)
    {rv, state} = exec(r, state)
    {lv < rv, state}
  end

  def exec(%Op.Gt{left: l, right: r}, state) do
    {lv, state} = exec(l, state)
    {rv, state} = exec(r, state)
    {lv > rv, state}
  end

  # --- slot ops ---

  def exec(%Op.SlotSet{slot: slot, value: value_op}, state) do
    {value, state} = exec(value_op, state)
    state = put_in(state.slots[slot], value)
    {value, state}
  end

  def exec(%Op.SlotGet{slot: slot}, state) do
    {state.slots[slot], state}
  end

  # --- tool ops ---

  def exec(%Op.CallTool{name: name, args: arg_ops}, state) do
    {args, state} =
      Enum.reduce(arg_ops, {[], state}, fn op, {acc, st} ->
        {val, st} = exec(op, st)
        {acc ++ [val], st}
      end)

    broadcast(state.session_id, %{type: :tool_started, name: name})

    output =
      case Daemon.Tool.execute(name, args) do
        {:ok, str} ->
          str

        {:error, reason} ->
          Logger.error("session=#{state.session_id} tool=#{name} error=#{inspect(reason)}")
          "Error: #{inspect(reason)}"
      end

    broadcast(state.session_id, %{type: :tool_completed, name: name, result: output})

    {output, state}
  end

  def exec(%Op.LoadContext{value: value_op}, state) do
    # Evaluates the op and makes the result available as context.
    # Full implementation will inject this into the LLM context window directly.
    exec(value_op, state)
  end

  # --- intervention ops ---

  def exec(%Op.Interrupt{kind: "ask_human", prompt: prompt, id: id}, state) do
    Logger.info("session=#{state.session_id} interrupt id=#{id} waiting for human")
    broadcast(state.session_id, %{type: :intervention_required, id: id, prompt: prompt})

    reply =
      receive do
        {:intervention_reply, ^id, reply} -> reply
      after
        :timer.minutes(30) ->
          Logger.error("session=#{state.session_id} interrupt id=#{id} timed out")
          raise "Intervention #{id} timed out"
      end

    Logger.info("session=#{state.session_id} interrupt id=#{id} received reply")
    {reply, state}
  end

  def exec(%Op.SpawnAgent{id: id, personality: personality, input: input_op}, state) do
    {input, state} = exec(input_op, state)

    child_id = "#{state.session_id}/#{id}"

    Logger.info("session=#{state.session_id} spawning agent child_id=#{child_id}")

    child_program = %Op.Program{
      acd: 2,
      manifest: %Op.Manifest{personality: personality, slots: []},
      body: %Op.Literal{value: to_string(input)}
    }

    Phoenix.PubSub.subscribe(Daemon.PubSub, "session:#{child_id}")

    DynamicSupervisor.start_child(
      Daemon.SessionSupervisor,
      {Daemon.Session, %{id: child_id, parent_id: state.session_id}}
    )

    broadcast(state.session_id, %{type: :agent_spawned, agent_id: child_id})

    Daemon.Session.run(child_id, child_program, "")

    result =
      receive do
        %{type: :finished, content: content} ->
          Logger.info("session=#{state.session_id} agent child_id=#{child_id} finished")
          content
      after
        :timer.minutes(30) ->
          Logger.error("session=#{state.session_id} agent child_id=#{child_id} timed out")
          raise "Agent #{child_id} timed out"
      end

    broadcast(state.session_id, %{type: :agent_finished, agent_id: child_id, result: result})

    {result, state}
  end

  # --- utility ops ---

  def exec(%Op.Literal{value: value}, state) do
    {value, state}
  end

  defp broadcast(session_id, event) do
    Phoenix.PubSub.broadcast(Daemon.PubSub, "session:#{session_id}", event)
  end
end
