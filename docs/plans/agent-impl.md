# Littleagent Implementation Plan

## 1. Objective

Build the first usable version of `littleagent` in Elixir. The agent should provide the basic behavior expected from a Pi-style coding agent:

- accept a user prompt and maintain a conversation;
- run a model/tool agent loop until the model produces a final answer or the run stops;
- expose a structured stream of lifecycle and assistant events;
- discover and load local skills and make their instructions available to the model;
- keep the core deterministic and testable through injected model, tool, filesystem, and clock boundaries.

The first release is a single-agent, local process. It should be useful as a library and have a small command-line integration point once the core is stable.

## 2. Scope and explicit non-goals

### In scope

- Elixir/OTP application structure and supervision.
- A conversation/message model with roles for system, user, assistant, and tool.
- A model adapter contract that supports streamed or complete responses.
- An agent loop that handles assistant text, tool calls, tool results, continuation, completion, cancellation, and failures.
- A small built-in tool registry and a safe tool execution boundary suitable for coding-agent work.
- Structured events emitted during every run.
- Skill discovery, validation, loading, ordering, and prompt integration.
- A basic terminal user interface (TUI) for interactive runs.
- Slash commands such as `/login` and `/exit`.
- Run limits, cancellation, error normalization, and observability hooks.
- Unit, integration, property, and end-to-end tests for the above behavior.

### Out of scope for the first release

- MCP clients or servers.
- Multi-agent orchestration, delegation, or agent-to-agent messaging.
- Distributed execution, clustering, or remote tool workers.
- A provider-specific implementation tied permanently to one model vendor.
- Long-term memory, vector search, RAG, or persistent conversation storage.
- A full-featured terminal UI, web UI, or production sandbox. The first release includes only a basic interactive TUI.

These exclusions should remain visible in module boundaries so they can be added later without changing the agent loop contract.

## 3. Design principles

1. **Small pure core.** Message normalization, state transitions, skill selection, and event construction should be pure functions where practical.
2. **Explicit effects.** Model calls, tool execution, filesystem access, time, and cancellation should be behind behaviours or adapters.
3. **Observable by default.** Every externally meaningful transition should have a stable event with a run ID and sequence number.
4. **Bounded execution.** A run must have configurable limits for turns, tool calls, elapsed time, and output size.
5. **Safe extension points.** New model providers, tools, and skill sources should implement contracts rather than modify the loop.
6. **English documentation.** Public docs, module docs, examples, and skill metadata must be written in English.

## 4. Proposed project layout

Create a standard Mix project and keep public boundaries apparent in the directory structure:

```text
lib/
  littleagent.ex                 # Public facade
  littleagent/application.ex     # OTP supervision tree
  littleagent/agent/
    loop.ex                      # Run state machine
    state.ex                     # Immutable run state
    config.ex                    # Validated run options
  littleagent/conversation/
    message.ex                   # Message structs and validation
    transcript.ex                # Append/query transcript
  littleagent/model/
    adapter.ex                   # Behaviour for model providers
    request.ex
    response.ex
  littleagent/tools/
    tool.ex                      # Tool behaviour and metadata
    registry.ex
    executor.ex
  littleagent/skills/
    skill.ex                     # Skill metadata and content
    loader.ex
    registry.ex
    prompt.ex
  littleagent/events/
    event.ex                     # Event structs/types
    publisher.ex                  # PubSub or subscriber delivery
  littleagent/errors.ex           # Normalized error types
  littleagent/runtime.ex          # Run lifecycle and cancellation
  littleagent/tui/
    application.ex                # Interactive TUI entry point
    renderer.ex                   # Event-to-terminal rendering
    input.ex                      # Line input and command parsing
    command.ex                    # Slash command definitions/dispatch
    session.ex                    # TUI session state
test/
  ...
priv/skills/                      # Optional built-in skills
docs/
  plans/agent-impl.md
```

