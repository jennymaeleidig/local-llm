#!/bin/bash
set -euo pipefail
#
# The gate for the local gemma-4-26B-A4B / llama.cpp setup.
#
#   llm verify                              verify the boundaries
#   llm verify --measure                    verify, then measure (never asserted)
#   llm verify --help
#
# One seam. The checks are read-only against the server: GETs plus stateless
# completions. It never loads, unloads, downloads, or reconfigures, so it is
# safe to re-run at any time, including immediately after a pin bump. Every
# check either passes or prints "FAIL: <boundary>" with the reason and exits
# non-zero. A server that is down is reported as "server not running", not as a
# connection trace.
#
# Thinking is not asserted here. The checks that used to do it encoded gpt-oss's
# graded `reasoning_effort`, which this model's template does not read: gemma's
# thinking is a boolean (`enable_thinking`, off by default) that a request sets
# through chat_template_kwargs. Asserting either shape would assert a harness
# preference rather than a boundary, so the reasoning checks were removed rather
# than rewritten per model. Checking it by hand is in SETUP.md step 7.
#
# Two checks are not HTTP at all, and are labelled as such in their output.
# Provider visibility is asserted from the harness's own declaration rather than
# assumed, and the launch flags are read from serve.sh because the pinned build
# reports no GPU offload field anywhere in its HTTP surface (checked against the
# binary), so the one silent-slowdown failure has no remote observable.

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
eval "$(python3 "$DIR/pins.py")"

BASE="http://$SERVER_HOST:$SERVER_PORT"
MODEL_SPEC="$HOME/.pi/agent/models.json"
MEASURE=0

usage() {
  cat <<'EOF'
usage: llm verify [--measure | --help]

  (no argument)  verify every boundary; non-zero on the first failure
  --measure      verify, then print throughput and peak memory (never asserted)
  --help         this text

Read-only against the server. A down server is reported as "server not
running", not as a connection trace.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
  --measure) MEASURE=1 ;;
  --help | -h)
    usage
    exit 0
    ;;
  *)
    echo "unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
  esac
  shift
done

# /tmp explicitly, not TMPDIR: under an agent sandbox TMPDIR is often
# unwritable, and a gate that cannot create its scratch dir should say so here
# rather than fail confusingly later.
TMP="$(mktemp -d /tmp/local-llm-gate.XXXXXX)"
SAMPLER=""
cleanup() {
  if [ -n "$SAMPLER" ]; then kill "$SAMPLER" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n      %s\n' "$1" "$2" >&2
  exit 1
}

pass() {
  printf 'ok: %s\n' "$1"
}

post_chat() { # $1 body file, $2 out file, $3 timeout seconds -> writes HTTP code
  curl -s --max-time "$3" -o "$2" -w '%{http_code}' \
    -H 'Content-Type: application/json' --data-binary @"$1" "$BASE/v1/chat/completions" || true
}

echo "==> local-llm gate  ($LLAMA_CPP_RELEASE / $MODEL_ID @ $BASE)"

# --- 1. server reachable ----------------------------------------------------
CODE="$(curl -s --max-time 5 -o "$TMP/health" -w '%{http_code}' "$BASE/health" || true)"
if [ "$CODE" = "000" ]; then
  fail "server reachable" "server not running at $BASE — start it with: llm serve"
fi
case "$CODE" in
2*) ;;
*) fail "server reachable" "server answered HTTP $CODE at $BASE/health" ;;
esac
pass "server reachable"

# --- 2. router mode ---------------------------------------------------------
CODE="$(curl -s --max-time 10 -o "$TMP/models" -w '%{http_code}' "$BASE/models" || true)"
[ "$CODE" = "000" ] && fail "router mode" "server stopped responding at $BASE/models"
case "$CODE" in 2*) ;; *) fail "router mode" "GET $BASE/models returned HTTP $CODE" ;; esac
if ! python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
assert isinstance(data.get("data"), list)
for model in data["data"]:
    assert isinstance(model.get("id"), str)
    assert isinstance(model.get("status", {}).get("value"), str)
' "$TMP/models" 2>/dev/null; then
  fail "router mode" "GET $BASE/models is not a llama.cpp router catalog — single-model mode? Start llama-server without --model."
fi
pass "router mode"

