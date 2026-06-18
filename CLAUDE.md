# Agent Control Daemon — Context for Claude

## What this is

The Elixir backend for the **Agent Control Daemon (ACD)**. It is a runtime for agent programs — an orchestration layer that receives structured op programs from client harnesses, interprets them, spawns and supervises LLM agent processes, dispatches tool calls to registered machines, and streams state back to clients in real time via SSE.

## Core mental model

```
op program  =  source code     (JSON instructions)
daemon      =  runtime         (interprets and executes)
agents      =  processes       (like threads in a normal language, managed by OTP)
```

The client sends op programs and runs **nothing itself**. All agent logic, LLM calls, and tool execution live in the daemon. Complex operations are intended to eventually compile to WASM (analogous to SQL sanitization — safe, sandboxed, portable).

## Registered machines

The "registered machines" concept refers to the machine(s) the client/harness is running on. A client harness registers its machine with the daemon. The executor then dispatches tool calls and serializes state to those registered machines. **Client harness libraries are being developed separately** — this daemon is the server side only. When tools are implemented for real, they dispatch to registered machines rather than running inline.

## The op set (instruction set)

Op programs are JSON documents. The executor reads them and performs actions. The full intended op set from the architecture diagram:

### Chain ops (control flow)
| Op | Status | Description |
|---|---|---|
| `then` | ✅ implemented | Run first, then second, keep one result |
| `when` | ❌ missing | Conditional — run body if condition is true |
| `while` | ❌ missing | Loop — run body while condition is true |

### Comparison ops (used in when/while conditions)
| Op | Status | Description |
|---|---|---|
| `eq` | ❌ missing | Equality check |
| `lt` | ❌ missing | Less than |
| `gt` | ❌ missing | Greater than |

### Tool ops
| Op | Status | Description |
|---|---|---|
| `call_tool` | ✅ implemented (stubbed) | Execute a named tool with resolved args |
| `load_context` | ❌ missing | Load data into LLM context without executing |

### Intervention ops
| Op | Status | Description |
|---|---|---|
| `interrupt` (ask_human) | ✅ implemented | Pause and wait for human reply via /resume |
| `request_direction` | ❌ missing | Ask LLM for direction before continuing |
| `spawn_agent` | ❌ missing | Spin up a sub-agent session and wait for result |

### Personality effects (manifest-level)
| Field | Status | Description |
|---|---|---|
| `starter_prompt` | ✅ implemented | System prompt for the agent's LLM |
| `tools` | ✅ implemented (schemas) | Named tools available to the agent |

### Slot ops (state)
| Op | Status | Description |
|---|---|---|
| `slot_set` | ✅ implemented | Assign a slot to the result of an op |
| `slot_get` | ✅ implemented | Read a slot value |

### Missing utility ops
| Op | Description |
|---|---|
| `literal` | Inject a static string value — critical for testing without a human interrupt |

## Agent / session architecture

Each agent is an Elixir **GenServer** (`Daemon.Session`) supervised by `DynamicSupervisor` (`Daemon.SessionSupervisor`). Agents are OTP processes — the supervisor tree IS the agent tree.

```
Daemon.Application
├── Daemon.PubSub              Phoenix.PubSub — event fan-out for SSE
├── Daemon.SessionRegistry     Registry — look up sessions by ID
├── Daemon.SessionSupervisor   DynamicSupervisor — manages agent processes
│   └── Daemon.Session         GenServer — one per active agent
└── Daemon.HTTP                Bandit + Plug router
```

- `parent_id` exists on `Daemon.Session` struct but is **not yet wired** — intended for sub-agent trees
- Spawning sub-agents (`spawn_agent` op) will create child GenServer sessions with `parent_id` set
- The parent blocks (via `receive`) until the child broadcasts `:finished`, same pattern as `interrupt`
- Parallel agents: `Task.async_stream` over multiple `spawn_agent` ops

## LLM provider layer

Provider-agnostic via a behaviour:

```
Daemon.LLM.Client      — thin dispatcher, reads plan.provider
Daemon.LLM.OpenAI      — default, gpt-4o, OPENAI_API_KEY env var
Daemon.LLM.Anthropic   — claude-opus-4-7, ANTHROPIC_API_KEY env var
```

Switch provider by passing `provider: :anthropic` in the plan map. Currently OpenAI is hardcoded as default in `session/loop.ex`.

The agent loop (`Session.Loop.agent_loop/3`) is recursive:
- `:end_turn` → broadcast `:finished`, done
- `:tool_calls` → dispatch each via `Daemon.Tool.execute/2`, feed results back, recurse

## Tool layer

`Daemon.Tool` is fully **stubbed** — all tools return `{:ok, "tool result for #{name}"}`.

Real tool definitions exist for the LLM's benefit:
- `search` — query string
- `read` — path string
- `write` — path + content
- `http_get` — url string
- fallback — generic input string

When tools are implemented for real, they should dispatch to registered machines.

## SSE event types

| Event | Payload |
|---|---|
| `thinking` | `{}` |
| `tool_started` | `{name}` |
| `tool_completed` | `{name, result}` |
| `intervention_required` | `{id, prompt}` |
| `finished` | `{content}` |
| `cancelled` | `{}` |

## HTTP API

```
POST /sessions/:id/run      Start a session with a program
GET  /sessions/:id/events   SSE stream of events
POST /sessions/:id/resume   Reply to an interrupt
```

## Known gaps (not bugs, design work needed)

1. **No `literal` op** — can't inject text into the LLM context without a human interrupt. Makes testing hard.
2. **No `when` / `while` / comparison ops** — no conditional or loop logic in op programs.
3. **No `spawn_agent` op** — sub-agent trees not yet possible. `parent_id` is wired in struct but unused.
4. **No `load_context` op** — no way to load data into LLM context vs executing a tool.
5. **Registered machine dispatch not implemented** — tools run inline as stubs instead of dispatching to client machines.
6. **`Session.Loop` always calls LLM** — even when the op tree is just control flow. Should be explicit.

## Testing locally

```bash
# Terminal 1 — start server
iex -S mix

# Terminal 2 — open SSE stream
curl -N http://localhost:4000/sessions/session1/events

# Terminal 3 — send program (nushell: use file, not inline -d)
'{ ...json... }' | save -f /tmp/program.json
curl -X POST -H "Content-Type: application/json" -d @/tmp/program.json http://localhost:4000/sessions/session1/run
```

Nushell note: inline `-d 'json'` with curl mangles the body. Always save to file and use `@/tmp/file.json`.

## Dependencies

| Package | Purpose |
|---|---|
| `bandit` | HTTP server |
| `plug` | HTTP routing |
| `req` | HTTP client for LLM API calls |
| `jason` | JSON encoding/decoding |
| `phoenix_pubsub` | Internal event fan-out for SSE |
