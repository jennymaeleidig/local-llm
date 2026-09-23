#!/bin/bash
set -euo pipefail
#
# Offline tests for the llm CLI. No llama-server, no model weights.
#
#   bash tests/run.sh
#
# Covers acceptance that does not need the pinned runtime:
#   - llm url prints the pinned host:port from a bare checkout
#   - llm serve preflight failures: missing binary, wrong GGUF count,
#     wrong model file, byte mismatch, missing/short draft
#   - llm serve success path execs the binary with the pinned flags
#   - llm verify reports "server not running" against a dead port
#   - llm state probe answers JSON even with the server down
#   - dispatcher: unknown verb and bare invocation exit non-zero

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LLM="$ROOT/bin/llm"

FIXTURES="$(mktemp -d /tmp/llm-serve-tests.XXXXXX)"
trap 'rm -rf "$FIXTURES"' EXIT
FAKE_HOME="$FIXTURES/home"
mkdir -p "$FAKE_HOME"

passes=0
fails=0

pass() { printf 'ok: %s\n' "$1"; passes=$((passes + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

expect_fail() { # $1 label, $2 pattern, then the command
  local label="$1" pattern="$2"
  shift 2
  local out
  if out="$("$@" 2>&1)" && false; then
    fail "$label: expected non-zero exit"
  elif printf '%s' "$out" | grep -qF "$pattern"; then
    pass "$label"
  else
    fail "$label: output did not contain '$pattern': $out"
  fi
}

# --- pins-derived helpers ----------------------------------------------------
MODELS_DIR="$FAKE_HOME/local-llm/models"
DRAFTS_DIR="$FAKE_HOME/local-llm/drafts"
RUNTIME_DIR="$FAKE_HOME/local-llm/runtime/llama-b11095"
MODEL_FILE="$(python3 -c 'import json;print(json.load(open("'$ROOT'/pins.json"))["model"]["file"])')"
MODEL_BYTES="$(python3 -c 'import json;print(json.load(open("'$ROOT'/pins.json"))["model"]["bytes"])')"
DRAFT_FILE="$(python3 -c 'import json;print(json.load(open("'$ROOT'/pins.json"))["model"]["draft"]["file"])')"
DRAFT_BYTES="$(python3 -c 'import json;print(json.load(open("'$ROOT'/pins.json"))["model"]["draft"]["bytes"])')"

fresh_home() {
  rm -rf "$FAKE_HOME"
  mkdir -p "$MODELS_DIR" "$DRAFTS_DIR" "$RUNTIME_DIR"
}

good_install() {
  fresh_home
  cat >"$RUNTIME_DIR/llama-server" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$(dirname "$0")/invoked.args"
STUB
  chmod +x "$RUNTIME_DIR/llama-server"
  truncate -s "$MODEL_BYTES" "$MODELS_DIR/$MODEL_FILE"
  truncate -s "$DRAFT_BYTES" "$DRAFTS_DIR/$DRAFT_FILE"
}

run_llm() { env HOME="$FAKE_HOME" "$LLM" "$@"; }

# --- 1. url works on a bare checkout (acceptance 1) ---------------------------
fresh_home
OUT="$(run_llm url)"
if [ "$OUT" = "http://127.0.0.1:8080" ]; then
  pass "llm url prints the pinned host:port with nothing installed"
else
  fail "llm url printed '$OUT'"
fi

# --- 2. serve preflight failures (acceptance 2) -------------------------------
fresh_home
expect_fail "serve: missing binary" "not found under" run_llm serve

good_install
rm "$MODELS_DIR/$MODEL_FILE"
expect_fail "serve: zero GGUFs" "expected exactly 1 GGUF in $MODELS_DIR, found 0" run_llm serve

good_install
truncate -s "$MODEL_BYTES" "$MODELS_DIR/other-model.gguf"
expect_fail "serve: two GGUFs" "expected exactly 1 GGUF in $MODELS_DIR, found 2" run_llm serve

good_install
mv "$MODELS_DIR/$MODEL_FILE" "$MODELS_DIR/wrong-name.gguf"
expect_fail "serve: wrong model file" "pins.json names $MODEL_FILE" run_llm serve

good_install
truncate -s "$((MODEL_BYTES - 1))" "$MODELS_DIR/$MODEL_FILE"
expect_fail "serve: model byte mismatch" "bytes, pins.json expects $MODEL_BYTES" run_llm serve

good_install
rm "$DRAFTS_DIR/$DRAFT_FILE"
expect_fail "serve: missing draft" "draft model not found at" run_llm serve

good_install
truncate -s "$((DRAFT_BYTES - 1))" "$DRAFTS_DIR/$DRAFT_FILE"
expect_fail "serve: draft byte mismatch" "bytes, pins.json expects $DRAFT_BYTES" run_llm serve

# --- 3. serve success path: exec with the pinned flags -------------------------
good_install
OUT="$(run_llm serve 2>&1)"
for fragment in "llama.cpp b11095" "--spec-type draft-mtp"; do
  if printf '%s' "$OUT" | grep -qF -- "$fragment"; then
    pass "serve banner names $fragment"
  else
    fail "serve banner missing '$fragment'"
  fi
done
if grep -qF -- '--spec-draft-model' "$RUNTIME_DIR/invoked.args" &&
  grep -qF -- '-ngl' "$RUNTIME_DIR/invoked.args" &&
  grep -qx '99' "$RUNTIME_DIR/invoked.args" &&
  grep -qF -- '--models-max' "$RUNTIME_DIR/invoked.args" &&
  grep -qF -- '--no-models-autoload' "$RUNTIME_DIR/invoked.args"; then
  pass "serve execs llama-server with the pinned flags"
else
  fail "serve did not exec llama-server with the pinned flags"
fi

# --- 4. verify against a dead port (offline half of acceptance 3) --------------
fresh_home
expect_fail "verify: down server" "server not running at http://127.0.0.1:8080" run_llm verify

# --- 5. state probe answers JSON with the server down --------------------------
fresh_home
OUT="$(run_llm state probe)"
if printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["state"]=="blocked" and d["label"]=="server offline"'; then
  pass "state probe: blocked JSON with the server down"
else
  fail "state probe did not report blocked/offline: $OUT"
fi

# --- 6. dispatcher hygiene ------------------------------------------------------
expect_fail "dispatcher: unknown verb" "unknown verb" run_llm frobnicate
expect_fail "dispatcher: no verb" "usage:" env HOME="$FAKE_HOME" "$LLM"
expect_fail "state: needs a subcommand" "usage: llm state probe" run_llm state

# --- 7. llm herdr: plugin registration (stub herdr via HERDR_BIN_PATH) ---------
fresh_home
STUB_BIN="$FIXTURES/herdr-stub"
REG="$FIXTURES/registered"
LOG="$FIXTURES/herdr.calls"
: >"$LOG"
cat >"$STUB_BIN" <<STUB
#!/bin/bash
case "\$1 \$2" in
  "plugin list")
    [ -f "$REG" ] && echo "- llama-state (Local Model State) enabled $FIXTURES/wherever"
    ;;
  "plugin link"|"plugin unlink")
    echo "\$*" >>"$LOG"
    case "\$2" in
      link)   touch "$REG" ;;
      unlink) rm -f "$REG" ;;
    esac
    ;;