# --- 3. exactly one model loaded, and it is the pinned one -------------------
LOADED="$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))["data"]
print("\n".join(m["id"] for m in data if m.get("status", {}).get("value") in ("loaded", "sleeping")))
' "$TMP/models")"
if [ -z "$LOADED" ]; then
  fail "model loaded and pinned" "no model loaded; in pi run /llama and select $MODEL_ID"
fi
LOADED_COUNT="$(printf '%s\n' "$LOADED" | grep -c . || true)"
if [ "$LOADED_COUNT" != "1" ]; then
  fail "model loaded and pinned" "expected exactly 1 loaded model, found $LOADED_COUNT: $(printf '%s ' $LOADED)"
fi
if [ "$LOADED" != "$MODEL_ID" ]; then
  fail "model loaded and pinned" "loaded '$LOADED', but pins.json names '$MODEL_ID'"
fi
pass "model loaded and pinned ($MODEL_ID)"

# --- 4a. the server allocated the window the pins declare --------------------
CTX_OUT="$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))["data"]
entry = next(m for m in data if m["id"] == sys.argv[2])
meta = entry.get("meta") or {}
ctx = meta.get("n_ctx") or meta.get("n_ctx_train")
if not ctx:
    print(f"the catalog entry for {sys.argv[2]} reports no n_ctx")
    sys.exit(1)
print(int(ctx))
' "$TMP/models" "$MODEL_ID")" || fail "context window parity" "${CTX_OUT:-no reason reported}"
SERVER_CTX="$CTX_OUT"
if [ "$SERVER_CTX" != "$CONTEXT_WINDOW" ]; then
  fail "context window parity" "server reports n_ctx=$SERVER_CTX, pins.json declares $CONTEXT_WINDOW; restart the server with serve.sh"
fi

# --- 4b. the harness agrees on the window -----------------------------------
if [ ! -f "$MODEL_SPEC" ]; then
  fail "harness window parity" "$MODEL_SPEC is missing — apply your dotfiles"
fi
REASON="$(python3 -c '
import json, sys
path, mid, server_ctx = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    cfg = json.load(open(path))
except Exception as exc:
    print(f"{path} is not valid JSON: {exc}")
    sys.exit(1)
override = ((cfg.get("providers") or {}).get("llama.cpp") or {}).get("modelOverrides") or {}
entry = override.get(mid)
if entry is None:
    print(f"{path} has no providers.llama.cpp.modelOverrides[{mid!r}] entry; the harness falls back to the built-in openai-completions defaults, whose window may not match the server. Apply your dotfiles.")
    sys.exit(1)
window = entry.get("contextWindow")
if window != server_ctx:
    print(f"the harness declares contextWindow={window!r} but the server reports n_ctx={server_ctx}")
    sys.exit(1)
' "$MODEL_SPEC" "$MODEL_ID" "$SERVER_CTX")" || fail "harness window parity" "${REASON:-no reason reported}"
pass "harness window parity ($SERVER_CTX)"

