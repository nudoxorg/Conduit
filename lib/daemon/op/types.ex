defmodule Daemon.Op do
  defmodule Program do
    defstruct [:acd, :manifest, :body]
  end

  defmodule Manifest do
    defstruct [:personality, slots: []]
  end

  defmodule Personality do
    defstruct [:starter_prompt, tools: []]
  end

  defmodule Slot do
    defstruct [:name, :ty]
  end

  # chain ops

  defmodule Label do
    defstruct [:label, :body]
  end

  defmodule Then do
    defstruct [:first, :second, :keep]
  end

  defmodule When do
    defstruct [:condition, :body]
  end

  defmodule While do
    defstruct [:condition, :body]
  end

  # comparison ops

  defmodule Eq do
    defstruct [:left, :right]
  end

  defmodule Lt do
    defstruct [:left, :right]
  end

  defmodule Gt do
    defstruct [:left, :right]
  end

  # slot ops

  defmodule SlotSet do
    defstruct [:slot, :value]
  end

  defmodule SlotGet do
    defstruct [:slot]
  end

  # tool ops

  defmodule CallTool do
    defstruct [:name, :args, :output]
  end

  defmodule LoadContext do
    defstruct [:value]
  end

  # intervention ops

  defmodule Interrupt do
    defstruct [:id, :kind, :prompt, :response]
  end

  defmodule SpawnAgent do
    defstruct [:id, :personality, :input]
  end

  # utility ops

  defmodule Literal do
    defstruct [:value]
  end
end
