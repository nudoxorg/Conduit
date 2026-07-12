# Conduit

**A runtime for agent op programs. Built on the BEAM.**

Conduit is a background daemon that runs on the same machine as an agent harness. Clients send it structured op programs; Conduit interprets them, spawns and supervises LLM-backed agent processes, dispatches tool calls, and streams state back over SSE. All the hard parts (concurrency, streaming, sub-agent trees, human-in-the-loop, retries, LLM providers) live in the daemon so that harness developers can focus on the experience layer.

```
┌──────────────┐    op program (JSON)      ┌────────────────────────┐
│              │  ────────────────────►    │                        │
│  any client  │                           │        Conduit         │
│  (any lang)  │  ◄────────────────────    │                        │
│              │    SSE event stream       └────────────────────────┘
└──────────────┘                                     │
                                                     │  OTP supervision tree
                                                     │  — one process per agent
                                                     │  — sub-agents = child procs
                                                     │  — real tools, LLM streaming
                                                     ▼
```

---

## Why it exists

Every serious agent harness eventually needs the same primitives: a supervision tree, sub-agents that can be interrupted and resumed, streaming tool + LLM output, retries and timeouts, backpressure, structured logs. These are non-trivial to build once, painful to build in every harness.

The BEAM has all of it — GenServers, DynamicSupervisor, Registry, Task, PubSub. Conduit wraps those primitives in an opaque, language-agnostic wire protocol so a harness in Swift, TypeScript, Python, Rust, whatever, can drive real OTP processes without touching Elixir.

You POST a program. You get an event stream back. That's the whole surface.

---

## Quick start

**Requirements:** Elixir 1.18+, OTP 27+, a provider API key.

```bash
git clone <repo> && cd daemon
mix deps.get
export ANTHROPIC_API_KEY=sk-ant-...   # or OPENAI_API_KEY
iex -S mix
```

The HTTP server starts on port `4000`.

Talk to it with `curl`:

```bash
# Terminal 1 — open the event stream
curl -N http://localhost:4000/sessions/s1/events

# Terminal 2 — send a program
curl -X POST http://localhost:4000/sessions/s1/run \
  -H "Content-Type: application/json" \
  -d '{
    "program": {
      "manifest": {
        "personality": {
          "use_llm": true,
          "provider": "anthropic",
          "model": "claude-opus-4-7",
          "system": "You are a helpful assistant.",
          "tools": ["shell", "read"]
        }
      },
      "body": { "op": "literal", "value": "list the files in /tmp" }
    }
  }'
```

Terminal 1 streams token deltas, tool calls, and a final `finished` event as the model runs.

---

## Public API

The daemon exposes three things: a set of HTTP endpoints, a stream of SSE events, and a JSON op set.

### HTTP

| Endpoint | Purpose |
|---|---|
| `GET  /health` | Liveness probe. |
| `POST /sessions/:id/run` | Start (or re-run) a session with a program. |
| `GET  /sessions/:id/events` | Server-Sent Events stream of session activity. Persistent across runs. |
| `POST /sessions/:id/resume` | Reply to a suspended `interrupt` op. Body: `{"value": <any>}`. |

### SSE events

| Event | Payload |
|---|---|
| `thought` | `{ "text": "..." }` |
| `checkpoint` | `{ "name": "..." }` |
| `tool_started` | `{ "name": "shell" }` |
| `tool_completed` | `{ "name": "shell", "result": "..." }` |
| `text_delta` | `{ "content": "..." }` (streaming LLM tokens) |
| `agent_spawned` | `{ "agent_id": "..." }` |
| `agent_finished` | `{ "agent_id": "...", "result": "..." }` |
| `intervention_required` | `{ "id": "...", "prompt": "..." }` |
| `finished` | `{ "content": "..." }` |
| `error` | `{ "reason": "..." }` |

Keepalive comment (`: keepalive\n\n`) every 30s. The stream stays open across `finished`/`error` — the same connection serves subsequent runs on the same session.

### Op set

An op program is a tree of typed JSON instructions. See **[docs/ops.md](docs/ops.md)** for the full reference — every op, its wire format, semantics, and implementation status.

Currently implemented categories: values & state, time & resilience, sequencing, comparison & control flow, tool dispatch, human-in-the-loop, concurrency (`par`/`race`/`fan_out`), routines, signals, sub-agents.