The exact file split can be adjusted while implementing, but the contracts between these areas should remain stable.

## 5. Public API and lifecycle

The facade should expose a small API before any provider-specific details:

```elixir
Littleagent.start_run(prompt, opts) :: {:ok, run_id} | {:error, reason}
Littleagent.run(prompt, opts) :: {:ok, result} | {:error, reason}
Littleagent.subscribe(run_id, subscriber) :: :ok | {:error, reason}
Littleagent.cancel(run_id) :: :ok | {:error, :not_found}
Littleagent.get_run(run_id) :: {:ok, snapshot} | {:error, :not_found}
```

`start_run/2` should return promptly and execute under a supervised run process. `run/2` may be a synchronous convenience wrapper that collects terminal events. A run has a unique ID, a monotonic event sequence, a status (`:pending`, `:running`, `:completed`, `:failed`, or `:cancelled`), a transcript, counters, and timestamps.

The API should validate options before starting work. Required dependencies—model adapter, tool registry, skill roots, and limits—must have defaults only when they are safe and deterministic for local development.

## 6. Basic TUI and command interface

The first interactive experience should be a small terminal session built on top of the public run and event APIs. Keep terminal concerns outside the agent loop so the same core can later be used by another client. The TUI should support:

- a startup banner and a visible input prompt;
- multiline-safe rendering of assistant text and tool activity;
- incremental rendering of streamed `message_delta` events;
- compact status indicators for running, waiting for a tool, completed, failed, and cancelled states;
- a scrollable in-memory transcript for the current session;
- clean handling of terminal resize, EOF, Ctrl-C, and `/exit`;
- a configurable non-interactive mode for scripted tests.

Use an adapter around terminal I/O rather than calling `IO` throughout the session code. A simple ANSI renderer is sufficient initially; full-screen alternate-buffer behavior, mouse support, syntax highlighting, and rich layout are follow-up work. The renderer must degrade to plain text when ANSI output is disabled or the terminal is not interactive.

### Input and slash-command parsing

Each input line should be classified as either a user prompt or a slash command. Parsing should trim only the command envelope, preserve prompt text, split the command name from arguments, and return a structured error for an unknown or malformed command. Commands are case-sensitive and use a stable registry so new commands do not require changes to the input loop.

Initial commands:

- `/login [provider]`: start or update the local provider authentication flow. The first implementation should define an injected credential/auth adapter and may provide a clear placeholder response when no provider is configured. It must never echo secrets or place tokens in the event stream.
- `/exit`: request graceful session shutdown, cancel the active run if one exists, flush pending terminal output, and return control to the operating system.
- `/help [command]`: display available commands and concise usage.
- `/clear`: clear the visible transcript while retaining only the state needed by the active run, if any.
- `/cancel`: cancel the active run without exiting the TUI.
- `/skills`: list loaded or selectable skills and their source paths without dumping full instruction contents.

Command results should be represented as TUI-local messages or dedicated UI events; they should not be sent to the model as user messages unless a command explicitly requests that behavior. While a run is active, the TUI should either queue one next prompt or report that input is unavailable according to a configured policy. `/cancel` and `/exit` must remain available during a run.

### Session state and shutdown

`Littleagent.TUI.Session` should track the current run ID, displayed transcript, command registry, authentication status, selected skills, renderer mode, and shutdown flag. It subscribes to run events and maps them to rendering actions. Terminal shutdown is successful only after the run process receives cancellation and emits a terminal event, or after a bounded shutdown timeout with a diagnostic message.

Authentication state belongs behind an `Auth` behaviour or adapter. Store credentials through an explicitly selected local mechanism and keep the TUI independent of provider-specific login details. `/login` should be testable with a fake adapter and should report success, cancellation, and failure as safe user-facing messages.

## 7. Message and transcript model

Define versioned structs rather than passing arbitrary maps through the core. At minimum:

