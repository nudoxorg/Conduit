defmodule Daemon.Op.Decoder do
  @moduledoc """
  Decodes a parsed JSON map into an `Op.t()` struct tree.

  The expected wire format uses an `"op"` key as the discriminator and
  snake_case field names matching the struct fields. Child ops are decoded
  recursively, so the entire tree is validated in one pass.

  Entry point for a full program is `Daemon.Manifest.decode/1`, which wraps
  this module and handles the outer `program > manifest/body` envelope.
  """

  # --- public ---

  @spec decode(map()) :: {:ok, Daemon.Op.t()} | {:error, term()}

  # values & state

  def decode(%{"op" => "nop"}), do: {:ok, %Op.Nop{}}

  def decode(%{"op" => "constant"} = m) do
    {:ok, %Op.Constant{ty: m["ty"], value: m["value"]}}
  end

  def decode(%{"op" => "literal"} = m) do
    {:ok, %Op.Literal{value: m["value"]}}
  end

  def decode(%{"op" => "slot_get"} = m) do
    {:ok, %Op.SlotGet{slot: m["slot"]}}
  end

  def decode(%{"op" => "slot_set"} = m) do
    with {:ok, value} <- decode(m["value"]) do
      {:ok, %Op.SlotSet{slot: m["slot"], value: value}}
    end
  end

  def decode(%{"op" => "param_get"} = m) do
    {:ok, %Op.ParamGet{param: m["param"]}}
  end

  # time & resilience

  def decode(%{"op" => "timeout"} = m) do
    with {:ok, body} <- decode(m["body"]) do
      {:ok, %Op.Timeout{ms: m["ms"], body: body}}
    end
  end

  def decode(%{"op" => "delay"} = m) do
    {:ok, %Op.Delay{ms: m["ms"]}}
  end

  def decode(%{"op" => "try_undo"} = m) do
    with {:ok, body} <- decode(m["body"]),
         {:ok, undo} <- decode(m["undo"]) do
      {:ok, %Op.TryUndo{body: body, undo: undo}}
    end
  end

  # sequencing & shaping

  def decode(%{"op" => "then"} = m) do
    with {:ok, first} <- decode(m["first"]),
         {:ok, second} <- decode(m["second"]) do
      {:ok, %Op.Then{first: first, second: second, keep: decode_keep(m["keep"])}}
    end
  end

  def decode(%{"op" => "map"} = m) do
    with {:ok, inner} <- decode(m["inner"]) do
      {:ok, %Op.Map{inner: inner, transform: m["transform"]}}
    end
  end

  def decode(%{"op" => "choice"} = m) do
    with {:ok, branches} <- decode_op_list(m["branches"]) do
      {:ok, %Op.Choice{branches: branches}}
    end
  end

  def decode(%{"op" => "repeated"} = m) do
    with {:ok, inner} <- decode(m["inner"]) do
      {:ok, %Op.Repeated{inner: inner, min: m["min"] || 0, max: m["max"]}}
    end
  end

  def decode(%{"op" => "ignore"} = m) do
    with {:ok, inner} <- decode(m["inner"]) do
      {:ok, %Op.Ignore{inner: inner}}
    end
  end

  def decode(%{"op" => "label"} = m) do
    with {:ok, body} <- decode(m["body"]) do
      {:ok, %Op.Label{label: m["label"], body: body}}
    end
  end

  def decode(%{"op" => "thought"} = m) do
    {:ok, %Op.Thought{text: m["text"]}}
  end

  def decode(%{"op" => "checkpoint"} = m) do
    {:ok, %Op.Checkpoint{name: m["name"]}}
  end

  # comparison & control

  def decode(%{"op" => "compare"} = m) do
    with {:ok, lhs} <- decode(m["lhs"]),
         {:ok, rhs} <- decode(m["rhs"]) do
      {:ok, %Op.Compare{kind: decode_compare_kind(m["kind"]), lhs: lhs, rhs: rhs}}
    end
  end

  def decode(%{"op" => "when"} = m) do
    with {:ok, condition} <- decode(m["condition"]),
         {:ok, body} <- decode(m["body"]) do
      {:ok, %Op.When{condition: condition, body: body}}
    end
  end

  def decode(%{"op" => "while"} = m) do
    with {:ok, condition} <- decode(m["condition"]),
         {:ok, body} <- decode(m["body"]) do
      {:ok, %Op.While{condition: condition, body: body}}
    end
  end

  def decode(%{"op" => "for_each"} = m) do
    with {:ok, over} <- decode(m["over"]),
         {:ok, body} <- decode(m["body"]) do
      {:ok, %Op.ForEach{over: over, param: m["param"], body: body}}
    end
  end

  # tools & context

  def decode(%{"op" => "call_tool"} = m) do
    with {:ok, args} <- decode_op_list(m["args"] || []) do
      {:ok, %Op.CallTool{name: m["name"], args: args, output: m["output"]}}
    end
  end

  def decode(%{"op" => "load_context"} = m) do
    {:ok, %Op.LoadContext{source: m["source"]}}
  end

  def decode(%{"op" => "compact_context"}) do
    {:ok, %Op.CompactContext{}}
  end

  def decode(%{"op" => "forget_after"} = m) do
    {:ok, %Op.ForgetAfter{mark: m["mark"]}}
  end

  def decode(%{"op" => "pin"} = m) do
    {:ok, %Op.Pin{fact: m["fact"]}}
  end

  # interrupts

  def decode(%{"op" => "interrupt"} = m) do
    {:ok,
     %Op.Interrupt{
       id: m["id"],
       kind: m["kind"],
       prompt: m["prompt"],
       response: m["response"]
     }}
  end

  # execution metadata

  def decode(%{"op" => "strategy"} = m) do
    with {:ok, body} <- decode(m["body"]) do
      {:ok, %Op.Strategy{strategy: m["strategy"], body: body}}
    end
  end

  def decode(%{"op" => "with_personality"} = m) do
    with {:ok, body} <- decode(m["body"]) do
      {:ok, %Op.WithPersonality{personality: Daemon.Personality.decode(m["personality"]), body: body}}
    end
  end

  def decode(%{"op" => "budget"} = m) do
    with {:ok, body} <- decode(m["body"]) do
      {:ok, %Op.Budget{tokens: m["tokens"], body: body}}
    end
  end

  def decode(%{"op" => "sandbox"} = m) do
    with {:ok, body} <- decode(m["body"]) do
      {:ok, %Op.Sandbox{allowed_tools: m["allowed_tools"] || [], body: body}}
    end
  end

  # error recovery

  def decode(%{"op" => "retry"} = m) do
    with {:ok, body} <- decode(m["body"]) do
      {:ok, %Op.Retry{policy: m["policy"], body: body}}
    end
  end

  def decode(%{"op" => "recover"} = m) do
    with {:ok, body} <- decode(m["body"]),
         {:ok, fallback} <- decode(m["fallback"]) do
      {:ok, %Op.Recover{body: body, fallback: fallback}}
    end
  end

  def decode(%{"op" => "skip"} = m) do
    with {:ok, body} <- decode(m["body"]) do
      {:ok, %Op.Skip{body: body}}
    end
  end

  # guards & steering

  def decode(%{"op" => "guard"} = m) do
    with {:ok, check} <- decode(m["check"]),
         {:ok, body} <- decode(m["body"]) do
      {:ok,
       %Op.Guard{
         phase: m["phase"],
         check: check,
         feedback: m["feedback"],
         max_attempts: m["max_attempts"] || 1,
         on_exhausted: m["on_exhausted"],
         body: body
       }}
    end
  end

  # concurrency

  def decode(%{"op" => "par"} = m) do
    with {:ok, branches} <- decode_op_list(m["branches"]) do
      {:ok, %Op.Par{branches: branches}}
    end
  end

  def decode(%{"op" => "race"} = m) do
    with {:ok, branches} <- decode_op_list(m["branches"]) do
      {:ok, %Op.Race{branches: branches}}
    end
  end

  def decode(%{"op" => "fan_out"} = m) do
    with {:ok, over} <- decode(m["over"]),
         {:ok, body} <- decode(m["body"]) do
      {:ok, %Op.FanOut{over: over, param: m["param"], body: body, join: m["join"]}}
    end
  end

  # routines

  def decode(%{"op" => "invoke"} = m) do
    with {:ok, args} <- decode_op_list(m["args"] || []) do
      {:ok, %Op.Invoke{routine: m["routine"], args: args}}
    end
  end

  # signals

  def decode(%{"op" => "emit"} = m) do
    with {:ok, payload} <- decode(m["payload"]) do
      {:ok, %Op.Emit{topic: m["topic"], payload: payload}}
    end
  end

  def decode(%{"op" => "await_signal"} = m) do
    {:ok, %Op.AwaitSignal{topic: m["topic"]}}
  end

  def decode(%{"op" => "on_signal"} = m) do
    with {:ok, body} <- decode(m["body"]) do
      {:ok, %Op.OnSignal{topic: m["topic"], param: m["param"], body: body}}
    end
  end

  # advanced agentic patterns

  def decode(%{"op" => "shadow"} = m) do
    with {:ok, body} <- decode(m["body"]) do
      {:ok, %Op.Shadow{threshold: m["threshold"], body: body}}
    end
  end

  def decode(%{"op" => "ensemble"} = m) do
    with {:ok, body} <- decode(m["body"]),
         {:ok, voter} <- decode(m["voter"]) do
      {:ok, %Op.Ensemble{count: m["count"], body: body, voter: voter}}
    end
  end

  def decode(%{"op" => "sample"} = m) do
    choices =
      Enum.map(m["choices"] || [], fn [weight, op_map] ->
        case decode(op_map) do
          {:ok, op} -> {weight, op}
          _ -> nil
        end
      end)

    if Enum.any?(choices, &is_nil/1) do
      {:error, {:invalid_sample_choices, m["choices"]}}
    else
      {:ok, %Op.Sample{choices: choices}}
    end
  end

  def decode(%{"op" => "on_chunk"} = m) do
    with {:ok, body} <- decode(m["body"]) do
      {:ok, %Op.OnChunk{body: body}}
    end
  end

  # agents

  def decode(%{"op" => "spawn_agent"} = m) do
    with {:ok, body} <- decode(m["body"]) do
      {:ok, %Op.SpawnAgent{personality: m["personality"], body: body}}
    end
  end

  # fallback

  def decode(%{"op" => name}) do
    {:error, {:unknown_op, name}}
  end

  def decode(other) do
    {:error, {:not_an_op, other}}
  end

  # --- private ---

  defp decode_op_list(list) when is_list(list) do
    result =
      Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
        case decode(item) do
          {:ok, op} -> {:cont, {:ok, [op | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, ops} -> {:ok, Enum.reverse(ops)}
      err -> err
    end
  end

  defp decode_keep("first"), do: :first
  defp decode_keep("second"), do: :second
  defp decode_keep("both"), do: :both
  defp decode_keep(_), do: :second

  defp decode_compare_kind("eq"), do: :eq
  defp decode_compare_kind("ne"), do: :ne
  defp decode_compare_kind("lt"), do: :lt
  defp decode_compare_kind("gt"), do: :gt
  defp decode_compare_kind("lte"), do: :lte
  defp decode_compare_kind("gte"), do: :gte
  defp decode_compare_kind(k), do: k
end
