# EAR — Elixir Agent Runtime

EAR (Elixir Agent Runtime) is a small Elixir coding-agent core with a supervised agent loop,
structured run events, local Markdown skills, tool execution, and a basic
line-oriented terminal UI.

## Development

```sh
mix deps.get
mix test
```

## Web Interface

Start the Phoenix web interface with:

```sh
mix ear.web --workspace /path/to/project
```

Open <http://localhost:9000> to send prompts, view streaming assistant output,
inspect run status and tool events, cancel a run, or start a new conversation.
The server listens on `127.0.0.1` and shares one conversation across browser tabs.
Follow-up prompts include the previous conversation. Runs and conversation state
are held in memory for the lifetime of the server.

The task accepts `--endpoint URL`, `--model NAME`, repeated `--skill-root PATH`,
`--port PORT` (default: `9000`), and `--verbose`. The workspace defaults to the current
directory. Debug logs are hidden by default; pass `--verbose` to show them. It uses the same `~/.ear/agent` model configuration and read-only
`file_list` / `file_read` tools as the terminal UI. Set the configured API key
environment variable before starting. Run `mix ear.web --help` for usage.

Model requests in the web UI default to a 120-second timeout. Set
`--model-timeout 300000` to allow five minutes. For live streaming this is an
inactivity timeout, reset whenever HTTP stream data arrives, so an active long
reply can continue beyond it. A stream ends when the provider sends `[DONE]`.
For non-streaming requests the timeout limits the entire HTTP request.

The default adapter is OpenAI-compatible and reads credentials from the
environment. A scripted adapter can be supplied for deterministic local
development:

```elixir
adapter = Ear.Model.Scripted.new([%{text: "Hello"}])
Ear.run("Say hello", adapter: adapter)
```

Start the basic interactive UI with `Ear.TUI.start/0`. It accepts
prompts and `/help`, `/login`, `/skills`, `/reload-skills`, `/status`, `/history`, `/runs`,
`/clear-runs`, `/cancel`, `/clear`, `/exit`, and `/quit`. Completed runs remain in the
session context for subsequent prompts.
On startup, both TUI modes create missing `~/.ear/agent/models.yaml` and
`~/.ear/agent/settings.yaml` from environment defaults, then read the selected
provider/model and terminal preferences. Existing files are preserved. Models
use a Pi-style `providers` registry with `baseUrl`, `api`, `apiEnvKey`, and
`models`; credentials are resolved from the named environment variable and are
never written to configuration. See [User Configuration](docs/usage.md#user-configuration)
for the YAML format and precedence rules.
The default renderer is quiet and shows assistant output without lifecycle
diagnostics. Pass `verbose: true` to `Ear.TUI.start/1`, or use `mix ear.tui
--verbose`, to display run, skill, and tool events.
Use `mix ear.tui --workspace /path/to/project` to choose the workspace inspected by
the TUI; without it, the current directory is used.
The line-oriented TUI enables Erlang terminal line history for the default
terminal input, providing readline-style editing and history. Injected `input`
functions used by applications and tests are left unchanged.
The TUI forwards adapter options supplied to `start/1`:

```elixir
Ear.TUI.start(adapter: Ear.Model.Scripted.new([%{text: "Hello"}]))
```

TUI runs automatically expose the read-only `file_list` and `file_read` tools,
using the current working directory as the workspace. This lets the model
inspect a project when asked to analyze it. `file_write` and `shell` remain
explicit opt-in tools for library callers.

For a full-screen terminal session, use `Ear.TUI.start(fullscreen: true)`. The
full-screen mode is implemented with the [TermUI](https://github.com/agentjido/term_ui)
Elm runtime; injected `key_input` options continue to use the deterministic
legacy backend for tests and embedding.
It uses an alternate screen buffer, editable input, cursor movement, transcript
scrolling, and live run status. `Ctrl-C` cancels an active run or exits an idle
session; `Ctrl-L` redraws the screen.

If no API key is configured, the default adapter returns a clear
`missing_api_key` error. Set `OPENAI_API_KEY` before starting the UI, or pass
a scripted adapter for offline development.

An OpenAI-compatible adapter is available when `OPENAI_API_KEY` is set:

```elixir
adapter = Ear.Model.OpenAI.new(model: "gpt-4o-mini")
Ear.TUI.start(adapter: adapter)
```

For compatible gateways, set `EAR_OPENAI_ENDPOINT` and optionally
`EAR_MODEL`.

Run snapshots are retained in memory. Configure the maximum retained count
before starting the application:

```elixir
config :ear, :max_stored_runs, 2_000
```

Shell execution requests OS-level isolation by default. You can pass
`tool_context: %{shell_isolation: :workspace}` explicitly. On macOS this uses the
available sandbox backend, denies network access by default, and allows writes
only within the workspace and temporary directories. Use `:strict` to fail
when no sandbox backend is available, or `:none` for legacy behavior. The
default `:workspace` mode falls back to legacy execution when the backend is
unavailable; use `:strict` to reject that fallback.

On Linux, install `bubblewrap` (`bwrap`) and enable unprivileged user namespaces
to use isolation. The Linux backend mounts runtime files read-only, allows
workspace writes, provides a private temporary directory, and isolates process
and network namespaces. Set `shell_network: true` in the tool context to allow
network access. Backend availability is checked by launching a sandbox, since
some container hosts disable namespace creation even when `bwrap` is installed.

The default `/login` command checks the selected provider's `apiEnvKey` without
printing the secret and preserves its configured endpoint and model.
Applications can inject a different auth adapter into
`Ear.TUI.start/1` when credentials are stored elsewhere.

The same UI can be launched directly from the shell:

```sh
mix ear.tui
```

The command also accepts `--endpoint URL`, `--model NAME`, repeated
`--skill-root PATH`, `--no-ansi`, and `--verbose`.

The command selects the OpenAI-compatible adapter and uses the configured
environment variables. On a fresh checkout, run `mix compile` first to make
the custom task available.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `ear` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ear, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/ear>.
