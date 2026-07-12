# Conduit Op Set Reference

Conduit executes **op programs** — trees of typed instructions serialized as JSON. This document is the canonical reference for every op the daemon understands: its wire format, its semantics, and its implementation status.

An op is a JSON object with an `"op"` key naming the instruction, plus fields specific to that op. Nested ops are themselves JSON objects.

```jsonc
{
  "op": "then",
  "first":  { "op": "literal",   "value": "hello" },
  "second": { "op": "thought",   "text":  "handled it" },
  "keep":   "first"
}
```

## Status legend

| Marker | Meaning |
|---|---|
| ✅ | Implemented and behaves as specified |
| 🟡 | Decoded but stubbed — evaluates to `unit`, logs a warning. Reserved for future work. |
| ⚠️ | Partial — some behavior works, some fields ignored |

---

## Values & state

### `nop` ✅
Does nothing. Yields `unit`.
```json
{ "op": "nop" }
```

### `constant` ✅
Wraps a literal value. Yields `value`.
```json
{ "op": "constant", "value": <any> }
```

### `literal` ✅
Like `constant`, semantically identical, kept for backwards compat with older programs. Yields `value`.
```json
{ "op": "literal", "value": <any> }
```

### `slot_get` ✅
Reads a slot from the current context. Yields the slot value or `nil`.
```json
{ "op": "slot_get", "slot": "cursor" }
```

### `slot_set` ✅
Evaluates `value` and stores it in a named slot. Yields `unit`.
```json
{ "op": "slot_set", "slot": "cursor", "value": <op> }
```

### `param_get` ✅
Reads a parameter bound by an enclosing `invoke`, `for_each`, `fan_out`, or `on_signal`. Yields the parameter value.
```json
{ "op": "param_get", "param": "file" }
```

---

## Time & resilience

### `timeout` ✅
Aborts `body` if it takes longer than `ms` milliseconds. Yields the body's output or `{error, :timeout}`.
```json
{ "op": "timeout", "ms": 5000, "body": <op> }
```

### `delay` ✅
Sleeps for `ms` milliseconds. Yields `unit`.
```json
{ "op": "delay", "ms": 1000 }
```

### `try_undo` ✅
Runs `body`. If it fails, runs `undo` as a compensating action (saga pattern).
```json
{ "op": "try_undo", "body": <op>, "undo": <op> }
```

---

## Sequencing & shaping

### `then` ✅
Runs `first`, then `second`. `keep` selects which output propagates: `"first"`, `"second"`, or `"both"`.
```json
{ "op": "then", "first": <op>, "second": <op>, "keep": "second" }
```

### `map` 🟡
Applies a transform to the output of `inner`. Currently the transform is ignored and `inner`'s output passes through unchanged.
```json
{ "op": "map", "inner": <op>, "transform": <transform> }
```

### `choice` ✅
Ordered fallback: tries each branch, yields the first success. If all fail, yields `{error, :all_branches_failed}`.
```json
{ "op": "choice", "branches": [<op>, <op>, ...] }
```

### `repeated` ✅
Repeats `inner` between `min` and `max` times. Yields a list of outputs. `max` may be omitted for unbounded.
```json
{ "op": "repeated", "inner": <op>, "min": 1, "max": 5 }
```

### `ignore` ✅
Runs `inner`, discards output. Yields `unit`.
```json
{ "op": "ignore", "inner": <op> }
```

### `label` ✅
Human-readable trace label. Transparent to execution.
```json
{ "op": "label", "label": "find files", "body": <op> }
```

### `thought` ✅
Records a reasoning step as a `thought` SSE event. Yields `unit`.
```json
{ "op": "thought", "text": "checking each match" }
```

### `checkpoint` ✅
Emits a named `checkpoint` SSE event for potential resumption or audit. Yields `unit`.
```json
{ "op": "checkpoint", "name": "after-scan" }
```

---

## Comparison & control flow

### `compare` ✅
Compares `lhs` to `rhs`. `kind` is one of `"eq"`, `"ne"`, `"lt"`, `"gt"`, `"lte"`, `"gte"`. Yields a boolean.
```json
{ "op": "compare", "kind": "eq", "lhs": <op>, "rhs": <op> }
```

### `when` ✅
Runs `body` only if `condition` yields a truthy value. Yields `{:some, <body_result>}` or `:none`.
```json
{ "op": "when", "condition": <op>, "body": <op> }
```