- `system`: generated system prompt and selected skill instructions;
- `user`: user input;
- `assistant`: text, optional reasoning metadata if the adapter supplies it, and zero or more tool calls;
- `tool`: tool call ID, tool name, normalized result, and error status.

Each message should carry a stable ID, creation time, and metadata map. Tool-call IDs must correlate the assistant request with its tool result. The transcript module should support append, last message, token/character estimates, and conversion to the model adapter request format.

Do not expose provider-specific wire formats outside the model adapter. Normalize malformed provider output into an explicit error event.

## 8. Model adapter contract

Define a behaviour with two supported response modes:

```elixir
@callback complete(request, context) :: {:ok, response} | {:error, reason}
@callback stream(request, context) :: {:ok, enumerable} | {:error, reason}
```

The loop should prefer streaming when configured, while allowing a complete-response adapter in tests and simple integrations. Normalized response chunks should represent text deltas, tool-call deltas, usage, finish reason, and provider metadata. The adapter owns authentication, HTTP details, retries appropriate to the provider, and provider response parsing; the loop owns policy and state transitions.

Add a deterministic fake adapter for tests. It should accept a scripted sequence of responses so tests can cover multi-turn tool calls, malformed output, provider failures, and cancellation without network access.

## 9. Agent loop behavior

Implement the loop as an explicit state machine rather than deeply nested recursive calls. A normal run is:

1. Validate options and create run state.
2. Load and select skills, build the system prompt, and emit `run_started`.
3. Append the user message and emit `message_started`/`message_completed` as appropriate.
4. Build a model request from the system prompt and transcript.
5. Stream or receive the assistant response, emitting text/tool-call deltas and accumulating a normalized assistant message.
6. If the response has no tool calls and has a terminal finish reason, append it and emit `run_completed`.
7. If tool calls are present, validate each call against the registry, execute allowed calls, append tool messages, and emit tool events.
8. Check cancellation and every configured limit.
9. Continue from step 4 until completion, failure, cancellation, or a limit is reached.

The loop must define behavior for multiple tool calls in one assistant response. The initial implementation may execute them sequentially to keep ordering and failure handling clear; the executor boundary can later support parallel execution. A failed tool call should be represented in the transcript and allow the model to recover unless the policy marks the error fatal.

The loop must never silently discard a partial assistant response. On cancellation or provider failure, preserve accumulated text and emit a terminal event containing the reason and partial result metadata.

## 10. Tool boundary

Define tool metadata (`name`, description, input schema, side-effect class, timeout, and whether confirmation is required) separately from the execution callback. The registry should reject duplicate names and validate arguments before execution.

The executor should:

- enforce per-tool and per-run timeouts;
- attach the run ID and tool-call ID to logs/events;
- normalize return values to bounded, model-readable text or structured JSON;
- capture exceptions and exits as tool errors;
- check cancellation before and during long operations;
- leave room for an approval callback, even if the first release uses an explicit policy such as `:allow` or `:deny`.

Start with a minimal set of local tools only if needed by the first CLI demo. Each tool must document its side effects. Do not add an MCP bridge; future integrations should implement a separate registry adapter.

## 11. Event protocol

Events are the primary integration surface. Define a versioned event struct with:

- `run_id`;
- `seq` (strictly increasing per run);
- `type`;
- `occurred_at`;
- `payload`;
- optional `parent_id`/`tool_call_id` correlation fields.

Initial event types:

- `run_started`, `run_completed`, `run_failed`, `run_cancelled`;
- `skill_loaded`, `skill_skipped`, `skill_error`;
- `message_started`, `message_delta`, `message_completed`;
- `tool_call_started`, `tool_call_delta`, `tool_call_completed`, `tool_call_failed`;
- `limit_reached` and `warning`.

Use atoms internally but provide a serialization-safe representation for JSON or CLI consumers. Event delivery should support a subscriber process and a buffered collector used by `run/2`. Define backpressure behavior: a slow subscriber must not block the agent loop; delivery failures should be isolated and observable.

