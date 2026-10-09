# EAR (Elixir Agent Runtime) Usage

## Partial Results and Model Failures

Live model chunks reach subscribers while the model request is still running.
On cancellation, provider failure, worker crash, deadline expiration, or an
output-limit failure, accepted chunks are retained in the stored transcript as
an assistant message with `metadata.partial: true`. A `message_completed` event
with `partial: true` closes that message before the single terminal event.

The terminal payload includes `partial_result` with `text`, `message_id`, and
`tool_call_deltas`. Incomplete tool fragments are retained as metadata and never
executed. An oversized incoming batch is rejected without emitting it; earlier
accepted chunks are still preserved. Normal successful completion does not add
partial metadata or duplicate the assistant message.

Malformed response bodies, live chunks, and tool-call structures produce
`run_failed` with reason `:malformed_model_response`. A valid explicit empty
text response remains a successful completion. Invalid adapter return tuples
use `:malformed_adapter_response`.

`run_with_events/2` returns terminal payloads together with the collected events.
Its own caller timeout returns immediately with `:timeout` and requests
cancellation; the eventual cancellation event and stored snapshot contain any
partial result. Use `subscribe/2` or the original subscriber to observe that
terminal event, and `get_run/1` to retrieve the snapshot after termination.

## Interactive TUI

Start the terminal UI with:

```sh
mix compile
mix ear.tui
```

### User Configuration

Both TUI modes check `~/.ear/agent/models.yaml` and
`~/.ear/agent/settings.yaml` before starting terminal input. Missing directories
and files are created; existing files are never overwritten. YAML comments and
normal lists are supported. Invalid configuration stops startup with a file name
and safe error reason, without printing file contents.

`models.yaml` groups models by provider, using a Pi-style provider/model registry:

```yaml
providers:
  openai:
    baseUrl: https://api.openai.com/v1
    api: openai-completions
    apiEnvKey: OPENAI_API_KEY
    models:
      - id: gpt-4o-mini
        name: GPT-4o Mini
```

Multiple providers and model IDs are supported. Currently the supported protocol
is `openai-completions` (OpenAI-compatible chat completions). `baseUrl` may also
be a complete `/chat/completions` endpoint. Credentials are read only from the
environment variable named by `apiEnvKey`; inline `apiKey`/`api_key` fields are
rejected. A missing or blank credential produces `missing_api_key` when a run
starts, allowing the TUI to open without credentials.

`settings.yaml` selects the default provider/model and terminal preferences:

```yaml
defaultProvider: openai
defaultModel: gpt-4o-mini
stream: true
ansi: true
fullscreen: false
skillRoots: []
# Optional non-negative run limits:
# maxTurns: 16
# maxToolCalls: 64
# maxOutputChars: 100000
# maxElapsedMs: 60000
# toolTimeoutMs: 30000
```

On first creation, the following environment variables supply defaults. Credential
values are never written to either file.

| Configuration | Environment variables, in precedence order |
| --- | --- |
| Provider name | `EAR_PROVIDER`, otherwise `openai` |
| Model ID | `EAR_MODEL`, `OPENAI_MODEL`, otherwise `gpt-4o-mini` |
| Base URL or endpoint | `EAR_OPENAI_ENDPOINT`, `OPENAI_BASE_URL`, otherwise the OpenAI `/v1` base URL |
| Credential variable name | `EAR_API_ENV_KEY`, otherwise `OPENAI_API_KEY` |
| Terminal preferences | `EAR_STREAM`, `EAR_ANSI`, `EAR_FULLSCREEN` (`true`/`false` or `1`/`0`) |
| Optional run limits | `EAR_MAX_TURNS`, `EAR_MAX_TOOL_CALLS`, `EAR_MAX_OUTPUT_CHARS`, `EAR_MAX_ELAPSED_MS`, `EAR_TOOL_TIMEOUT_MS` |

Blank values use defaults, and invalid optional preference/limit values are
ignored. If only settings are missing, their default provider/model is chosen
from the existing model registry. Explicit TUI options and CLI `--model` /
`--endpoint` override stored configuration; environment model preferences seed
missing files and do not override an existing configuration. An explicit model
override may name a model not yet listed in the registry.

`/login` without an argument validates the selected provider's `apiEnvKey` and
refreshes its credential while keeping the configured model and endpoint.
Applications/tests can use `config_dir: path` for a separate configuration
directory, or explicitly disable file initialization with `config: false`.
The non-TUI run API continues to accept injected adapters and environment defaults.

The Mix task accepts `--endpoint URL`, `--model NAME`, repeated
`--workspace DIR`, `--skill-root PATH`, `--no-ansi`, and
`--verbose` in addition to `--help`. The workspace defaults to the current
directory and is passed to file tools and adapter context.

The default TUI renderer is quiet: assistant text and terminal errors remain
visible, while run, skill, and tool lifecycle events are suppressed. Pass
`verbose: true` to `Ear.TUI.start/1`, or use `mix ear.tui --verbose`, to display
those diagnostics. Event subscribers still receive every structured event in
both modes. After a terminal event, quiet mode redraws the `ear>` prompt. A
blank line entered at the prompt is ignored rather than submitted as a model
request.

The line-oriented TUI uses a raw-terminal readline editor for its default input,
providing line editing and history (including `Ctrl-A`/Home, `Ctrl-E`/End,
`Ctrl-K`, `Ctrl-U`, arrows, and deletion). Erlang terminal mode and
`line_history` are enabled when standard input is a terminal, and the original
`stty`/I/O options are restored when the session exits. An injected `input`
function bypasses terminal configuration and is useful for embedding and tests.

Set `OPENAI_API_KEY` before starting to use the OpenAI-compatible adapter. The
following environment variables are supported:

