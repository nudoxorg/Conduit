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
      slots: Enum.map(raw["slots"] || [], &parse_slot/1)
    }
  end

  defp parse_personality(raw) do
    %Op.Personality{
      starter_prompt: raw["starter_prompt"],
      tools: raw["tools"] || []
    }
  end

  defp parse_slot(raw) do
    %Op.Slot{name: raw["name"], ty: raw["ty"]}
  end

  # --- chain ops ---

  def parse_op(%{"op" => "label"} = raw) do
    %Op.Label{label: raw["label"], body: parse_op(raw["body"])}
  end

  def parse_op(%{"op" => "then"} = raw) do
    %Op.Then{
      first: parse_op(raw["first"]),
      second: parse_op(raw["second"]),
      keep: raw["keep"]
    }
  end

  def parse_op(%{"op" => "when"} = raw) do
    %Op.When{condition: parse_op(raw["condition"]), body: parse_op(raw["body"])}
  end

  def parse_op(%{"op" => "while"} = raw) do
    %Op.While{condition: parse_op(raw["condition"]), body: parse_op(raw["body"])}
  end

  # --- comparison ops ---

  def parse_op(%{"op" => "eq"} = raw) do
    %Op.Eq{left: parse_op(raw["left"]), right: parse_op(raw["right"])}
  end

  def parse_op(%{"op" => "lt"} = raw) do
    %Op.Lt{left: parse_op(raw["left"]), right: parse_op(raw["right"])}
  end

  def parse_op(%{"op" => "gt"} = raw) do
    %Op.Gt{left: parse_op(raw["left"]), right: parse_op(raw["right"])}
  end

  # --- slot ops ---

  def parse_op(%{"op" => "slot_set"} = raw) do
    %Op.SlotSet{slot: raw["slot"], value: parse_op(raw["value"])}
  end

  def parse_op(%{"op" => "slot_get"} = raw) do
    %Op.SlotGet{slot: raw["slot"]}
  end

  # --- tool ops ---

  def parse_op(%{"op" => "call_tool"} = raw) do
    %Op.CallTool{
      name: raw["name"],
      args: Enum.map(raw["args"] || [], &parse_op/1),
      output: raw["output"]
    }
  end

  def parse_op(%{"op" => "load_context"} = raw) do
    %Op.LoadContext{value: parse_op(raw["value"])}
  end

  # --- intervention ops ---

  def parse_op(%{"op" => "interrupt"} = raw) do
    %Op.Interrupt{
      id: raw["id"],
      kind: raw["kind"],
      prompt: raw["prompt"],
      response: raw["response"]
    }
  end

  def parse_op(%{"op" => "spawn_agent"} = raw) do
    %Op.SpawnAgent{
      id: raw["id"],
      personality: parse_personality(raw["personality"]),
      input: parse_op(raw["input"])
    }
  end

  # --- utility ops ---

  def parse_op(%{"op" => "literal"} = raw) do
    %Op.Literal{value: raw["value"]}
  end

  def parse_op(unknown) do
    raise "Unknown op: #{inspect(unknown)}"
  end
end