## 12. Skill system

### File format and discovery

Support skills stored beneath configured roots such as `priv/skills` and a user-level directory. Each skill is a directory containing `SKILL.md`; optional supporting files may be referenced by relative path. `SKILL.md` should contain English Markdown with a small front matter block:

```yaml
name: shell-safety
description: Rules for safe shell command execution.
priority: 100
enabled: true
tags: [coding, safety]
```

The loader must validate the name, required description, front matter types, path containment, and file size. Invalid skills should produce `skill_error` and follow a configurable policy (`:skip` by default, `:fail` for strict startup).

### Selection and prompt integration

The registry should index skills by name and tags, preserve source precedence, and make selection deterministic. Run options may select skills explicitly; a future selector can add relevance-based selection without changing the prompt interface. Explicitly selected skills should be loaded in stable priority/name order and deduplicated.

The prompt builder should separate core system instructions, selected skill content, tool descriptions, and run-specific limits. It must expose the selected skill list in run metadata so the same prompt can be reproduced in tests and diagnostics. Avoid executing arbitrary code from a skill; skills are instructions and resources only.

## 13. Configuration, limits, and errors

Create a validated configuration struct with defaults for:

- model adapter and model name;
- tool registry and tool policy;
- skill roots and selected skill names;
- max turns, max tool calls, max elapsed time, and max output size;
- streaming mode;
- subscriber delivery and error policy.

Define normalized error categories: invalid input, adapter failure, malformed model response, unknown/invalid tool, tool failure, skill failure, cancellation, and limit reached. Every terminal error should retain a safe human-readable message plus machine-readable category and retryability. Never expose secrets from adapter errors or tool output.

## 14. OTP and concurrency plan

Use an application supervisor for global registries and a dynamic supervisor for run processes. A run process owns mutable lifecycle state; registries can be long-lived and read-only from the loop's perspective. Cancellation should be a message or monitored signal handled by the run process, not an uncoordinated process kill, so the terminal event and partial result are emitted consistently.

Keep PubSub or an equivalent event publisher behind a module boundary. The initial implementation can use built-in Registry/PubSub facilities, but tests should be able to inject a synchronous publisher.

## 15. Testing and verification strategy

Implement tests alongside each phase:

- **Pure unit tests:** message validation, transcript operations, config validation, skill front matter parsing, deterministic ordering, event sequence generation, and prompt construction.
- **Loop tests with fake adapters/tools:** final text, one and multiple tool calls, tool errors and recovery, malformed responses, cancellation, each limit, provider failure, and partial output preservation.
- **Event contract tests:** event types, required fields, sequence monotonicity, correlation IDs, terminal-event uniqueness, and subscriber isolation.
- **Skill integration tests:** multiple roots and precedence, explicit selection, invalid files, path traversal attempts, duplicate names, and prompt reproducibility.
- **TUI and command tests:** command parsing and quoting, unknown-command errors, `/login` success/failure without secret leakage, `/exit` cancellation and shutdown, `/cancel`, `/help`, `/clear`, `/skills`, ANSI-disabled rendering, streamed deltas, EOF, and Ctrl-C behavior.
- **OTP tests:** supervised run startup, crash cleanup, concurrent runs, cancellation races, and registry lifecycle.
- **Property tests:** no run emits two terminal events; sequence numbers are strictly increasing; every tool result references a prior tool call; selected skill order is deterministic.
- **Optional end-to-end test:** a scripted fake model drives a short coding task through the public facade and verifies the collected event stream and final result.

Run `mix format --check-formatted`, `mix test`, and static analysis (such as Credo) in CI once the Mix project exists. Network-provider tests should be opt-in and never required for the default suite.

## 16. Delivery phases

### Phase 0: Project skeleton