Stubbed as placeholders for future work: context/memory (`load_context`, `pin`, etc.), guards, ensembles, sampling.

---

## Architecture

```
Daemon.Application
├── Finch                        outbound HTTP pool (for LLM streams)
├── Phoenix.PubSub               internal signal fan-out
├── Daemon.SessionRegistry       Registry — look up sessions by id
├── Daemon.Session.Supervisor    DynamicSupervisor — one child per active session
│   └── Daemon.Session           GenServer — session lifecycle & message hub
└── Bandit                       HTTP server → Daemon.HTTP.Router
```

**Per-session:**

- `Daemon.Session` (GenServer) holds session state — subscribers, event log, conversation history, personality.
- Every run spawns a `Task` that runs `Daemon.Interpreter.run/3` on the op tree.
- The interpreter sends `{:op_result, value, personality}` back to Session when it's done.
- Session decides: if `personality.use_llm`, feed the result into `Daemon.LLM.Loop` (streaming Anthropic/OpenAI); otherwise emit `finished`.
- `spawn_agent` creates a child Session under the same supervisor; the parent Task subscribes to the child, forwards its events upstream, and blocks in a `receive` until the child finishes.

**Multi-turn conversation:**

The Session keeps a `messages` list across runs. When it dies (or the BEAM restarts), history dies with it. Persistent memory is intentionally out of scope for this version.

**Project layout:**

```
lib/daemon/
├── application.ex            supervision tree entry point
├── personality.ex            struct + decoder for the JSON personality
├── manifest.ex               program envelope decoder
├── session.ex                per-session GenServer
├── session/supervisor.ex     DynamicSupervisor
├── interpreter.ex            op eval (~500 loc)
├── interpreter/context.ex    execution state struct
├── op.ex                     Op union type
├── op/                       one file per category — struct definitions
├── op/decoder.ex             JSON → Op structs
├── tool.ex                   built-in tool implementations
├── llm/
│   ├── provider.ex           behaviour + dispatcher
│   ├── anthropic.ex          streaming Claude
│   ├── openai.ex             streaming GPT
│   ├── loop.ex               tool-cycle driver
│   ├── message.ex            unified message shape
│   ├── response.ex           unified response shape
│   ├── error.ex              provider errors
│   └── sse_parser.ex         SSE line parser for provider streams
└── http/
    ├── router.ex             Plug router
    └── event_stream.ex       SSE handler
```

---

## Status

**Alpha.** The core runtime is functional end-to-end: op decoding, interpreter, LLM streaming, tool dispatch, sub-agent trees, multi-turn context, SSE streaming, interrupts. See `docs/ops.md` for per-op status.

**Known limitations:**

- Persistent memory is not implemented. Conversation history lives in the Session GenServer and dies with it.
- The stubbed op categories above (context/memory, guards, ensembles) are decoded but no-op.
- `sandbox` and `budget` are decoded but not enforced.
- Nested `interrupt` (inside a `spawn_agent` body) resumes to the wrong process — the top-level `interrupt` works fine.
- Sub-agent event ordering across concurrent children is not guaranteed.
- No tests yet.

**Not accepting contributions yet.** This will change once the API surface stabilizes.

---

## Client libraries

Client libraries for building harnesses (in various languages) live in separate repositories. The daemon has no opinion about how a client is built — the wire contract in `docs/ops.md` is the only surface a client needs to understand.

A minimal reference client (SwiftUI, macOS) that exercises most of the op surface lives at `../ACD-Client/` in a sibling repo. It's a testing tool, not a template.

---

## Distribution

The daemon runs as a background process alongside the client that talks to it. Packaging (Homebrew, an npm postinstall script, a bundled release inside the harness app, etc.) is not yet decided — it will depend on how harness developers want to ship. For now, run it manually via `iex -S mix` or `mix run --no-halt`.

---

## Development

```bash
mix deps.get         # fetch deps
mix compile          # type-check
iex -S mix           # run the daemon interactively
mix format           # format
```

**Dependencies:**

| Package | Purpose |
|---|---|
| `bandit` | HTTP server |
| `plug` | HTTP routing |
| `req` | HTTP client (LLM streams, `http_get` tool) |
| `finch` | HTTP connection pool — required for OTP 29 + TLS 1.3 |
| `jason` | JSON |
| `phoenix_pubsub` | Signal fan-out for `emit`/`await_signal` |

---

## License

TBD.
