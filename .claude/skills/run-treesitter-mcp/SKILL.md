---
name: run-treesitter-mcp
description: Build, launch, and drive the treesitter-mcp server. Use when asked to run, start, build, smoke-test, or exercise the tree-sitter MCP server, or to confirm a change works by calling its MCP tools (code_map, view_code, find_usages, etc.) over stdio.
---

# Run treesitter-mcp

`treesitter-mcp` is a Rust **MCP server with no GUI and no HTTP port**. It
speaks JSON-RPC 2.0 over **stdin/stdout** only. You cannot "open" it — you
launch the binary, do the MCP handshake (`initialize` → `notifications/initialized`
→ `tools/list`), then send `tools/call` requests and read the compact JSON each
tool returns.

The driver that does all of this is **`.claude/skills/run-treesitter-mcp/driver.sh`**
(pure bash + `jq` — no node/python needed; both are unreliable in this nix shell).
Drive the server through it.

All paths below are relative to the repo root (the unit dir).

## Prerequisites

- A Rust toolchain (`cargo`, `rustc`). On this machine it comes from the nix
  flake (`.envrc` + `flake.nix`) — `cargo 1.93`. `direnv allow` or the nix dev
  shell puts it on `PATH`.
- `jq` and `bash` (both at `/usr/bin`). The driver needs these.
- No OS packages beyond the toolchain — it builds and runs headless on Linux
  and macOS alike.

> Note: `node`/`npx` are absent here, and `/usr/bin/python3` is a broken `xcrun`
> shim inside the nix shell (`error: tool 'python3' not found`). The driver is
> bash-only on purpose. Don't reach for a python/node MCP client.

## Build

```bash
cargo build --release
```

Produces `target/release/treesitter-mcp`. (A debug binary at
`target/debug/treesitter-mcp` also works — pass `--bin` to the driver.)

## Run (agent path) — use this

Smoke the server against the repo's own `src/` (handshake + 4 representative
tool calls, asserts each returns content, exits non-zero on any failure):

```bash
.claude/skills/run-treesitter-mcp/driver.sh
```

Expected tail: `RESULT: PASS` and exit code 0. It prints the connected
server banner, the tool count (17), and a truncated payload per call.

List the tools the running server exposes:

```bash
.claude/skills/run-treesitter-mcp/driver.sh tools
```

Call any single tool and print its full response (this is how you confirm a
code change actually altered a tool's output):

```bash
.claude/skills/run-treesitter-mcp/driver.sh call view_code '{"file_path":"src/main.rs","detail":"signatures"}'
.claude/skills/run-treesitter-mcp/driver.sh call symbol_at_line '{"file_path":"src/main.rs","line":21}'
.claude/skills/run-treesitter-mcp/driver.sh call code_map '{"path":"src","detail":"minimal","max_tokens":1500}'
```

Other flags: `--path DIR` (smoke a different source tree), `--raw` (don't
truncate payloads), `--bin PATH` (use a different binary). See the header of
`driver.sh` for the full list.

## Run (human path)

`target/release/treesitter-mcp` with no args just blocks reading stdin — there
is no window and nothing to see. A human only runs it indirectly by registering
it with an MCP client:

```bash
claude mcp add --scope project treesitter-mcp -- "$PWD/target/release/treesitter-mcp"
```

For iterating on the server itself, the driver is faster than a full client.

## Raw protocol (no driver)

If you need to see the exact wire bytes, the server processes a batched stdin
stream in order and emits one response line per request (notifications get no
reply):

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"d","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | target/release/treesitter-mcp 2>/dev/null
```

## Test

```bash
cargo test --release
```

Note: as of this writing one test, `test_code_map_respects_gitignore`, fails
on a clean tree (asserts a `visible.rs` fixture is present) — a pre-existing
failure unrelated to launching the server. The rest pass. The driver smoke
test above is the reliable "does the server actually work" check.

## Gotchas

- **Protocol version is pinned.** `initialize` must send
  `"protocolVersion":"2025-11-25"` (matches `ProtocolVersion::V2025_11_25` in
  `src/main.rs`). The driver hardcodes it as `PROTO`. A mismatched version can
  make the handshake fail silently.
- **Notifications get no response line.** `notifications/initialized` produces
  zero output. So `initialize` + `initialized` + one `tools/call` yields exactly
  **two** response lines (init reply + call reply), not three. The driver picks
  responses by `id` with `jq` rather than counting lines.
- **The server reads stdin to EOF and processes in order**, so you can pipe the
  whole handshake + call as one batch — no coprocess or fifo needed. The driver
  re-runs the handshake on every `call`/`smoke` invocation; that's cheap because
  startup is instant.
- **Tool output is deliberately compact**, not pretty JSON: pipe-delimited rows
  under short keys (`h`, `f`, `s`, `u`, `types`, …) and `\n`-escaped multi-line
  cells. `"@":{"t":true}` means the result was **truncated** to fit `max_tokens`
  — raise `max_tokens` if you need the full map. This is the product working as
  designed, not a bug.
- **`python3`/`node` are traps here** — see the Prerequisites note. Use the bash
  driver.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `binary not found/executable` from the driver | `cargo build --release` first, or point `--bin` at an existing binary. |
| `cargo: command not found` | The nix toolchain isn't on `PATH`. Run inside the nix dev shell / `direnv allow` (the repo has `.envrc` + `flake.nix`). |
| `error: tool 'python3' not found` | That's macOS's `xcrun` shim, not the driver — ignore it. The driver doesn't use python. |
| Driver prints a banner but a `call` shows `[FAIL] ... no content` | The tool returned an error (e.g. bad/relative path it can't resolve, or a file in an unsupported language). Re-run that tool via `call` and inspect; most tools want a path that exists relative to your CWD. |
| `jq: invalid JSON text passed to --argjson` | Your `call` args string isn't valid JSON. Quote it in single quotes and check the braces. |
