defmodule Daemon.LLM.Anthropic do
  @moduledoc """
  Anthropic Claude provider.

  Streams a response from the Messages API, calling `on_chunk` for each text
  delta and accumulating tool use content blocks as they arrive. Returns a
  unified `Response` when the model's turn ends.

  Requires `ANTHROPIC_API_KEY` in the environment.
  """

  @behaviour Daemon.LLM.Provider

  alias Daemon.LLM.{Response, Error, ToolCall, SSEParser}

  @api_url "https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"
  @max_tokens 8096
  @timeout_ms 120_000

  @impl true
  def available?, do: api_key() not in [nil, ""]

  @impl true
  def stream(plan, messages, on_chunk) do
    case api_key() do
      key when key in [nil, ""] ->
        {:error,
         Error.new(:authentication, message: "ANTHROPIC_API_KEY not set", provider: :anthropic)}

      key ->
        do_stream(key, plan, messages, on_chunk)
    end
  end

  # --- streaming ---

  defp do_stream(api_key, plan, messages, on_chunk) do
    tools = Enum.map(plan.tools || [], &Daemon.Tool.definition/1)

    body =
      %{
        model: plan.model || "claude-opus-4-7",
        max_tokens: @max_tokens,
        messages: format_messages(messages),
        stream: true
      }
      |> maybe_put_system(plan[:system])
      |> maybe_put_tools(tools)

    ref = make_ref()
    parent = self()

    Task.start(fn ->
      result =
        Req.post(@api_url,
          json: body,
          finch: Daemon.Finch,
          receive_timeout: @timeout_ms,
          headers: [{"x-api-key", api_key}, {"anthropic-version", @api_version}],
          into: fn {:data, data}, acc ->
            send(parent, {:chunk, ref, data})
            {:cont, acc}
          end
        )

      case result do
        {:ok, %{status: status}} when status >= 400 ->
          send(parent, {:error, ref, "HTTP #{status}"})

        {:error, reason} ->
          send(parent, {:error, ref, inspect(reason)})

        _ ->
          :ok
      end

      send(parent, {:done, ref})
    end)

    collect(ref, on_chunk, %{text: "", tool_calls: [], curr_tool: nil, stop_reason: nil, buf: ""})
  end

  defp collect(ref, on_chunk, state) do
    receive do
      {:chunk, ^ref, data} ->
        {events, buf} = split_lines(state.buf <> data)
        state = Enum.reduce(events, %{state | buf: buf}, &handle_event(&1, &2, on_chunk))
        collect(ref, on_chunk, state)

      {:error, ^ref, reason} ->
        {:error, Error.new(:provider_error, message: reason, provider: :anthropic)}

      {:done, ^ref} ->
        finish_reason = if state.stop_reason == "tool_use", do: :tool_calls, else: :end_turn

        {:ok,
         %Response{
           content: state.text,
           finish_reason: finish_reason,
           tool_calls: state.tool_calls
         }}
    after
      @timeout_ms ->
        {:error, Error.new(:timeout, message: "stream timed out", provider: :anthropic)}
    end
  end

  # Splits buffered data into complete SSE lines + leftover remainder.
  defp split_lines(data) do
    lines = String.split(data, "\n")
    {complete, [remainder]} = Enum.split(lines, -1)

    events =
      complete
      |> Enum.map(&String.trim/1)
      |> Enum.flat_map(fn line ->
        case SSEParser.parse_line(line) do
          {:ok, event} -> [event]
          _ -> []
        end
      end)

    {events, remainder}
  end

  # --- SSE event handlers ---

  defp handle_event(
         %{
           "type" => "content_block_start",
           "content_block" => %{"type" => "tool_use", "id" => id, "name" => name}
         },
         state,
         _on_chunk
       ) do
    %{state | curr_tool: %{id: id, name: name, args_acc: ""}}
  end

  defp handle_event(
         %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}},
         state,
         on_chunk
       ) do
    on_chunk.(text)
    %{state | text: state.text <> text}
  end

  defp handle_event(
         %{
           "type" => "content_block_delta",
           "delta" => %{"type" => "input_json_delta", "partial_json" => chunk}
         },
         state,
         _on_chunk
       ) do
    case state.curr_tool do
      nil -> state
      tool -> %{state | curr_tool: %{tool | args_acc: tool.args_acc <> chunk}}
    end
  end

  defp handle_event(%{"type" => "content_block_stop"}, state, _on_chunk) do
    case state.curr_tool do
      nil ->
        state

      tool ->
        args =
          case Jason.decode(tool.args_acc) do
            {:ok, parsed} -> parsed
            _ -> %{}
          end

        call = %ToolCall{id: tool.id, name: tool.name, args: args}
        %{state | curr_tool: nil, tool_calls: state.tool_calls ++ [call]}
    end
  end

  defp handle_event(
         %{"type" => "message_delta", "delta" => %{"stop_reason" => reason}},
         state,
         _on_chunk
       ) do
    %{state | stop_reason: reason}
  end

  defp handle_event(_event, state, _on_chunk), do: state

  # --- message formatting ---

  # Anthropic has no system role in messages — system prompt goes in the top-level field.
  # Tool results become user messages with tool_result content blocks.
  # Assistant messages that include tool calls need both text and tool_use content blocks.

  defp format_messages(messages) do
    Enum.map(messages, &format_message/1)
  end

  defp format_message(%{"role" => "tool", "content" => content} = msg) do
    %{
      "role" => "user",
      "content" => [
        %{"type" => "tool_result", "tool_use_id" => msg["tool_call_id"], "content" => content}
      ]
    }
  end

  defp format_message(%{"role" => "assistant", "tool_calls" => calls, "content" => text})
       when is_list(calls) and calls != [] do
    text_blocks = if text && text != "", do: [%{"type" => "text", "text" => text}], else: []

    tool_blocks =
      Enum.map(calls, fn call ->
        %{"type" => "tool_use", "id" => call.id, "name" => call.name, "input" => call.args || %{}}
      end)

    %{"role" => "assistant", "content" => text_blocks ++ tool_blocks}
  end

  defp format_message(%{"role" => role, "content" => content}) do
    %{"role" => role, "content" => [%{"type" => "text", "text" => to_string(content)}]}
  end

  # --- helpers ---

  defp maybe_put_system(body, nil), do: body
  defp maybe_put_system(body, ""), do: body
  defp maybe_put_system(body, system), do: Map.put(body, :system, system)

  defp maybe_put_tools(body, []), do: body
  defp maybe_put_tools(body, tools), do: Map.put(body, :tools, tools)

  defp api_key do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil -> nil
      key -> String.trim(key)
    end
  end
end
