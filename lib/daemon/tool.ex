defmodule Daemon.Tool do
  require Logger

  # @response_truncate_chars 4000
  # messing around with this number
  @response_truncate_chars 10_000

  # --- tool execution ---
  @spec execute(String.t(), map() | list()) :: {:ok, String.t()} | {:error, any()}

  def execute("http_get", %{"url" => url}) do
    Logger.info("tool=http_get url=#{url}")
    http_get(url)
  end

  def execute("http_get", [url | _]) when is_binary(url) do
    Logger.info("tool=http_get url=#{url}")
    http_get(url)
  end

  def execute("read", %{"path" => path}) do
    Logger.info("tool=read path=#{path}")
    read_file(path)
  end

  def execute("read", [path | _]) when is_binary(path) do
    Logger.info("tool=read path=#{path}")
    read_file(path)
  end

  def execute("write", %{"path" => path, "content" => content}) do
    Logger.info("tool=write path=#{path}")
    write_file(path, content)
  end

  def execute("write", [path, content | _]) when is_binary(path) and is_binary(content) do
    Logger.info("tool=write path=#{path}")
    write_file(path, content)
  end

  def execute("list", %{"path" => path}) do
    Logger.info("tool=list path=#{path}")
    list_dir(path)
  end

  def execute("list", [path | _]) when is_binary(path) do
    Logger.info("tool=list path=#{path}")
    list_dir(path)
  end

  def execute("grep", %{"pattern" => pattern, "path" => path}) do
    Logger.info("tool=grep pattern=#{pattern} path=#{path}")
    run_grep(pattern, path)
  end

  def execute("grep", [pattern, path | _]) when is_binary(pattern) and is_binary(path) do
    Logger.info("tool=grep pattern=#{pattern} path=#{path}")
    run_grep(pattern, path)
  end

  def execute("shell", %{"command" => command}) do
    Logger.info("tool=shell command=#{command}")
    run_shell(command)
  end

  def execute("shell", [command | _]) when is_binary(command) do
    Logger.info("tool=shell command=#{command}")
    run_shell(command)
  end

  # fallback (stubbed)
  def execute(name, args) do
    Logger.info("tool=#{name} args=#{inspect(args)} (stubbed)")
    {:ok, "tool result for #{name}"}
  end

  # --- tool schemas/definitions ---
  # network
  def definition("search") do
    %{
      name: "search",
      description: "Search the web for information on a topic. Returns relevant text snippets.",
      input_schema: %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "The search query"}
        },
        required: ["query"]
      }
    }
  end

  def definition("http_get") do
    %{
      name: "http_get",
      description: "Make an HTTP GET request to a URL and return the response body.",
      input_schema: %{
        type: "object",
        properties: %{
          url: %{type: "string", description: "The URL to fetch"}
        },
        required: ["url"]
      }
    }
  end

  # client 
  def definition("read") do
    %{
      name: "read",
      description: "Read the contents of a file at the given path.",
      input_schema: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Absolute or relative file path"}
        },
        required: ["path"]
      }
    }
  end

  def definition("write") do
    %{
      name: "write",
      description: "Write content to a file at the given path.",
      input_schema: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "File path to write to"},
          content: %{type: "string", description: "Content to write"}
        },
        required: ["path", "content"]
      }
    }
  end

  def definition("list") do
    %{
      name: "list",
      description: "List the contents of a directory on the registered machine.",
      input_schema: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Directory path to list"}
        },
        required: ["path"]
      }
    }
  end

  def definition("grep") do
    %{
      name: "grep",
      description: "Search for a pattern within files on the registered machine.",
      input_schema: %{
        type: "object",
        properties: %{
          pattern: %{type: "string", description: "The pattern to search for"},
          path: %{type: "string", description: "File or directory to search in"}
        },
        required: ["pattern", "path"]
      }
    }
  end

  def definition("shell") do
    %{
      name: "shell",
      description: "Run a shell command on the registered machine and return stdout.",
      input_schema: %{
        type: "object",
        properties: %{
          command: %{type: "string", description: "The shell command to run"}
        },
        required: ["command"]
      }
    }
  end

  # context/memory
  def definition("memory_read") do
    %{
      name: "memory_read",
      description: "Read a value from persistent agent memory by key.",
      input_schema: %{
        type: "object",
        properties: %{
          key: %{type: "string", description: "The memory key to read"}
        },
        required: ["key"]
      }
    }
  end

  def definition("memory_write") do
    %{
      name: "memory_write",
      description: "Write a value to persistent agent memory.",
      input_schema: %{
        type: "object",
        properties: %{
          key: %{type: "string", description: "The memory key to write"},
          value: %{type: "string", description: "The value to store"}
        },
        required: ["key", "value"]
      }
    }
  end

  # --- private ---

  # client
  defp read_file(path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, String.slice(content, 0, @response_truncate_chars)}

      {:error, reason} ->
        {:error, "read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp write_file(path, content) do
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, content) do
      {:ok, "wrote #{path}"}
    else
      {:error, reason} -> {:error, "write #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp list_dir(path) do
    case File.ls(path) do
      {:ok, entries} -> {:ok, Enum.join(Enum.sort(entries), "\n")}
      {:error, reason} -> {:error, "list #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp run_grep(pattern, path) do
    case System.cmd("grep", ["-rn", pattern, path], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.slice(output, 0, @response_truncate_chars)}
      {_output, 1} -> {:ok, "no matches"}
      {output, code} -> {:error, "grep exit #{code}: #{String.slice(output, 0, @response_truncate_chars)}"}
    end
  end

  defp run_shell(command) do
    case System.cmd("sh", ["-c", command], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.slice(output, 0, @response_truncate_chars)}
      {output, code} -> {:error, "exit #{code}: #{String.slice(output, 0, @response_truncate_chars)}"}
    end
  end

  # network
  defp http_get(url) do
    case Req.get(url, finch: Daemon.Finch) do
      {:ok, %{status: 200, body: body}} ->
        text = if is_binary(body), do: body, else: Jason.encode!(body)
        {:ok, String.slice(text, 0, @response_truncate_chars)}

      {:ok, %{status: status}} ->
        Logger.warning("tool=http_get url=#{url} status=#{status}")
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        Logger.error("tool=http_get url=#{url} error=#{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end

  # memory/context
end
