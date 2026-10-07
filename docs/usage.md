# Littleagent Usage

## Interactive TUI

Start the terminal UI with:

```sh
mix compile
mix littleagent
```

The Mix task accepts `--endpoint URL`, `--model NAME`, repeated
`--skill-root PATH`, `--no-ansi`, and `--fullscreen` in addition to `--help`.

Set `OPENAI_API_KEY` before starting to use the OpenAI-compatible adapter. The
following environment variables are supported:

- `OPENAI_API_KEY`: provider credential;
- `LITTLEAGENT_OPENAI_ENDPOINT`: compatible chat-completions endpoint;
- `LITTLEAGENT_MODEL`: model name.

The TUI supports `/help`, `/login`, `/skills`, `/reload-skills`, `/status`, `/history`, `/runs`,
`/clear-runs`, `/cancel`, `/clear`, `/exit`, and `/quit`. `/runs` accepts an
optional non-negative limit such as `/runs 10`; `/history` accepts the same
limit to show only the most recent messages. `/skills` accepts an optional
skill name to filter the list. A prompt is rejected while
another run is active. Assistant text is rendered incrementally from
`message_delta` events and terminated with a single newline when the run
completes. `/login openai` validates `OPENAI_API_KEY` and configures the
OpenAI adapter for subsequent prompts. Completed runs remain the session
context, so the next prompt includes earlier user, assistant, and tool
messages. Set `ansi: false` in `Littleagent.TUI.start/1` when output is being
redirected or the terminal does not support ANSI control sequences.
The default renderer also reports run start, skill loading, and tool lifecycle
events as compact status lines.

Shell execution requests OS-level isolation by default. You can select it
explicitly with `tool_context: %{shell_isolation: :workspace}`. On macOS this uses
`sandbox-exec` to restrict filesystem access to the workspace and temporary
directories, and denies network access by default. Use
`shell_network: true` only when the task requires outbound networking.
`shell_isolation: :strict` fails when the platform cannot provide the sandbox;
`:none` preserves the legacy workspace-only behavior. If the sandbox backend is
unavailable, `:workspace` falls back to the legacy launcher; use `:strict` to
reject that fallback.
Command names are case-insensitive, so `/HELP` and `/help` are equivalent.
`/cancel` keeps the cancelled run associated with the session until its
terminal state is stored, preventing a new prompt from racing cancellation.
When no run is active, `/clear` also resets the conversation context used by
the next prompt.
On `/exit` or EOF, the TUI requests cancellation and waits briefly for the
active run to reach a terminal state before shutting down its event renderer.

Use `Littleagent.TUI.start(fullscreen: true)` for the full-screen terminal
mode. It provides an alternate screen buffer, editable input with arrow keys,
Backspace, Delete, and Enter, plus Up/Down and PageUp/PageDown transcript
scrolling. `Ctrl-L` redraws the screen. `Ctrl-C` cancels the active run or
exits an idle session. Set `ansi: false` when embedding the full-screen state
in a non-interactive test harness.

Applications can inject an auth module implementing `login/2`, or an arity-2
function, through `auth_adapter`. Adapter exceptions are reported as safe
errors to the TUI.

## Library API

Use a scripted adapter for deterministic local development:

```elixir
adapter = Littleagent.Model.Scripted.new([%{text: "Hello"}])
Littleagent.run("Say hello", adapter: adapter)
```

When no adapter is supplied, the run API uses the OpenAI-compatible adapter
and reads `OPENAI_API_KEY`, `LITTLEAGENT_OPENAI_ENDPOINT`, and
`LITTLEAGENT_MODEL` from the environment. Without a key it returns
`{:error, %{reason: :missing_api_key}}`.

Use the OpenAI-compatible adapter for a live provider:

```elixir
adapter = Littleagent.Model.OpenAI.new()
Littleagent.run("Explain this project", adapter: adapter, stream: true)
```

Custom struct adapters implement `Littleagent.Model.Adapter.complete/3`;
module adapters may implement `complete/3` or the legacy `complete/2` form.
The `stream/3` callback is optional: when `stream: true` is requested for an
adapter without that callback, the loop calls `complete/3` instead. This
fallback applies to both struct and module adapters.
Adapters receive a context map containing `run_id`, `workspace`, and the
configured `tool_context`.