- `OPENAI_API_KEY`: provider credential;
- `EAR_OPENAI_ENDPOINT`: compatible chat-completions endpoint;
- `EAR_MODEL`: model name.

The TUI supports `/help`, `/login`, `/skills`, `/reload-skills`, `/status`, `/history`, `/runs`,
`/clear-runs`, `/cancel`, `/clear`, `/exit`, and `/quit`. `/runs` accepts an
optional non-negative limit such as `/runs 10`; `/history` accepts the same
limit to show only the most recent messages. `/skills` accepts an optional
skill name to filter the list. A prompt is rejected while
another run is active. Assistant text is rendered incrementally from
`message_delta` events and terminated with a single newline when the run
completes. `/login openai` validates `OPENAI_API_KEY` and configures the
OpenAI adapter for subsequent prompts. Use `/login` for the configured default
provider. Completed runs remain the session
context, so the next prompt includes earlier user, assistant, and tool
messages. Set `ansi: false` in `Ear.TUI.start/1` when output is being
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

On Linux, isolation uses `bubblewrap` (`bwrap`), which must be installed with
unprivileged user namespaces enabled. Runtime files are mounted read-only;
only the workspace is writable on the host. Temporary files use a private
`/tmp`, and process and network namespaces are isolated. `shell_network: true`
shares the host network namespace and mounts DNS configuration. A sandbox
startup probe detects hosts that prohibit namespace creation. Linux isolation
integration tests run only when that probe succeeds.

Command names are case-insensitive, so `/HELP` and `/help` are equivalent.
`/cancel` keeps the cancelled run associated with the session until its
terminal state is stored, preventing a new prompt from racing cancellation.
When no run is active, `/clear` also resets the conversation context used by
the next prompt.
On `/exit` or EOF, the TUI requests cancellation and waits briefly for the
active run to reach a terminal state before shutting down its event renderer.

Use `Ear.TUI.start(fullscreen: true)` for the full-screen terminal. This mode
uses the TermUI Elm runtime and renders complete `TermUI.Frame` values.
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
adapter = Ear.Model.Scripted.new([%{text: "Hello"}])
Ear.run("Say hello", adapter: adapter)
```

When no adapter is supplied, the run API uses the OpenAI-compatible adapter
and reads `OPENAI_API_KEY`, `EAR_OPENAI_ENDPOINT`, and
`EAR_MODEL` from the environment. Without a key it returns
`{:error, %{reason: :missing_api_key}}`.

Use the OpenAI-compatible adapter for a live provider:

```elixir
adapter = Ear.Model.OpenAI.new()
Ear.run("Explain this project", adapter: adapter, stream: true)
```

Custom struct adapters implement `Ear.Model.Adapter.complete/3`;
module adapters may implement `complete/3` or the legacy `complete/2` form.
The `stream/3` callback is optional: when `stream: true` is requested for an
adapter without that callback, the loop calls `complete/3` instead. This
fallback applies to both struct and module adapters.
Adapters receive a context map containing `run_id`, `workspace`, and the
configured `tool_context`.

Use `run_with_events/2` when the caller needs the complete ordered event
stream:

```elixir
{:ok, result, events} = Ear.run_with_events("Inspect the project", adapter: adapter)
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
Live streaming uses the OpenAI adapter's `timeout` as an inactivity limit,
reset whenever HTTP stream data arrives, instead of a total request deadline.
The stream finishes at `[DONE]`, even if the provider keeps the connection open.
Timeout and cancellation close the pending HTTP request. The web UI defaults
to 120,000 milliseconds; pass `mix ear.web --model-timeout 300000` to increase
this to five minutes. Complete and buffered model requests use a total HTTP
timeout. This model timeout is separate from the synchronous caller timeout
described below.

`mix ear.web` suppresses debug logs by default. Pass `--verbose` to show them.

Runtime failures return `{:error, reason, events}` from `run_with_events/2`.
Validation failures return `{:error, reason}` before a run starts. `run/2`
always returns a two-element success or error tuple. Set `timeout` (milliseconds)
to bound the synchronous wait; it covers the whole collection period and cancels
the active run when it expires. Events belonging to other runs remain in the
caller's mailbox.

`Ear.list_runs/0` returns all stored snapshots. Use
`Ear.list_runs(limit)` to cap the number of returned records.
Active runs support `Ear.subscribe/2` and `Ear.unsubscribe/2`
for managing event consumers. Subscriber processes are monitored and removed
automatically when they exit.
Run snapshots are kept in a supervised in-memory store with a default limit of
1,000 completed records. Set the `:max_stored_runs` application configuration
to change the retention limit.

Runs accept safety and resource limits:

```elixir
Ear.run("Use the echo tool",
  adapter: adapter,
  tools: Ear.Tools.Registry.new([Ear.Tools.Echo]),
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
Ear.TUI.start(skill_roots: ["./priv/skills"])
```

Built-in tools are opt-in for library calls and include `file_read`, `file_write`,
`file_list`, and `shell`. The TUI automatically registers the read-only
`file_list` and `file_read` tools so prompts such as "analyze this project" can
inspect the current workspace. The TUI does not register write or shell tools.
For library calls, register only the tools a run needs. File tools resolve real
paths and reject symlinks that escape the configured workspace; shell execution
should also use `allowed_tools` and an approval callback:

`file_list` traverses directories incrementally and stops when its
`max_entries` limit is reached.
`file_read` accepts regular UTF-8 files and reads at most `max_bytes + 1`
bytes to detect oversized content. The default limit is 256,000 bytes.

```elixir
tools = Ear.Tools.Registry.new([Ear.Tools.FileRead, Ear.Tools.Shell])

Ear.run("Inspect the project",
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