- Initialize Mix application and supervision tree.
- Add formatter, test configuration, documentation conventions, and CI commands.
- Add the public facade with stable placeholder contracts.

**Exit criteria:** application starts, tests run, and public modules have docs.

### Phase 1: Core data and event contracts

- Implement message, transcript, config, errors, event, and publisher modules.
- Add serialization-safe event and message representations.

**Exit criteria:** pure unit tests pass and event contract is documented.

### Phase 2: Model adapter and loop

- Implement adapter behaviours, fake scripted adapter, run state, and explicit loop.
- Support text-only completion, streaming accumulation, terminal states, cancellation, and limits.

**Exit criteria:** a fake adapter can complete a run through the public facade with a reproducible event stream.

### Phase 3: Tools

- Implement tool behaviour, registry, argument validation, executor, timeout/error policy, and one or two documented local tools.
- Add model continuation after tool results.

**Exit criteria:** tests cover successful, failed, denied, timed-out, and cancelled tool calls.

### Phase 4: Skills

- Implement loader, parser, registry, selection, precedence, and prompt builder.
- Add example built-in skills under `priv/skills` and fixtures for invalid skills.

**Exit criteria:** selected skills are deterministic, visible in metadata/events, and included in the model request.

### Phase 5: Integration surface

- Add the synchronous `run/2` collector and the basic interactive TUI after core behavior is stable.
- Implement the command registry/parser and `/help`, `/login`, `/exit`, `/clear`, `/cancel`, and `/skills`.
- Add ANSI/plain-text rendering, terminal input abstraction, graceful shutdown, and operator-facing diagnostics.

**Exit criteria:** a user can start an interactive terminal session, enter a prompt, observe streamed events, use `/login` and `/exit`, cancel a run, and understand failures without reading internals. The same command parser and renderer can be exercised without a real terminal.

## 17. Open decisions to resolve during implementation

1. Which model provider should receive the first concrete adapter, and which HTTP client will be supported?
2. Should the default event transport use PubSub, per-run subscribers, or both?
3. Which local tools are safe and useful enough for the first demo?
4. What confirmation policy is appropriate for filesystem and shell side effects?
5. Should skill roots include only project-local paths initially, or also a user-global path?
6. What output/token estimation is sufficient before a provider supplies usage data?
7. Should the first TUI use line-oriented input only, or depend on a terminal UI library for full-screen behavior?
8. Which credential storage and provider authentication flow should back `/login`?

Resolve these decisions through small interfaces and tests rather than embedding them in the loop. Any decision that expands scope toward MCP, multi-agent execution, persistent memory, or distributed operation should be recorded as a separate follow-up initiative.

## 18. Definition of done for the first release

The first release is ready when a clean checkout can start the OTP application, execute a complete scripted model run, load a selected Markdown skill, perform a validated tool call, emit a complete ordered event stream, stop on cancellation or limits, and return a normalized final result or error. It must also provide a basic interactive TUI where a user can submit prompts, see streamed output, invoke `/login`, `/help`, `/cancel`, `/skills`, `/clear`, and `/exit`, and leave the session cleanly. The default test suite must be offline, deterministic, and pass with formatting and documentation checks enabled.

## 19. Current implementation status

The first-release scope is implemented and covered by the offline test suite. The
current implementation also includes bounded run snapshot retention, monitored
event subscribers, TUI conversation history, ANSI-disabled rendering, a
full-screen alternate-buffer TUI with editable input and transcript scrolling,
secure filesystem traversal with symlink and cycle handling, configurable
macOS OS-level shell isolation, supervised tool workers, approval and execution
deadlines, and OpenAI-compatible complete and live network-level SSE responses.

The following remain follow-up work: Linux-native sandbox backends and richer
terminal integrations such as mouse support and syntax highlighting. Shell
output is now collected incrementally with a hard byte limit. MCP and
multi-agent execution remain outside this implementation scope.