### `while` ✅
Runs `body` while `condition` yields true. Yields `unit`.
```json
{ "op": "while", "condition": <op>, "body": <op> }
```

### `for_each` ✅
Evaluates `over` (must yield a list), runs `body` once per element bound to `param`, sequentially. Yields a list of results.
```json
{ "op": "for_each", "over": <op>, "param": "file", "body": <op> }
```

---

## Tools & context

### `call_tool` ✅
Invokes a named tool from the daemon's registry. `args` is a list of ops whose values are passed to the tool. Yields the tool's return value. Unknown tools yield an error.
```json
{ "op": "call_tool", "name": "shell", "args": [<op>, ...] }
```

Built-in tools: `read`, `write`, `list`, `grep`, `shell`, `http_get`. See [tools](tools.md).

### `load_context` 🟡
Loads an external source into the agent's LLM context. Stub — future memory work.
```json
{ "op": "load_context", "source": "s3://bucket/key" }
```

### `compact_context` 🟡
Summarizes and truncates interaction history. Stub — future memory work.
```json
{ "op": "compact_context" }
```

### `forget_after` 🟡
Discards history after a named mark. Stub — future memory work.
```json
{ "op": "forget_after", "mark": "session-start" }
```

### `pin` 🟡
Pins a fact so it remains in the top-level context across compactions. Stub — future memory work.
```json
{ "op": "pin", "fact": "user's name is Alex" }
```

---

## Human in the loop

### `interrupt` ✅
Suspends the interpreter until a human replies. The daemon emits an `intervention_required` SSE event carrying `id` and `prompt`. Execution resumes when the client sends the reply via `POST /sessions/:id/resume`. Yields the reply value.
```json
{ "op": "interrupt", "id": "confirm-delete", "prompt": "Are you sure?" }
```

Optional fields `kind` and `response` are reserved for future typed-response validation.

---

## Execution metadata

### `strategy` ⚠️
Marks a strategy (e.g. `"react"`, `"cot"`) for the body. Currently a pass-through — the label is not enforced.
```json
{ "op": "strategy", "strategy": "react", "body": <op> }
```

### `with_personality` ✅
Overrides the agent's personality for the duration of `body`. Restores the outer personality after.
```json
{ "op": "with_personality",
  "personality": { "use_llm": true, "model": "gpt-4o", ... },
  "body": <op>
}
```

### `budget` 🟡
Declares a token budget for `body`. Currently sets a context field but is not enforced.
```json
{ "op": "budget", "tokens": 8000, "body": <op> }
```

### `sandbox` 🟡
Declares an allowlist of tools for `body`. Currently sets a context field but is not enforced.
```json
{ "op": "sandbox", "allowed_tools": ["read", "list"], "body": <op> }
```

---

## Error recovery

### `retry` ✅
Retries `body` on failure. `policy.max_attempts` sets the ceiling (default `3`).
```json
{ "op": "retry", "policy": { "max_attempts": 5 }, "body": <op> }
```

### `recover` ✅
If `body` fails, runs `fallback` instead.
```json
{ "op": "recover", "body": <op>, "fallback": <op> }
```

### `skip` ✅
If `body` fails, yields `:none`. Otherwise yields `{:some, result}`.
```json
{ "op": "skip", "body": <op> }
```

---

## Guards & steering

### `guard` 🟡
Wraps `body` with a pre- or post-condition. Feeds `feedback` back to the agent on failure and reattempts up to `max_attempts` times. Stub.
```json
{ "op": "guard",
  "phase": "pre",
  "check": <op>,
  "feedback": "Path must be absolute",
  "max_attempts": 3,
  "on_exhausted": "fail",
  "body": <op>
}
```

---

## Concurrency

### `par` ✅
Runs all branches concurrently. Yields a tuple of their outputs. If any branch errors, the whole op errors.
```json
{ "op": "par", "branches": [<op>, <op>, ...] }
```

### `race` ✅
Runs all branches concurrently. Yields the output of the first to succeed. Losers are shut down.
```json
{ "op": "race", "branches": [<op>, <op>, ...] }
```

### `fan_out` ✅
Evaluates `over` (must yield a list), runs `body` per element bound to `param`, concurrently. Yields a list of outputs.
```json
{ "op": "fan_out", "over": <op>, "param": "file", "body": <op>, "join": "list" }
```

---

## Routines

### `invoke` ✅
Calls a named routine declared in the program's `manifest.routines`. Positional `args` are bound as `arg_0`, `arg_1`, ... in the routine's scope.
```json
{ "op": "invoke", "routine": "process_file", "args": [<op>, ...] }
```

