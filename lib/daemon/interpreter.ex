defmodule Daemon.Interpreter do
  @moduledoc """
  Takes and op and a context, then does what the op says, then returns a result.
  """
  require Logger

  alias Daemon.Interpreter.Context

  def run(manifest, session_pid, session_id) do
    ctx = %Context{
      session_id: session_id,
      session_pid: session_pid,
      manifest: manifest,
      personality: manifest.personality
    }

    case eval(manifest.entry, ctx) do
      {:ok, result, _ctx} -> send(session_pid, {:finished, result})
      {:error, reason, _ctx} -> send(session_pid, {:error, reason})
    end
  end

  # --- values & state ---

  def eval(%Op.Nop{}, ctx), do: {:ok, :unit, ctx}

  def eval(%Op.Constant{value: value}, ctx), do: {:ok, value, ctx}

  def eval(%Op.Literal{value: value}, ctx), do: {:ok, value, ctx}

  def eval(%Op.SlotGet{slot: slot}, ctx), do: {:ok, Map.get(ctx.slots, slot), ctx}

  def eval(%Op.SlotSet{slot: slot, value: value_op}, ctx) do
    with {:ok, value, ctx} <- eval(value_op, ctx) do
      {:ok, :unit, %{ctx | slots: Map.put(ctx.slots, slot, value)}}
    end
  end

  def eval(%Op.ParamGet{param: param}, ctx), do: {:ok, Map.get(ctx.params, param), ctx}

  # --- time & resilience ---

  def eval(%Op.Timeout{ms: ms, body: body}, ctx) do
    task = Task.async(fn -> eval(body, ctx) end)

    case Task.yield(task, ms) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :timeout, ctx}
    end
  end

  def eval(%Op.Delay{ms: ms}, ctx) do
    Process.sleep(ms)
    {:ok, :unit, ctx}
  end

  def eval(%Op.TryUndo{body: body, undo: undo}, ctx) do
    case eval(body, ctx) do
      {:ok, _, _} = ok -> ok
      {:error, _, ctx} -> eval(undo, ctx)
    end
  end

  # --- sequencing & shaping ---

  def eval(%Op.Then{first: first, second: second, keep: keep}, ctx) do
    with {:ok, first_val, ctx} <- eval(first, ctx),
         {:ok, second_val, ctx} <- eval(second, ctx) do
      case keep do
        :first -> {:ok, first_val, ctx}
        :second -> {:ok, second_val, ctx}
        :both -> {:ok, {first_val, second_val}, ctx}
      end
    end
  end

  def eval(%Op.Map{inner: inner}, ctx) do
    stub(:map, ctx)
    eval(inner, ctx)
  end

  def eval(%Op.Choice{branches: branches}, ctx) do
    Enum.reduce_while(branches, {:error, :all_branches_failed, ctx}, fn branch, _acc ->
      case eval(branch, ctx) do
        {:ok, _, _} = ok -> {:halt, ok}
        {:error, _, _} -> {:cont, {:error, :all_branches_failed, ctx}}
      end
    end)
  end

  def eval(%Op.Repeated{inner: inner, min: min, max: max}, ctx) do
    do_repeated(inner, ctx, min, max, 0, [])
  end

  def eval(%Op.Ignore{inner: inner}, ctx) do
    case eval(inner, ctx) do
      {:ok, _, ctx} -> {:ok, :unit, ctx}
      error -> error
    end
  end

  def eval(%Op.Label{body: body}, ctx), do: eval(body, ctx)

  def eval(%Op.Thought{text: text}, ctx) do
    send(ctx.session_pid, {:event, {:thought, text}})
    {:ok, :unit, ctx}
  end

  def eval(%Op.Checkpoint{name: name}, ctx) do
    send(ctx.session_pid, {:event, {:checkpoint, name}})
    {:ok, :unit, ctx}
  end

  # --- comparison & control ---

  def eval(%Op.Compare{kind: kind, lhs: lhs, rhs: rhs}, ctx) do
    with {:ok, lhs_val, ctx} <- eval(lhs, ctx),
         {:ok, rhs_val, ctx} <- eval(rhs, ctx) do
      result =
        case kind do
          :eq -> lhs_val == rhs_val
          :ne -> lhs_val != rhs_val
          :lt -> lhs_val < rhs_val
          :gt -> lhs_val > rhs_val
          :lte -> lhs_val <= rhs_val
          :gte -> lhs_val >= rhs_val
        end

      {:ok, result, ctx}
    end
  end

  def eval(%Op.When{condition: condition, body: body}, ctx) do
    with {:ok, bool, ctx} <- eval(condition, ctx) do
      if bool do
        case eval(body, ctx) do
          {:ok, val, ctx} -> {:ok, {:some, val}, ctx}
          error -> error
        end
      else
        {:ok, :none, ctx}
      end
    end
  end

  def eval(%Op.While{condition: condition, body: body}, ctx) do
    do_while(condition, body, ctx)
  end

  def eval(%Op.ForEach{over: over, param: param, body: body}, ctx) do
    with {:ok, list, ctx} <- eval(over, ctx) do
      Enum.reduce_while(list, {:ok, [], ctx}, fn element, {:ok, acc, ctx} ->
        scoped = %{ctx | params: Map.put(ctx.params, param, element)}

        case eval(body, scoped) do
          {:ok, val, new_ctx} ->
            {:cont, {:ok, [val | acc], %{new_ctx | params: ctx.params}}}

          {:error, _, _} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, results, ctx} -> {:ok, Enum.reverse(results), ctx}
        error -> error
      end
    end
  end

  # --- tools & context ---

  def eval(%Op.CallTool{name: name, args: arg_ops}, ctx) do
    send(ctx.session_pid, {:event, {:tool_started, name}})

    args =
      Enum.map(arg_ops, fn op ->
        case eval(op, ctx) do
          {:ok, val, _} -> val
          _ -> nil
        end
      end)

    case Daemon.Tool.execute(name, args) do
      {:ok, result} ->
        send(ctx.session_pid, {:event, {:tool_completed, name, result}})
        {:ok, result, ctx}

      {:error, reason} ->
        {:error, reason, ctx}
    end
  end

  def eval(%Op.LoadContext{}, ctx), do: stub(:load_context, ctx)
  def eval(%Op.CompactContext{}, ctx), do: stub(:compact_context, ctx)
  def eval(%Op.ForgetAfter{}, ctx), do: stub(:forget_after, ctx)
  def eval(%Op.Pin{}, ctx), do: stub(:pin, ctx)

  # --- interrupts ---

  def eval(%Op.Interrupt{id: id, prompt: prompt}, ctx) do
    send(ctx.session_pid, {:suspend, :interrupt, id, prompt})

    receive do
      {:resume, value} -> {:ok, value, ctx}
    end
  end

  # --- execution metadata ---

  def eval(%Op.Strategy{body: body}, ctx), do: eval(body, ctx)

  def eval(%Op.WithPersonality{personality: personality, body: body}, ctx) do
    case eval(body, %{ctx | personality: personality}) do
      {:ok, val, new_ctx} -> {:ok, val, %{new_ctx | personality: ctx.personality}}
      error -> error
    end
  end

  def eval(%Op.Budget{tokens: tokens, body: body}, ctx) do
    case eval(body, %{ctx | token_budget: tokens}) do
      {:ok, val, new_ctx} -> {:ok, val, %{new_ctx | token_budget: ctx.token_budget}}
      error -> error
    end
  end

  def eval(%Op.Sandbox{allowed_tools: tools, body: body}, ctx) do
    case eval(body, %{ctx | allowed_tools: tools}) do
      {:ok, val, new_ctx} -> {:ok, val, %{new_ctx | allowed_tools: ctx.allowed_tools}}
      error -> error
    end
  end

  # --- error recovery ---

  def eval(%Op.Retry{policy: policy, body: body}, ctx) do
    do_retry(body, ctx, policy)
  end

  def eval(%Op.Recover{body: body, fallback: fallback}, ctx) do
    case eval(body, ctx) do
      {:ok, _, _} = ok -> ok
      {:error, _, ctx} -> eval(fallback, ctx)
    end
  end

  def eval(%Op.Skip{body: body}, ctx) do
    case eval(body, ctx) do
      {:ok, val, ctx} -> {:ok, {:some, val}, ctx}
      {:error, _, ctx} -> {:ok, :none, ctx}
    end
  end

  # --- guards & steering ---

  def eval(%Op.Guard{}, ctx), do: stub(:guard, ctx)

  # --- concurrency ---

  def eval(%Op.Par{branches: branches}, ctx) do
    results =
      branches
      |> Task.async_stream(fn branch -> eval(branch, ctx) end, ordered: true)
      |> Enum.map(fn {:ok, result} -> result end)

    case Enum.find(results, &match?({:error, _, _}, &1)) do
      nil ->
        values = Enum.map(results, fn {:ok, val, _} -> val end)
        {:ok, List.to_tuple(values), ctx}

      error ->
        error
    end
  end

  def eval(%Op.Race{branches: branches}, ctx) do
    parent = self()
    ref = make_ref()
    count = length(branches)

    Enum.each(branches, fn branch ->
      Task.start(fn -> send(parent, {ref, eval(branch, ctx)}) end)
    end)

    collect_race(ref, count, {:error, :all_branches_failed, ctx})
  end

  def eval(%Op.FanOut{over: over, param: param, body: body}, ctx) do
    with {:ok, list, ctx} <- eval(over, ctx) do
      results =
        list
        |> Task.async_stream(
          fn element ->
            scoped = %{ctx | params: Map.put(ctx.params, param, element)}
            eval(body, scoped)
          end,
          ordered: true
        )
        |> Enum.map(fn {:ok, result} -> result end)

      case Enum.find(results, &match?({:error, _, _}, &1)) do
        nil ->
          values = Enum.map(results, fn {:ok, val, _} -> val end)
          {:ok, values, ctx}

        error ->
          error
      end
    end
  end

  # --- routines ---

  def eval(%Op.Invoke{routine: routine, args: arg_ops}, ctx) do
    case Map.get(ctx.manifest.routines || %{}, routine) do
      nil ->
        {:error, {:unknown_routine, routine}, ctx}

      op ->
        args =
          arg_ops
          |> Enum.with_index()
          |> Enum.reduce(%{}, fn {arg_op, i}, acc ->
            case eval(arg_op, ctx) do
              {:ok, val, _} -> Map.put(acc, "arg_#{i}", val)
              _ -> acc
            end
          end)

        eval(op, %{ctx | params: args})
    end
  end

  # --- signals ---

  def eval(%Op.Emit{topic: topic, payload: payload_op}, ctx) do
    with {:ok, payload, ctx} <- eval(payload_op, ctx) do
      Phoenix.PubSub.broadcast(Daemon.PubSub, topic, {:signal, topic, payload})
      {:ok, :unit, ctx}
    end
  end

  def eval(%Op.AwaitSignal{topic: topic}, ctx) do
    Phoenix.PubSub.subscribe(Daemon.PubSub, topic)

    receive do
      {:signal, ^topic, payload} -> {:ok, payload, ctx}
    end
  end

  def eval(%Op.OnSignal{}, ctx), do: stub(:on_signal, ctx)

  # --- advanced agentic ---

  def eval(%Op.Shadow{}, ctx), do: stub(:shadow, ctx)
  def eval(%Op.Ensemble{}, ctx), do: stub(:ensemble, ctx)
  def eval(%Op.Sample{}, ctx), do: stub(:sample, ctx)
  def eval(%Op.OnChunk{}, ctx), do: stub(:on_chunk, ctx)

  # --- agents ---

  def eval(%Op.SpawnAgent{personality: personality, body: body}, ctx) do
    child_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    child_manifest = %Daemon.Manifest{
      entry: body,
      routines: ctx.manifest.routines,
      personality: personality
    }

    {:ok, _pid} = Daemon.Session.Supervisor.start_session(child_id, ctx.session_id)
    Daemon.Session.run(child_id, child_manifest)
    {:ok, child_id, ctx}
  end

  # --- private helpers ---

  defp stub(op, ctx) do
    Logger.warning("interpreter: #{op} not implemented")
    {:ok, :unit, ctx}
  end

  defp do_while(condition, body, ctx) do
    case eval(condition, ctx) do
      {:ok, true, ctx} ->
        case eval(body, ctx) do
          {:ok, _, ctx} -> do_while(condition, body, ctx)
          error -> error
        end

      {:ok, false, ctx} ->
        {:ok, :unit, ctx}

      error ->
        error
    end
  end

  defp do_repeated(_inner, ctx, min, max, count, acc) when not is_nil(max) and count >= max do
    if count >= min,
      do: {:ok, Enum.reverse(acc), ctx},
      else: {:error, :min_not_met, ctx}
  end

  defp do_repeated(inner, ctx, min, max, count, acc) do
    case eval(inner, ctx) do
      {:ok, val, ctx} ->
        do_repeated(inner, ctx, min, max, count + 1, [val | acc])

      {:error, _, _} = error ->
        if count >= min, do: {:ok, Enum.reverse(acc), ctx}, else: error
    end
  end

  defp do_retry(_body, ctx, _policy, 0), do: {:error, :max_retries_exceeded, ctx}

  defp do_retry(body, ctx, policy, attempts) do
    case eval(body, ctx) do
      {:ok, _, _} = ok -> ok
      {:error, _, ctx} -> do_retry(body, ctx, policy, attempts - 1)
    end
  end

  defp do_retry(body, ctx, policy) do
    max = if is_map(policy), do: Map.get(policy, :max_attempts, 3), else: 3
    do_retry(body, ctx, policy, max)
  end

  defp collect_race(_ref, 0, last), do: last

  defp collect_race(ref, remaining, _last) do
    receive do
      {^ref, {:ok, _, _} = ok} -> ok
      {^ref, {:error, _, _} = err} -> collect_race(ref, remaining - 1, err)
    end
  end
end
