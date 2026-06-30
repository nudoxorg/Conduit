defmodule Daemon.Op.Parser do
  alias Daemon.Op, as: Op

  def parse(raw) when is_map(raw) do
    %Op.Program{
      acd: raw["acd"],
      manifest: parse_manifest(raw["manifest"]),
      body: parse_op(raw["body"])
    }
  end

  defp parse_manifest(raw) do
    %Op.Manifest{
      personality: parse_personality(raw["personality"]),
      slots: Enum.map(raw["slots"] || [], &parse_slot/1),
      routines: parse_routines(raw["routines"] || %{})
    }
  end

  defp parse_personality(raw) do
    %Op.Personality{
      starter_prompt: raw["starter_prompt"],
      tools: raw["tools"] || [],
      use_llm: Map.get(raw, "use_llm", true),
      provider: parse_provider(raw["provider"]),
      model: raw["model"]
    }
  end

  defp parse_provider("anthropic"), do: :anthropic
  defp parse_provider("openai"), do: :openai
  defp parse_provider("gemini"), do: :gemini
  defp parse_provider(_), do: nil

  defp parse_slot(raw) do
    %Op.Slot{name: raw["name"], ty: raw["ty"]}
  end

  defp parse_routines(raw) do
    Enum.map(raw, fn {name, op_raw} -> {name, parse_op(op_raw)} end)
    |> Elixir.Map.new()
  end

  # ── values & state ────────────────────────────────────────────────

  def parse_op(%{"op" => "literal"} = raw) do
    %Op.Literal{value: raw["value"]}
  end

  def parse_op(%{"op" => "nop"}) do
    %Op.Nop{}
  end

  def parse_op(%{"op" => "slot_get"} = raw) do
    %Op.SlotGet{slot: raw["slot"]}
  end

  def parse_op(%{"op" => "slot_set"} = raw) do
    %Op.SlotSet{slot: raw["slot"], value: parse_op(raw["value"])}
  end

  def parse_op(%{"op" => "param_get"} = raw) do
    %Op.ParamGet{param: raw["param"]}
  end

  # ── time & resilience ─────────────────────────────────────────────

  def parse_op(%{"op" => "timeout"} = raw) do
    %Op.Timeout{ms: raw["ms"], body: parse_op(raw["body"])}
  end

  def parse_op(%{"op" => "delay"} = raw) do
    %Op.Delay{ms: raw["ms"]}
  end

  def parse_op(%{"op" => "try_undo"} = raw) do
    %Op.TryUndo{body: parse_op(raw["body"]), undo: parse_op(raw["undo"])}
  end

  # ── sequencing & shaping ──────────────────────────────────────────

  def parse_op(%{"op" => "then"} = raw) do
    %Op.Then{
      first: parse_op(raw["first"]),
      second: parse_op(raw["second"]),
      keep: raw["keep"]
    }
  end

  def parse_op(%{"op" => "map"} = raw) do
    %Op.MapOp{inner: parse_op(raw["inner"]), transform: raw["transform"]}
  end

  def parse_op(%{"op" => "choice"} = raw) do
    %Op.Choice{branches: Enum.map(raw["branches"] || [], &parse_op/1)}
  end

  def parse_op(%{"op" => "repeated"} = raw) do
    %Op.Repeated{
      inner: parse_op(raw["inner"]),
      min: raw["min"] || 1,
      max: raw["max"]
    }
  end

  def parse_op(%{"op" => "ignore"} = raw) do
    %Op.Ignore{inner: parse_op(raw["inner"])}
  end

  def parse_op(%{"op" => "label"} = raw) do
    %Op.Label{label: raw["label"], body: parse_op(raw["body"])}
  end

  def parse_op(%{"op" => "thought"} = raw) do
    %Op.Thought{text: raw["text"]}
  end

  def parse_op(%{"op" => "checkpoint"} = raw) do
    %Op.Checkpoint{name: raw["name"]}
  end

  # ── comparison & control ──────────────────────────────────────────

  def parse_op(%{"op" => "compare"} = raw) do
    %Op.Compare{kind: raw["kind"], lhs: parse_op(raw["lhs"]), rhs: parse_op(raw["rhs"])}
  end

  # backwards compat aliases
  def parse_op(%{"op" => "eq"} = raw) do
    %Op.Eq{left: parse_op(raw["left"]), right: parse_op(raw["right"])}
  end

  def parse_op(%{"op" => "lt"} = raw) do
    %Op.Lt{left: parse_op(raw["left"]), right: parse_op(raw["right"])}
  end

  def parse_op(%{"op" => "gt"} = raw) do
    %Op.Gt{left: parse_op(raw["left"]), right: parse_op(raw["right"])}
  end

  def parse_op(%{"op" => "when"} = raw) do
    %Op.When{condition: parse_op(raw["condition"]), body: parse_op(raw["body"])}
  end

  def parse_op(%{"op" => "while"} = raw) do
    %Op.While{condition: parse_op(raw["condition"]), body: parse_op(raw["body"])}
  end

  def parse_op(%{"op" => "foreach"} = raw) do
    %Op.ForEach{
      over: parse_op(raw["over"]),
      param: raw["param"],
      body: parse_op(raw["body"])
    }
  end

  # ── tools & context ───────────────────────────────────────────────

  def parse_op(%{"op" => "call_tool"} = raw) do
    %Op.CallTool{
      name: raw["name"],
      args: Enum.map(raw["args"] || [], &parse_op/1),
      output: raw["output"]
    }
  end

  def parse_op(%{"op" => "load_context"} = raw) do
    %Op.LoadContext{source: raw["source"]}
  end

  def parse_op(%{"op" => "compact_context"}) do
    %Op.CompactContext{}
  end

  def parse_op(%{"op" => "forget_after"} = raw) do
    %Op.ForgetAfter{mark: raw["mark"]}
  end

  def parse_op(%{"op" => "pin"} = raw) do
    %Op.Pin{fact: raw["fact"]}
  end

  # ── interrupts ────────────────────────────────────────────────────

  def parse_op(%{"op" => "interrupt"} = raw) do
    %Op.Interrupt{
      id: raw["id"],
      kind: raw["kind"],
      prompt: raw["prompt"],
      response: raw["response"]
    }
  end

  # ── execution metadata ────────────────────────────────────────────

  def parse_op(%{"op" => "strategy"} = raw) do
    %Op.Strategy{strategy: raw["strategy"], body: parse_op(raw["body"])}
  end

  def parse_op(%{"op" => "with_personality"} = raw) do
    %Op.WithPersonality{
      personality: parse_personality(raw["personality"]),
      body: parse_op(raw["body"])
    }
  end

  def parse_op(%{"op" => "budget"} = raw) do
    %Op.Budget{tokens: raw["tokens"], body: parse_op(raw["body"])}
  end

  def parse_op(%{"op" => "sandbox"} = raw) do
    %Op.Sandbox{allowed_tools: raw["allowed_tools"] || [], body: parse_op(raw["body"])}
  end

  # ── error recovery ────────────────────────────────────────────────

  def parse_op(%{"op" => "retry"} = raw) do
    %Op.Retry{policy: raw["policy"] || %{}, body: parse_op(raw["body"])}
  end

  def parse_op(%{"op" => "recover"} = raw) do
    %Op.Recover{body: parse_op(raw["body"]), fallback: parse_op(raw["fallback"])}
  end

  def parse_op(%{"op" => "skip"} = raw) do
    %Op.Skip{body: parse_op(raw["body"])}
  end

  # ── guards & steering ─────────────────────────────────────────────

  def parse_op(%{"op" => "guard"} = raw) do
    %Op.Guard{
      phase: raw["phase"],
      check: parse_op(raw["check"]),
      feedback: raw["feedback"],
      max_attempts: raw["max_attempts"] || 3,
      on_exhausted: raw["on_exhausted"] || "fail",
      body: parse_op(raw["body"])
    }
  end

  # ── concurrency ───────────────────────────────────────────────────

  def parse_op(%{"op" => "par"} = raw) do
    %Op.Par{branches: Enum.map(raw["branches"] || [], &parse_op/1)}
  end

  def parse_op(%{"op" => "race"} = raw) do
    %Op.Race{branches: Enum.map(raw["branches"] || [], &parse_op/1)}
  end

  def parse_op(%{"op" => "fan_out"} = raw) do
    %Op.FanOut{
      over: parse_op(raw["over"]),
      param: raw["param"],
      body: parse_op(raw["body"]),
      join: raw["join"] || "all"
    }
  end

  # ── routines ──────────────────────────────────────────────────────

  def parse_op(%{"op" => "invoke"} = raw) do
    %Op.Invoke{
      routine: raw["routine"],
      args: Enum.map(raw["args"] || [], &parse_op/1)
    }
  end

  # ── signals ───────────────────────────────────────────────────────

  def parse_op(%{"op" => "emit"} = raw) do
    %Op.Emit{topic: raw["topic"], payload: parse_op(raw["payload"])}
  end

  def parse_op(%{"op" => "await_signal"} = raw) do
    %Op.AwaitSignal{topic: raw["topic"]}
  end

  def parse_op(%{"op" => "on_signal"} = raw) do
    %Op.OnSignal{
      topic: raw["topic"],
      param: raw["param"],
      body: parse_op(raw["body"])
    }
  end

  # ── advanced agentic ──────────────────────────────────────────────

  def parse_op(%{"op" => "shadow"} = raw) do
    %Op.Shadow{threshold: raw["threshold"] || 0.8, body: parse_op(raw["body"])}
  end

  def parse_op(%{"op" => "ensemble"} = raw) do
    %Op.Ensemble{
      count: raw["count"] || 3,
      body: parse_op(raw["body"]),
      voter: parse_op(raw["voter"])
    }
  end

  def parse_op(%{"op" => "sample"} = raw) do
    choices =
      Enum.map(raw["choices"] || [], fn [weight, op_raw] -> {weight, parse_op(op_raw)} end)

    %Op.Sample{choices: choices}
  end

  def parse_op(%{"op" => "on_chunk"} = raw) do
    %Op.OnChunk{body: parse_op(raw["body"])}
  end

  # ── agents ────────────────────────────────────────────────────────

  def parse_op(%{"op" => "spawn_agent"} = raw) do
    %Op.SpawnAgent{
      id: raw["id"],
      personality: parse_personality(raw["personality"]),
      input: if(raw["input"], do: parse_op(raw["input"]), else: nil),
      body: if(raw["body"], do: parse_op(raw["body"]), else: nil)
    }
  end

  def parse_op(unknown) do
    raise "Unknown op: #{inspect(unknown)}"
  end
end
