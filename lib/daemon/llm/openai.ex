defmodule Daemon.LLM.OpenAI do
  @moduledoc """
  OpenAI-compatible provider.

  Works with OpenAI or any endpoint that speaks the chat completions format
  (OpenRouter, Together, Groq, local vLLM, etc.). Set a custom base URL via
  the `:openai_base_url` application config key or the `OPENAI_BASE_URL`
  env var.

  Streams a response, calling `on_chunk` for each text delta and accumulating
  tool call argument deltas by index. Returns a unified `Response` when the
  turn ends.

  Requires `OPENAI_API_KEY` in the environment (or `opts[:api_key]`).
  """

  @behaviour Daemon.LLM.Provider

  alias Daemon.LLM.{Response, Error, ToolCall, SSEParser}

  @default_base_url "https://api.openai.com/v1"
  @max_tokens 4096
  @timeout_ms 60_000

  @impl true
  def available?, do: api_key() not in [nil, ""]

  @impl true
  def stream(plan, messages, on_chunk) do
    case api_key() do
      key when key in [nil, ""] ->
        {:error, Error.new(:authentication, message: "OPENAI_API_KEY not set", provider: :openai)}

      key ->
        do_stream(key, plan, messages, on_chunk)
    end
  end

  # --- streaming ---

  defp do_stream(api_key, plan, messages, on_chunk) do
    tools = Enum.map(plan.tools || [], &Daemon.Tool.definition/1)
    url = base_url() <> "/chat/completions"

    body =
      %{
        model: plan.model || "gpt-4o",
        messages: format_messages(plan[:system], messages),
        stream: true,
        max_tokens: @max_tokens
      }
      |> maybe_put_tools(tools)

    ref = make_ref()
    parent = self()

    Task.start(fn ->
      result =
        Req.post(url,
          json: body,
          finch: Daemon.Finch,
          receive_timeout: @timeout_ms,
          headers: [
            {"Authorization", "Bearer #{api_key}"},
            {"Content-Type", "application/json"}
          ],
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

    collect(ref, on_chunk, %{text: "", tool_acc: %{}, finish_reason: nil, buf: ""})
  end

  defp collect(ref, on_chunk, state) do
    receive do
      {:chunk, ^ref, data} ->
        {events, buf} = split_lines(state.buf <> data)
        state = Enum.reduce(events, %{state | buf: buf}, &handle_event(&1, &2, on_chunk))
        collect(ref, on_chunk, state)

      {:error, ^ref, reason} ->
        {:error, Error.new(:provider_error, message: reason, provider: :openai)}

      {:done, ^ref} ->
        tool_calls = finalize_tools(state.tool_acc)
        finish_reason = if state.finish_reason == "tool_calls", do: :tool_calls, else: :end_turn

        {:ok,
         %Response{
           content: state.text,
           finish_reason: finish_reason,
           tool_calls: tool_calls
         }}
    after
      @timeout_ms ->
        {:error, Error.new(:timeout, message: "stream timed out", provider: :openai)}
    end
  end

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

  defp handle_event(%{"choices" => [choice | _]}, state, on_chunk) do
    state = handle_delta(choice["delta"] || %{}, state, on_chunk)

    case choice["finish_reason"] do
      nil -> state
      reason -> %{state | finish_reason: reason}
    end
  end

  defp handle_event(_event, state, _on_chunk), do: state

  defp handle_delta(%{"content" => content}, state, on_chunk) when is_binary(content) do
    on_chunk.(content)
    %{state | text: state.text <> content}
  end

  defp handle_delta(%{"tool_calls" => calls}, state, _on_chunk) when is_list(calls) do
    tool_acc =
      Enum.reduce(calls, state.tool_acc, fn call, acc ->
        idx = call["index"]
        current = Map.get(acc, idx, %{id: nil, name: nil, args_acc: ""})

        current =
          current
          |> then(fn c -> if call["id"], do: %{c | id: call["id"]}, else: c end)
          |> then(fn c ->
            name = get_in(call, ["function", "name"])
            if name, do: %{c | name: name}, else: c
          end)
          |> then(fn c ->
            chunk = get_in(call, ["function", "arguments"]) || ""
            %{c | args_acc: c.args_acc <> chunk}
          end)

        Map.put(acc, idx, current)
      end)

    %{state | tool_acc: tool_acc}
  end

  defp handle_delta(_delta, state, _on_chunk), do: state

  defp finalize_tools(tool_acc) when map_size(tool_acc) == 0, do: []

  defp finalize_tools(tool_acc) do
    tool_acc
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map(fn {_idx, tool} ->
      args =
        case Jason.decode(tool.args_acc) do
          {:ok, parsed} -> parsed
          _ -> %{}
        end

      %ToolCall{id: tool.id, name: tool.name, args: args}
    end)
  end

  # --- message formatting ---

  # OpenAI takes the system prompt as a system-role message at the top of the list.
  # Tool results use the "tool" role with a tool_call_id.
  # Assistant messages with tool calls include a tool_calls array in OpenAI function format.

  defp format_messages(nil, messages), do: Enum.map(messages, &format_message/1)
  defp format_messages("", messages), do: Enum.map(messages, &format_message/1)

  defp format_messages(system, messages) do
    [%{"role" => "system", "content" => system} | Enum.map(messages, &format_message/1)]
  end

  defp format_message(%{"role" => "tool", "content" => content} = msg) do
    %{"role" => "tool", "tool_call_id" => msg["tool_call_id"], "content" => content}
  end

  defp format_message(%{"role" => "assistant", "tool_calls" => calls, "content" => text})
       when is_list(calls) and calls != [] do
    openai_calls =
      Enum.map(calls, fn call ->
        %{
          "id" => call.id,
          "type" => "function",
          "function" => %{
            "name" => call.name,
            "arguments" => Jason.encode!(call.args || %{})
          }
        }
      end)

    %{"role" => "assistant", "content" => text, "tool_calls" => openai_calls}
  end

  defp format_message(%{"role" => role, "content" => content}) do
    %{"role" => role, "content" => content}
  end

  # --- helpers ---

  defp maybe_put_tools(body, []), do: body

  defp maybe_put_tools(body, tools) do
    openai_tools =
      Enum.map(tools, fn tool ->
        %{
          "type" => "function",
          "function" => %{
            "name" => tool.name,
            "description" => tool.description,
            "parameters" => tool.input_schema
          }
        }
      end)

    Map.put(body, :tools, openai_tools)
  end

  defp api_key do
    case System.get_env("OPENAI_API_KEY") || Application.get_env(:daemon, :openai_api_key) do
      nil -> nil
      key -> String.trim(key)
    end
  end

  defp base_url do
    System.get_env("OPENAI_BASE_URL") ||
      Application.get_env(:daemon, :openai_base_url, @default_base_url)
  end
end