esac
STUB
chmod +x "$STUB_BIN"
run_stubbed() { env HOME="$FAKE_HOME" HERDR_BIN_PATH="$STUB_BIN" "$LLM" "$@"; }

# install links the vendored plugin
echo "==> install from clean"
OUT="$(run_stubbed herdr --install)"
if grep -qx "plugin link $ROOT/llama-state" "$LOG"; then
  pass "herdr --install links the vendored llama-state"
else
  fail "herdr --install did not link the vendored plugin: $OUT"
fi

# install is idempotent: a stale registration is unlinked first
: >"$LOG"
touch "$REG"
run_stubbed herdr --install >/dev/null
if [ "$(head -n1 "$LOG")" = "plugin unlink llama-state" ] &&
   [ "$(tail -n1 "$LOG")" = "plugin link $ROOT/llama-state" ]; then
  pass "herdr --install reconciles a stale registration (unlink, then link)"
else
  fail "herdr --install did not unlink before linking: $(cat "$LOG")"
fi

# uninstall removes the registration, and is quiet when nothing is registered
: >"$LOG"
run_stubbed herdr --uninstall >/dev/null
if grep -qx "plugin unlink llama-state" "$LOG"; then
  pass "herdr --uninstall unlinks llama-state"
else
  fail "herdr --uninstall did not unlink: $(cat "$LOG")"
fi
: >"$LOG"
run_stubbed herdr --uninstall >/dev/null
if [ ! -s "$LOG" ]; then
  pass "herdr --uninstall is a no-op when not registered"
else
  fail "herdr --uninstall called herdr when not registered: $(cat "$LOG")"
fi

# a missing herdr binary must fail loudly, not silently skip
if env HOME="$FAKE_HOME" HERDR_BIN_PATH="$FIXTURES/no-such-herdr" \
    "$LLM" herdr --install >/dev/null 2>&1; then
  fail "herdr --install with herdr missing should exit non-zero"
else
  pass "herdr --install fails loudly when herdr is absent"
fi

expect_fail "herdr: needs a flag" "usage: llm herdr" run_stubbed herdr

if [ "$HOME" = "$FAKE_HOME" ]; then
  fail "tests clobbered the real HOME"
fi

printf '\n%d passed, %d failed\n' "$passes" "$fails"
[ "$fails" -eq 0 ]