# --- 4c. the harness is pointed at this server -------------------------------
# Provider visibility is asserted rather than assumed: the model only appears in
# pi's list when the provider is enabled, and the provider is enabled by
# LLAMA_BASE_URL. The server was reached in checks 1-3 without credentials, so
# no key is needed to make the provider visible; the declaration is what has to
# exist, and it has to name this server.
BASE_DECLARED="${LLAMA_BASE_URL:-}"
if [ -z "$BASE_DECLARED" ] && [ -r "$HOME/.bash_exports" ]; then
  BASE_DECLARED="$(sed -nE 's/^export LLAMA_BASE_URL="?([^"]*)"?$/\1/p' "$HOME/.bash_exports" | tail -n 1)"
fi
if [ -z "$BASE_DECLARED" ]; then
  fail "harness provider connection" "LLAMA_BASE_URL is not set and is not declared in \$HOME/.bash_exports — the provider stays invisible however healthy the server is. Apply your dotfiles."
fi
if [ "$BASE_DECLARED" != "$BASE" ]; then
  fail "harness provider connection" "the harness is pointed at $BASE_DECLARED but the server is at $BASE (pins.json)"
fi
pass "harness provider connection ($BASE_DECLARED)"

# --- 5. the pinned launch flags are intact ----------------------------------
# Not HTTP: the pinned build's HTTP surface has no GPU-offload field at all, so
# residency cannot be asserted from here, and throughput would be a measurement.
# What can be asserted is the line that decides it, so a later edit that drops a
# flag is caught. serve.sh prints llama.cpp's own "offloaded N/N layers" line
# when you start it, which is where you read residency itself.
LAUNCH="$DIR/serve.sh"
if [ ! -r "$LAUNCH" ]; then
  fail "pinned launch flags" "$LAUNCH is not readable"
fi
# Only the argument tail, so a flag named in a comment cannot satisfy the check.
LAUNCH_ARGS="$(sed -n '/^exec /,$p' "$LAUNCH")"
if [ -z "$LAUNCH_ARGS" ]; then
  fail "pinned launch flags" "$LAUNCH has no 'exec' line to read the flags from"
fi
REQUIRED_FLAGS=(
  '--models-dir "$MODELS_DIR"'
  '--models-max 1'
  '--no-models-autoload'
  '--jinja'
  '-ngl 99'
  '-c "$CONTEXT_WINDOW"'
  '--parallel 1'
  '--spec-type draft-mtp'
  '--spec-draft-model "$DRAFT_PATH"'
  '--spec-draft-n-max 1'
  '--host "$SERVER_HOST"'
  '--port "$SERVER_PORT"'
)
for flag in "${REQUIRED_FLAGS[@]}"; do
  if ! grep -qF -- "$flag" <<<"$LAUNCH_ARGS"; then
    fail "pinned launch flags" "serve.sh no longer passes $flag — window, slots, speculative decoding, tool calling or GPU offload would change silently"
  fi
done
pass "pinned launch flags intact (offload -ngl 99, window, slots, jinja, MTP drafter)"

# --- 6. a tool spec produces a structured tool call -------------------------
python3 - "$MODEL_ID" >"$TMP/tool_req.json" <<'PY'
import json, sys
print(json.dumps({
    "model": sys.argv[1],
    "messages": [{
        "role": "user",
        "content": "Read the file /etc/hosts using the read tool. Reply with the tool call only.",
    }],
    "tools": [{
        "type": "function",
        "function": {
            "name": "read",
            "description": "Read a text file from disk.",
            "parameters": {
                "type": "object",
                "properties": {"path": {"type": "string", "description": "Path of the file to read."}},
                "required": ["path"],
            },
        },
    }],
    "tool_choice": "auto",
    "max_tokens": 512,
    "temperature": 0,
    "stream": False,
}))
PY
CODE="$(post_chat "$TMP/tool_req.json" "$TMP/tool_resp.json" 120)"
if [ "$CODE" = "000" ]; then
  fail "tool call structured" "server not running at $BASE — start it with: llm serve"
fi
case "$CODE" in
2*) ;;
*) fail "tool call structured" "chat completion returned HTTP $CODE: $(head -c 300 "$TMP/tool_resp.json")" ;;
esac
REASON="$(
  python3 - "$TMP/tool_resp.json" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    message = data["choices"][0]["message"]
except Exception as exc:
    print(f"response did not contain choices[0].message: {exc}")
    sys.exit(1)
calls = message.get("tool_calls") or []
content = (message.get("content") or "").strip()
if not calls:
    if content:
        print("the model answered in prose instead of returning a structured tool_calls entry; "
              "the template's tool-call parser did not run (is --jinja active?). "
              f"Content began: {content[:160]!r}")
    else:
        print("response had neither tool_calls nor content")
    sys.exit(1)
function = calls[0].get("function") or {}
if function.get("name") != "read":
    print(f"expected a tool_calls entry named 'read', got {function.get('name')!r}")
    sys.exit(1)
arguments = function.get("arguments")
if isinstance(arguments, str):
    try:
        arguments = json.loads(arguments)
    except Exception as exc:
        print(f"tool_calls arguments are not JSON: {exc}; raw={arguments[:160]!r}")
        sys.exit(1)
if not isinstance(arguments, dict) or "path" not in arguments:
    print(f"tool_calls arguments carry no 'path' key: {arguments!r}")
    sys.exit(1)
PY
)" || fail "tool call structured" "${REASON:-no reason reported}"
pass "tool call structured (read)"

echo "PASS: all boundaries green"