---

## Signals

### `emit` ✅
Publishes a payload on a topic. Any op subscribed to the topic (via `await_signal`) receives it. Yields `unit`.
```json
{ "op": "emit", "topic": "cursor.moved", "payload": <op> }
```

### `await_signal` ✅
Blocks until the next message on `topic`. Yields the payload.
```json
{ "op": "await_signal", "topic": "cursor.moved" }
```

### `on_signal` 🟡
Subscribes `body` to a topic; payload is bound to `param`. Stub — async handler registration not yet implemented.
```json
{ "op": "on_signal", "topic": "cursor.moved", "param": "pos", "body": <op> }
```

---

## Advanced agentic patterns

### `shadow` 🟡
Pauses for human review if agent confidence falls below `threshold`. Stub.
```json
{ "op": "shadow", "threshold": 0.7, "body": <op> }
```

### `ensemble` 🟡
Runs `count` independent attempts of `body` and picks a result using `voter`. Stub.
```json
{ "op": "ensemble", "count": 3, "body": <op>, "voter": <op> }
```

### `sample` 🟡
Probabilistically picks one branch from weighted choices. Stub.
```json
{ "op": "sample", "choices": [[0.7, <op>], [0.3, <op>]] }
```

### `on_chunk` 🟡
Runs `body` on every incremental chunk of a streaming output. Stub.
```json
{ "op": "on_chunk", "body": <op> }
```

---

## Agents

### `spawn_agent` ✅
Spawns a child agent session with its own personality running `body`. The parent blocks until the child finishes; child events are forwarded to the parent's SSE stream.

Emits `agent_spawned` and `agent_finished` SSE events on the parent's stream. Yields the child's final result.
```json
{ "op": "spawn_agent",
  "personality": { "use_llm": true, "model": "claude-opus-4-7", ... },
  "body": <op>
}
```

---

## Quick reference

| Op | Category | Status | Yields |
|---|---|---|---|
| `nop` | values | ✅ | `unit` |
| `constant` | values | ✅ | value |
| `literal` | values | ✅ | value |
| `slot_get` | state | ✅ | value or `nil` |
| `slot_set` | state | ✅ | `unit` |
| `param_get` | state | ✅ | value |
| `timeout` | time | ✅ | inner |
| `delay` | time | ✅ | `unit` |
| `try_undo` | resilience | ✅ | inner |
| `then` | sequencing | ✅ | per `keep` |
| `map` | sequencing | 🟡 | inner (transform ignored) |
| `choice` | sequencing | ✅ | first success |
| `repeated` | sequencing | ✅ | list |
| `ignore` | sequencing | ✅ | `unit` |
| `label` | sequencing | ✅ | inner |
| `thought` | sequencing | ✅ | `unit` |
| `checkpoint` | sequencing | ✅ | `unit` |
| `compare` | control | ✅ | boolean |
| `when` | control | ✅ | `{:some, x}` or `:none` |
| `while` | control | ✅ | `unit` |
| `for_each` | control | ✅ | list |
| `call_tool` | tools | ✅ | tool return |
| `load_context` | context | 🟡 | `unit` |
| `compact_context` | context | 🟡 | `unit` |
| `forget_after` | context | 🟡 | `unit` |
| `pin` | context | 🟡 | `unit` |
| `interrupt` | human | ✅ | reply value |
| `strategy` | metadata | ⚠️ | inner |
| `with_personality` | metadata | ✅ | inner |
| `budget` | metadata | 🟡 | inner |
| `sandbox` | metadata | 🟡 | inner |
| `retry` | recovery | ✅ | inner |
| `recover` | recovery | ✅ | inner or fallback |
| `skip` | recovery | ✅ | `{:some, x}` or `:none` |
| `guard` | steering | 🟡 | inner |
| `par` | concurrency | ✅ | tuple |
| `race` | concurrency | ✅ | first winner |
| `fan_out` | concurrency | ✅ | list |
| `invoke` | routines | ✅ | routine output |
| `emit` | signals | ✅ | `unit` |
| `await_signal` | signals | ✅ | payload |
| `on_signal` | signals | 🟡 | `unit` |
| `shadow` | agentic | 🟡 | inner |
| `ensemble` | agentic | 🟡 | inner |
| `sample` | agentic | 🟡 | inner |
| `on_chunk` | agentic | 🟡 | `unit` |
| `spawn_agent` | agents | ✅ | child result |
