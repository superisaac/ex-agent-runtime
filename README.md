# Littleagent

Littleagent is a small Elixir coding-agent core with a supervised agent loop,
structured run events, local Markdown skills, tool execution, and a basic
line-oriented terminal UI.

## Development

```sh
mix deps.get
mix test
```

The default adapter is OpenAI-compatible and reads credentials from the
environment. A scripted adapter can be supplied for deterministic local
development:

```elixir
adapter = Littleagent.Model.Scripted.new([%{text: "Hello"}])
Littleagent.run("Say hello", adapter: adapter)
```

Start the basic interactive UI with `Littleagent.TUI.start/0`. It accepts
prompts and `/help`, `/login`, `/skills`, `/reload-skills`, `/status`, `/history`, `/runs`,
`/clear-runs`, `/cancel`, `/clear`, `/exit`, and `/quit`. Completed runs remain in the
session context for subsequent prompts.
The TUI forwards adapter options supplied to `start/1`:

```elixir
Littleagent.TUI.start(adapter: Littleagent.Model.Scripted.new([%{text: "Hello"}]))
```

For a full-screen terminal session, use `Littleagent.TUI.start(fullscreen: true)`.
It uses an alternate screen buffer, editable input, cursor movement, transcript
scrolling, and live run status. `Ctrl-C` cancels an active run or exits an idle
session; `Ctrl-L` redraws the screen.

If no API key is configured, the default adapter returns a clear
`missing_api_key` error. Set `OPENAI_API_KEY` before starting the UI, or pass
a scripted adapter for offline development.

An OpenAI-compatible adapter is available when `OPENAI_API_KEY` is set:

```elixir
adapter = Littleagent.Model.OpenAI.new(model: "gpt-4o-mini")
Littleagent.TUI.start(adapter: adapter)
```

For compatible gateways, set `LITTLEAGENT_OPENAI_ENDPOINT` and optionally
`LITTLEAGENT_MODEL`.

Run snapshots are retained in memory. Configure the maximum retained count
before starting the application:

```elixir
config :littleagent, :max_stored_runs, 2_000
```

Shell execution requests OS-level isolation by default. You can pass
`tool_context: %{shell_isolation: :workspace}` explicitly. On macOS this uses the
available sandbox backend, denies network access by default, and allows writes
only within the workspace and temporary directories. Use `:strict` to fail
when no sandbox backend is available, or `:none` for legacy behavior. The
default `:workspace` mode falls back to legacy execution when the backend is
unavailable; use `:strict` to reject that fallback.

The default `/login openai` command checks `OPENAI_API_KEY` without printing
the secret. Applications can inject a different auth adapter into
`Littleagent.TUI.start/1` when credentials are stored elsewhere.

The same UI can be launched directly from the shell:

```sh
mix littleagent
```

The command also accepts `--endpoint URL`, `--model NAME`, repeated
`--skill-root PATH`, `--no-ansi`, and `--fullscreen`.

The command selects the OpenAI-compatible adapter and uses the configured
environment variables. On a fresh checkout, run `mix compile` first to make
the custom task available.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `littleagent` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:littleagent, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/littleagent>.