if [ "$MEASURE" != "1" ]; then
  exit 0
fi

# --- measurement mode (never asserted) --------------------------------------
echo
echo "==> measurement (not asserted; wall-clock, includes prefill)"
echo "    short  run is decode-bound; long run is prefill-bound (that is the"
echo "           number where a lost GPU offload shows up first)"

WIRED="$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo unavailable)"
echo "    iogpu.wired_limit_mb: $WIRED MiB"

PID="$(pgrep -f 'llama-server' 2>/dev/null | head -n 1 || true)"
if [ -n "$PID" ]; then
  (while :; do
    ps -o rss= -p "$PID" 2>/dev/null || break
    sleep 0.5
  done) >"$TMP/rss.txt" 2>/dev/null &
  SAMPLER=$!
else
  echo "    peak memory: unavailable (llama-server pid not visible from here)"
fi

run_completion() { # $1 body file, $2 response file, $3 wall file
  local start end code
  start="$(python3 -c 'import time; print(time.time())')"
  code="$(post_chat "$1" "$2" 900)"
  end="$(python3 -c 'import time; print(time.time())')"
  case "$code" in
  2*) ;;
  *) fail "measurement request" "chat completion returned HTTP $code" ;;
  esac
  python3 -c 'import sys; print(float(sys.argv[2]) - float(sys.argv[1]))' "$start" "$end" >"$3"
}

report_run() { # $1 label, $2 body, $3 response, $4 wall file, $5 phase to rate
  run_completion "$2" "$3" "$4"
  python3 - "$3" "$4" "$1" "$5" <<'PY'
import json, sys

# Wall time here covers both phases, so a single rate is only honest for the
# phase that dominates the run. The short run is decode-bound; the long run is
# prefill-bound (its completion is a handful of tokens after a huge prompt).
# Labelling which one each run measures is the point: prefill is where a lost
# GPU offload shows up first, and it is invisible in a decode-only number.
usage = (json.load(open(sys.argv[1])).get("usage") or {})
wall = float(open(sys.argv[2]).read())
prompt = usage.get("prompt_tokens") or 0
completion = usage.get("completion_tokens") or 0
reasoning = (usage.get("completion_tokens_details") or {}).get("reasoning_tokens")
phase = sys.argv[4]
tokens = prompt if phase == "prefill" else (completion + (reasoning or 0))
rate = f"{tokens / wall:.1f} tok/s {phase}" if wall > 0 else f"no {phase} time"
print(f"    {sys.argv[3]:<13} prompt={prompt} completion={completion} reasoning={reasoning} wall={wall:.1f}s {rate}")
PY
}

python3 - "$MODEL_ID" >"$TMP/short_req.json" <<'PY'
import json, sys
print(json.dumps({
    "model": sys.argv[1],
    "messages": [{"role": "user", "content": "Write a short paragraph about the ocean."}],
    "max_tokens": 128,
    "temperature": 0,
    "stream": False,
}))
PY

python3 -c 'import sys; sys.stdout.write("The quick brown fox jumps over the lazy dog. " * int(sys.argv[1]))' 2200 >"$TMP/long_prompt.txt"
python3 - "$MODEL_ID" "$TMP/long_prompt.txt" >"$TMP/long_req.json" <<'PY'
import json, sys
print(json.dumps({
    "model": sys.argv[1],
    "messages": [{"role": "user", "content": open(sys.argv[2]).read() + "\n\nReply with exactly: done."}],
    "max_tokens": 64,
    "temperature": 0,
    "stream": False,
}))
PY

report_run "short" "$TMP/short_req.json" "$TMP/short_resp.json" "$TMP/short.wall" decode
report_run "long" "$TMP/long_req.json" "$TMP/long_resp.json" "$TMP/long.wall" prefill

if [ -n "$SAMPLER" ]; then
  kill "$SAMPLER" 2>/dev/null || true
  SAMPLER=""
  PEAK="$(sort -n "$TMP/rss.txt" 2>/dev/null | tail -n 1 || true)"
  if [ -n "$PEAK" ]; then
    python3 -c 'import sys; print(f"    peak llama-server resident: {int(sys.argv[1]) / 1048576:.2f} GiB")' "$PEAK"
  fi
fi
echo "    (numbers are a fact about this machine today, not a contract)"