Use `run_with_events/2` when the caller needs the complete ordered event
stream:

```elixir
{:ok, result, events} = Littleagent.run_with_events("Inspect the project", adapter: adapter)
```

Successful assistant text emits one or more `message_delta` events followed
by `message_completed` with the full text, then `run_completed`. Events have
increasing sequence numbers within each run. Scripted streaming preserves
adapter state across tool calls and emits text in grapheme-sized deltas.
If a model response contains both assistant text and tool calls, the text is
emitted and retained in the assistant transcript entry before tool execution.
The OpenAI-compatible adapter reads SSE response bodies incrementally and
forwards parsed deltas to the agent loop as soon as complete network chunks
arrive. Partial TCP frames are buffered until their SSE lines are complete.

Runtime failures return `{:error, reason, events}` from `run_with_events/2`.
Validation failures return `{:error, reason}` before a run starts. `run/2`
always returns a two-element success or error tuple. Set `timeout` (milliseconds)
to bound the synchronous wait; it covers the whole collection period and cancels
the active run when it expires. Events belonging to other runs remain in the
caller's mailbox.

`Littleagent.list_runs/0` returns all stored snapshots. Use
`Littleagent.list_runs(limit)` to cap the number of returned records.
Active runs support `Littleagent.subscribe/2` and `Littleagent.unsubscribe/2`
for managing event consumers. Subscriber processes are monitored and removed
automatically when they exit.
Run snapshots are kept in a supervised in-memory store with a default limit of
1,000 completed records. Set the `:max_stored_runs` application configuration
to change the retention limit.

Runs accept safety and resource limits:

```elixir
Littleagent.run("Use the echo tool", 
  adapter: adapter,
  tools: Littleagent.Tools.Registry.new([Littleagent.Tools.Echo]),
  allowed_tools: ["echo"],
  max_turns: 8,
  max_tool_calls: 16,
  max_output_chars: 100_000,
  max_elapsed_ms: 30_000,
  tool_timeout_ms: 5_000
)
```

When `max_elapsed_ms` is set, the run deadline remains active during approval
and tool execution. Cancellation or deadline expiry terminates the active
worker and prevents remaining tools from starting.
Tool workers run as supervised tasks without links to the agent process.
A worker crash becomes a tool error, allowing the model to handle the failed
call on its next turn. Timed out workers are terminated. Approval and
execution share one `tool_timeout_ms` budget per call. An approval timeout
denies the call; an execution timeout returns `:tool_timeout`. Tools in a
response execute sequentially, preserving transcript order.

Skill roots can be supplied to inject local `SKILL.md` instructions:

```elixir
Littleagent.TUI.start(skill_roots: ["./priv/skills"])
```

Built-in tools are opt-in and include `file_read`, `file_write`, `file_list`,
and `shell`. Register only the tools a run needs. File tools resolve real
paths and reject symlinks that escape the configured workspace; shell execution
should also use `allowed_tools` and an approval callback:

`file_list` traverses directories incrementally and stops when its
`max_entries` limit is reached.
`file_read` accepts regular UTF-8 files and reads at most `max_bytes + 1`
bytes to detect oversized content. The default limit is 256,000 bytes.

```elixir
tools = Littleagent.Tools.Registry.new([Littleagent.Tools.FileRead, Littleagent.Tools.Shell])

Littleagent.run("Inspect the project", 
  adapter: adapter,
  tools: tools,
  workspace: "/path/to/project",
  allowed_tools: ["file_read", "shell"],
  approve_tool: fn name, _args -> if name == "shell", do: :deny, else: :allow end
)
```

The shell tool is never registered automatically. Keep its approval callback
explicit, pass only required environment variables through the tool context,
and use `tool_timeout_ms` plus output limits for long-running commands.
Inherited environment variables are removed. Supply variables through
`tool_context: %{env: [{"NAME", "value"}]}` when using the run API.
The workspace sets the shell's working directory; shell commands can still
access paths outside that directory. Shell output is collected incrementally
and stops when the configured output limit is exceeded.

Invalid prompts and invalid limits are rejected before a supervised run is
started. Invalid workspace, tool context, and approval callback values are
also rejected before startup. An explicit `adapter: nil` is rejected as an
invalid adapter. Provider credentials are never included in emitted events.
