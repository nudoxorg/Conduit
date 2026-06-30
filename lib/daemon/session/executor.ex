defmodule Daemon.Session.Executor do
  alias Daemon.Op, as: Op
  require Logger

  # state = %{
  #   session_id: "...",
  #   slots: %{},
  #   context_messages: [],
  #   params: %{},
  #   checkpoints: %{},
  #   routines: %{},
  #   personality: nil,      # WithPersonality override
  #   allowed_tools: nil,    # Sandbox restriction (nil = all allowed)
  #   strategy: nil          # Strategy override
  # }

  @max_while_iterations 1000
  @task_timeout :timer.minutes(5)

  # ── values & state ────────────────────────────────────────────────

  def exec(%Op.Literal{value: value}, state) do
    {value, state}
  end

  def exec(%Op.Nop{}, state) do
    {nil, state}
  end

  def exec(%Op.SlotGet{slot: slot}, state) do
    {state.slots[slot], state}
  end

  def exec(%Op.SlotSet{slot: slot, value: value_op}, state) do
    {value, state} = exec(value_op, state)
    state = %{state | slots: Map.put(state.slots, slot, value)}
    {value, state}
  end

  def exec(%Op.ParamGet{param: param}, state) do
    {Map.get(state.params, param), state}
  end

  # ── time & resilience ─────────────────────────────────────────────

  def exec(%Op.Timeout{ms: ms, body: body}, state) do
    task = Task.async(fn -> exec(body, state) end)

    case Task.yield(task, ms) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        raise "Timeout body failed: #{inspect(reason)}"

      nil ->
        Task.shutdown(task, :brutal_kill)
        raise "Timeout: body exceeded #{ms}ms"
    end
  end

  def exec(%Op.Delay{ms: ms}, state) do
    :timer.sleep(ms)
    {nil, state}
  end

  def exec(%Op.TryUndo{body: body, undo: undo}, state) do
    try do
      exec(body, state)
    rescue
      e ->
        exec(undo, state)
        reraise e, __STACKTRACE__
    end
  end

  # ── sequencing & shaping ──────────────────────────────────────────

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

  def exec(%Op.MapOp{inner: inner, transform: transform}, state) do
    {value, state} = exec(inner, state)
    {apply_transform(value, transform), state}
  end

  def exec(%Op.Choice{branches: branches}, state) do
    exec_choice(branches, state)
  end

  def exec(%Op.Repeated{inner: inner, min: min, max: max}, state) do
    count = max || min

    {results, state} =
      Enum.reduce(1..count, {[], state}, fn _, {acc, st} ->
        {value, st} = exec(inner, st)
        {acc ++ [value], st}
      end)

    {results, state}
  end

  def exec(%Op.Ignore{inner: inner}, state) do
    {_result, state} = exec(inner, state)
    {nil, state}
  end

  def exec(%Op.Thought{text: text}, state) do
    Logger.info("session=#{state.session_id} thought: #{text}")
    broadcast(state.session_id, %{type: :thought, text: text})
    {nil, state}
  end

  def exec(%Op.Checkpoint{name: name}, state) do
    state = %{
      state
      | checkpoints: Map.put(state.checkpoints, name, length(state.context_messages))
    }

    {nil, state}
  end

  # ── comparison & control ──────────────────────────────────────────

  def exec(%Op.Compare{kind: kind, lhs: lhs, rhs: rhs}, state) do
    {lv, state} = exec(lhs, state)
    {rv, state} = exec(rhs, state)

    result =
      case kind do
        "eq" -> lv == rv
        "lt" -> lv < rv
        "gt" -> lv > rv
        "lte" -> lv <= rv
        "gte" -> lv >= rv
        "ne" -> lv != rv
        _ -> lv == rv
      end

    {result, state}
  end

  # backwards compat aliases
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

  def exec(%Op.ForEach{over: over_op, param: param, body: body}, state) do
    {list, state} = exec(over_op, state)
    items = if is_list(list), do: list, else: [list]

    {results, state} =
      Enum.reduce(items, {[], state}, fn item, {acc, st} ->
        st = %{st | params: Map.put(st.params, param, item)}
        {value, st} = exec(body, st)
        {acc ++ [value], st}
      end)

    {results, state}
  end

  # ── tools & context ───────────────────────────────────────────────

  def exec(%Op.CallTool{name: name, args: arg_ops}, state) do
    if state.allowed_tools && name not in state.allowed_tools do
      raise "Tool #{name} not allowed in sandbox (allowed: #{inspect(state.allowed_tools)})"
    end

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

  def exec(%Op.LoadContext{source: source}, state) do
    content =
      cond do
        String.starts_with?(source, "http://") or String.starts_with?(source, "https://") ->
          case Req.get(source, finch: Daemon.Finch, receive_timeout: 30_000) do
            {:ok, %{status: 200, body: body}} ->
              if is_binary(body), do: body, else: Jason.encode!(body)

            _ ->
              "Failed to load: #{source}"
          end

        true ->
          case File.read(source) do
            {:ok, content} -> content
            {:error, _} -> "Failed to read: #{source}"
          end
      end

    {nil, %{state | context_messages: state.context_messages ++ [content]}}
  end

  def exec(%Op.CompactContext{}, state) do
    Logger.info("session=#{state.session_id} compact_context (stub — requires LLM summarization)")
    {nil, state}
  end

  def exec(%Op.ForgetAfter{mark: mark}, state) do
    idx = Map.get(state.checkpoints, mark, 0)
    {nil, %{state | context_messages: Enum.take(state.context_messages, idx)}}
  end

  def exec(%Op.Pin{fact: fact}, state) do
    {nil, %{state | context_messages: state.context_messages ++ [fact]}}
  end

  # ── interrupts ────────────────────────────────────────────────────

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

  # ── execution metadata ────────────────────────────────────────────

  def exec(%Op.Strategy{strategy: strategy, body: body}, state) do
    old = state.strategy
    {result, state} = exec(body, %{state | strategy: strategy})
    {result, %{state | strategy: old}}
  end

  def exec(%Op.WithPersonality{personality: personality, body: body}, state) do
    old = state.personality
    {result, state} = exec(body, %{state | personality: personality})
    {result, %{state | personality: old}}
  end

  def exec(%Op.Budget{body: body}, state) do
    Logger.info("session=#{state.session_id} budget (token limit not enforced without streaming)")
    exec(body, state)
  end

  def exec(%Op.Sandbox{allowed_tools: tools, body: body}, state) do
    old = state.allowed_tools
    {result, state} = exec(body, %{state | allowed_tools: tools})
    {result, %{state | allowed_tools: old}}
  end

  # ── error recovery ────────────────────────────────────────────────

  def exec(%Op.Retry{policy: policy, body: body}, state) do
    max = Map.get(policy, "max_attempts", 3)
    delay_ms = Map.get(policy, "delay_ms", 0)
    exec_retry(body, state, max, delay_ms)
  end

  def exec(%Op.Recover{body: body, fallback: fallback}, state) do
    try do
      exec(body, state)
    rescue
      _ -> exec(fallback, state)
    end
  end

  def exec(%Op.Skip{body: body}, state) do
    try do
      exec(body, state)
    rescue
      _ -> {nil, state}
    end
  end

  # ── guards & steering ─────────────────────────────────────────────

  def exec(
        %Op.Guard{
          phase: phase,
          check: check,
          feedback: feedback,
          max_attempts: max_attempts,
          on_exhausted: on_exhausted,
          body: body
        },
        state
      ) do
    exec_guard(phase, check, feedback, max_attempts, on_exhausted, body, state, 0)
  end

  # ── concurrency ───────────────────────────────────────────────────

  def exec(%Op.Par{branches: branches}, state) do
    results =
      branches
      |> Task.async_stream(fn branch -> exec(branch, state) end,
        ordered: true,
        timeout: @task_timeout
      )
      |> Enum.map(fn {:ok, {value, _st}} -> value end)

    {results, state}
  end

  def exec(%Op.Race{branches: branches}, state) do
    me = self()
    ref = make_ref()

    pids =
      Enum.map(branches, fn branch ->
        spawn(fn ->
          try do
            {value, _} = exec(branch, state)
            send(me, {ref, {:ok, value}})
          rescue
            e -> send(me, {ref, {:error, e}})
          end
        end)
      end)

    result =
      receive do
        {^ref, {:ok, value}} -> value
        {^ref, {:error, e}} -> raise e
      after
        @task_timeout -> raise "Race: all branches timed out"
      end

    Enum.each(pids, &Process.exit(&1, :kill))
    {result, state}
  end

  def exec(%Op.FanOut{over: over_op, param: param, body: body}, state) do
    {list, state} = exec(over_op, state)
    items = if is_list(list), do: list, else: [list]

    results =
      items
      |> Task.async_stream(
        fn item ->
          item_state = %{state | params: Map.put(state.params, param, item)}
          {value, _} = exec(body, item_state)
          value
        end,
        ordered: true,
        timeout: @task_timeout
      )
      |> Enum.map(fn {:ok, value} -> value end)

    {results, state}
  end

  # ── routines ──────────────────────────────────────────────────────

  def exec(%Op.Invoke{routine: name, args: arg_ops}, state) do
    {args, state} =
      Enum.reduce(arg_ops, {[], state}, fn op, {acc, st} ->
        {val, st} = exec(op, st)
        {acc ++ [val], st}
      end)

    case Map.get(state.routines, name) do
      nil ->
        raise "Invoke: routine #{inspect(name)} not found in manifest"

      routine_op ->
        arg_params =
          args
          |> Enum.with_index()
          |> Enum.map(fn {v, i} -> {"arg_#{i}", v} end)
          |> Map.new()

        exec(routine_op, %{state | params: Map.merge(state.params, arg_params)})
    end
  end

  # ── signals ───────────────────────────────────────────────────────

  def exec(%Op.Emit{topic: topic, payload: payload_op}, state) do
    {payload, state} = exec(payload_op, state)

    Phoenix.PubSub.broadcast(Daemon.PubSub, "signal:#{topic}", %{
      type: :signal,
      topic: topic,
      payload: payload
    })

    {nil, state}
  end

  def exec(%Op.AwaitSignal{topic: topic}, state) do
    Phoenix.PubSub.subscribe(Daemon.PubSub, "signal:#{topic}")

    payload =
      receive do
        %{type: :signal, topic: ^topic, payload: payload} -> payload
      after
        :timer.minutes(30) -> raise "AwaitSignal: timeout waiting for topic #{inspect(topic)}"
      end

    {payload, state}
  end

  def exec(%Op.OnSignal{topic: topic, param: param, body: body}, state) do
    Phoenix.PubSub.subscribe(Daemon.PubSub, "signal:#{topic}")

    payload =
      receive do
        %{type: :signal, topic: ^topic, payload: payload} -> payload
      after
        :timer.minutes(30) -> raise "OnSignal: timeout waiting for topic #{inspect(topic)}"
      end

    state = %{state | params: Map.put(state.params, param, payload)}
    {_result, state} = exec(body, state)
    {nil, state}
  end

  # ── advanced agentic ──────────────────────────────────────────────

  def exec(%Op.Shadow{threshold: threshold, body: body}, state) do
    {result, state} = exec(body, state)
    broadcast(state.session_id, %{type: :shadow_check, threshold: threshold, result: result})
    {result, state}
  end

  def exec(%Op.Ensemble{count: count, body: body, voter: voter}, state) do
    {results, state} =
      Enum.reduce(1..count, {[], state}, fn _, {acc, st} ->
        {value, st} = exec(body, st)
        {acc ++ [value], st}
      end)

    voter_state = %{state | params: Map.put(state.params, "ensemble_results", results)}
    exec(voter, voter_state)
  end

  def exec(%Op.Sample{choices: choices}, state) do
    # total = Enum.sum(Enum.map(choices, fn {w, _} -> w end))

    total =
      choices
      |> Enum.map(fn {w, _} -> w end)
      |> Enum.sum()

    r = :rand.uniform() * total

    {_, chosen} =
      Enum.reduce_while(choices, {0.0, nil}, fn {w, op}, {acc, _} ->
        new_acc = acc + w
        if new_acc >= r, do: {:halt, {new_acc, op}}, else: {:cont, {new_acc, nil}}
      end)

    exec(chosen || elem(List.last(choices), 1), state)
  end

  def exec(%Op.OnChunk{body: body}, state) do
    Logger.info("session=#{state.session_id} on_chunk (stub — requires streaming LLM support)")
    exec(body, state)
  end

  # ── agents ────────────────────────────────────────────────────────

  def exec(
        %Op.SpawnAgent{id: id, personality: personality, input: input_op, body: body_op},
        state
      ) do
    {input, state} = if input_op, do: exec(input_op, state), else: {nil, state}

    child_id =
      if id,
        do: "#{state.session_id}/#{id}",
        else: "#{state.session_id}/#{System.unique_integer([:positive])}"

    Logger.info("session=#{state.session_id} spawning agent child_id=#{child_id}")

    child_body = body_op || %Op.Literal{value: to_string(input)}

    child_program = %Op.Program{
      acd: 2,
      manifest: %Op.Manifest{personality: personality, slots: []},
      body: child_body
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

  # ── private ───────────────────────────────────────────────────────

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

  defp exec_choice([], _state), do: raise("Choice: all branches failed")

  defp exec_choice([branch | rest], state) do
    try do
      exec(branch, state)
    rescue
      _ -> exec_choice(rest, state)
    end
  end

  defp exec_retry(_body, _state, 0, _delay_ms) do
    raise "Retry: exhausted all attempts"
  end

  defp exec_retry(body, state, attempts_left, delay_ms) do
    try do
      exec(body, state)
    rescue
      _ ->
        if delay_ms > 0, do: :timer.sleep(delay_ms)
        exec_retry(body, state, attempts_left - 1, delay_ms)
    end
  end

  defp exec_guard(_phase, _check, _feedback, max_attempts, on_exhausted, body, state, attempts)
       when attempts >= max_attempts do
    case on_exhausted do
      "skip" -> {nil, state}
      "proceed" -> exec(body, state)
      _ -> raise "Guard: exhausted #{max_attempts} attempts"
    end
  end

  defp exec_guard("pre", check, feedback, max_attempts, on_exhausted, body, state, attempts) do
    {pass, state} = exec(check, state)

    if pass do
      exec(body, state)
    else
      if feedback,
        do: Logger.info("session=#{state.session_id} guard pre-check failed: #{feedback}")

      exec_guard("pre", check, feedback, max_attempts, on_exhausted, body, state, attempts + 1)
    end
  end

  defp exec_guard("post", check, feedback, max_attempts, on_exhausted, body, state, attempts) do
    {result, state} = exec(body, state)
    {pass, state} = exec(check, state)

    if pass do
      {result, state}
    else
      if feedback,
        do: Logger.info("session=#{state.session_id} guard post-check failed: #{feedback}")

      exec_guard("post", check, feedback, max_attempts, on_exhausted, body, state, attempts + 1)
    end
  end

  defp exec_guard(_, _check, _feedback, _max, _on_exhausted, body, state, _attempts) do
    exec(body, state)
  end

  defp apply_transform(value, "to_string"), do: to_string(value)
  defp apply_transform(value, "upcase") when is_binary(value), do: String.upcase(value)
  defp apply_transform(value, "downcase") when is_binary(value), do: String.downcase(value)
  defp apply_transform(value, "trim") when is_binary(value), do: String.trim(value)
  defp apply_transform(value, "lines") when is_binary(value), do: String.split(value, "\n")
  defp apply_transform(value, "json_decode") when is_binary(value), do: Jason.decode!(value)
  defp apply_transform(value, "json_encode"), do: Jason.encode!(value)
  defp apply_transform(value, _), do: value

  defp broadcast(session_id, event) do
    Phoenix.PubSub.broadcast(Daemon.PubSub, "session:#{session_id}", event)
  end
end
