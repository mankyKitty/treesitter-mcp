#!/usr/bin/env bash
# Driver / smoke test for the treesitter-mcp stdio MCP server.
#
# treesitter-mcp has no GUI and no HTTP surface — it is a JSON-RPC 2.0 server
# that speaks MCP over stdin/stdout. The only way to "run" it is to spawn the
# binary, do the MCP handshake, and exchange framed JSON. This is that harness.
#
# The server reads newline-delimited JSON requests from stdin and writes one
# JSON response line per request to stdout (notifications get no reply). It
# processes a batch in order, so we feed the whole handshake + call in one pipe
# and pick the response out by its id with jq. No coprocess or fifo needed.
#
# Requires: bash, jq (both at /usr/bin here). Does NOT require node or python.
#
# Usage:
#   .claude/skills/run-treesitter-mcp/driver.sh                 # smoke the repo's own src/
#   .claude/skills/run-treesitter-mcp/driver.sh --path DIR      # smoke a different source tree
#   .claude/skills/run-treesitter-mcp/driver.sh --raw           # don't truncate payloads
#   .claude/skills/run-treesitter-mcp/driver.sh tools           # just list tool names
#   .claude/skills/run-treesitter-mcp/driver.sh call <tool> '<json-args>'
#        e.g. driver.sh call view_code '{"file_path":"src/main.rs","detail":"signatures"}'
#   .claude/skills/run-treesitter-mcp/driver.sh --bin PATH ...  # use a different binary
set -euo pipefail

PROTO="2025-11-25"   # matches ProtocolVersion::V2025_11_25 in src/main.rs
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"
BIN="$REPO_ROOT/target/release/treesitter-mcp"
SRC="$REPO_ROOT/src"
RAW=0

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"'"$PROTO"'","capabilities":{},"clientInfo":{"name":"treesitter-mcp-driver","version":"0"}}}'
NOTIF='{"jsonrpc":"2.0","method":"notifications/initialized"}'

# exchange <id> <request-json>  -> prints the response line whose id matches
exchange() {
  local id="$1" req="$2"
  printf '%s\n%s\n%s\n' "$INIT" "$NOTIF" "$req" \
    | "$BIN" 2>/dev/null \
    | jq -c --argjson id "$id" 'select(.id==$id)'
}

list_tools() {
  exchange 2 '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    | jq -r '.result.tools[].name'
}

# call_tool <tool> <json-args>  -> prints the content text (empty string on error)
call_tool() {
  local req
  req="$(jq -nc --arg n "$1" --argjson a "$2" \
    '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:$n,arguments:$a}}')"
  exchange 2 "$req" | jq -r '.result.content[0].text // empty'
}

# --- arg parsing ---------------------------------------------------------
MODE="smoke"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin)  BIN="$2"; shift 2;;
    --path) SRC="$2"; shift 2;;
    --raw)  RAW=1; shift;;
    tools)  MODE="tools"; shift;;
    call)   MODE="call"; CALL_TOOL="$2"; CALL_ARGS="${3:-}"; [[ -n "$CALL_ARGS" ]] || CALL_ARGS='{}'; shift $(( $# >= 3 ? 3 : $# ));;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[[ -x "$BIN" ]] || { echo "binary not found/executable: $BIN" >&2;
  echo "build it first: cargo build --release" >&2; exit 1; }

# --- handshake banner ----------------------------------------------------
# initialize alone is enough to read serverInfo; don't reuse exchange() here
# (it prepends its own INIT and would run initialize twice).
INFO="$(printf '%s\n' "$INIT" | "$BIN" 2>/dev/null | jq -c 'select(.id==1)')"
NAME="$(jq -r '.result.serverInfo.name' <<<"$INFO")"
VER="$(jq -r '.result.serverInfo.version' <<<"$INFO")"
PV="$(jq -r '.result.protocolVersion' <<<"$INFO")"
# banner to stderr so `tools`/`call` stdout stays pipeable
echo "connected: $NAME $VER (protocol $PV)" >&2

case "$MODE" in
  tools)
    list_tools
    ;;
  call)
    out="$(call_tool "$CALL_TOOL" "$CALL_ARGS")"
    [[ -n "$out" ]] || { echo "[FAIL] $CALL_TOOL returned no content" >&2; exit 1; }
    echo "$out"
    ;;
  smoke)
    n_tools="$(list_tools | wc -l | tr -d ' ')"
    echo "$n_tools tools available"
    # pick a focus file that exists
    FOCUS="$SRC/main.rs"
    [[ -f "$FOCUS" ]] || FOCUS="$(find "$SRC" -type f \( -name '*.rs' -o -name '*.py' -o -name '*.ts' -o -name '*.js' -o -name '*.go' \) | head -1)"
    echo "== smoke: src=$SRC focus=$FOCUS =="
    echo
    fail=0
    run() {
      local label="$1" tool="$2" args="$3" out
      out="$(call_tool "$tool" "$args")" || true
      local n=${#out}
      if [[ -n "$out" ]]; then
        echo "[ok ] $label ($n chars)"
      else
        echo "[FAIL] $label (empty)"; fail=1
      fi
      if [[ $RAW -eq 1 ]]; then
        echo "  $out"
      else
        echo "  ${out:0:300}"
      fi
      echo
    }
    run "code_map(minimal)"        code_map    "$(jq -nc --arg p "$SRC" '{path:$p,detail:"minimal",max_tokens:1500}')"
    run "type_map"                 type_map    "$(jq -nc --arg p "$SRC" '{path:$p,max_tokens:1500}')"
    run "view_code(signatures)"    view_code   "$(jq -nc --arg f "$FOCUS" '{file_path:$f,detail:"signatures"}')"
    run "find_usages(main)"        find_usages "$(jq -nc --arg p "$SRC" '{symbol:"main",path:$p,context_lines:1,max_context_lines:30}')"
    if [[ $fail -eq 0 ]]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; exit 1; fi
    ;;
esac
