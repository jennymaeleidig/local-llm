#!/bin/bash
set -euo pipefail
#
# Serve the pinned gemma-4-26B-A4B GGUF with the pinned llama.cpp build.
#
# The target is paired with its pinned MTP drafter (pins.json `model.draft`) for
# speculative decoding. The drafter lives outside the models directory, which is
# the router catalogue and stays at exactly one GGUF.
#
# This is host-owner material: run it yourself, in the foreground, when you want
# the model up. It is not an Apply effect and there is no login item — the
# server should not be running unless you asked for it.
#
#   llm serve
#
# The build and the model file are named only in pins.json; this script derives
# every path and every identifier from it. In router mode llama-server is
# started *without* --model: it catalogues --models-dir and loads a model on
# demand (and only on demand — --no-models-autoload). --models-max 1 makes a
# second load a loud error rather than a silent second copy in memory, so the
# memory cost of a swap is visible before it happens.

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
eval "$(python3 "$DIR/pins.py")"

MODELS_DIR="$HOME/$MODELS_DIR"
RUNTIME="$HOME/$RUNTIME_DIR"
BIN="$(find "$RUNTIME" -type f -name llama-server -perm -u+x 2>/dev/null | head -n 1)"

if [ -z "$BIN" ]; then
  echo "FAIL: llama-server ($LLAMA_CPP_RELEASE) not found under $RUNTIME" >&2
  echo "      Download and extract the pinned runtime first; see SETUP.md in the repo root." >&2
  exit 1
fi

# One model loadable means exactly one model on disk: a second GGUF would let
# the router load a different model than the pins describe.
GGUFS="$(find "$MODELS_DIR" -maxdepth 1 -type f -name '*.gguf' 2>/dev/null || true)"
COUNT="$(printf '%s\n' "$GGUFS" | grep -c . || true)"
if [ "$COUNT" != "1" ]; then
  echo "FAIL: expected exactly 1 GGUF in $MODELS_DIR, found $COUNT" >&2
  echo "      The model directory is part of the pins; see SETUP.md in the repo root." >&2
  exit 1
fi
if [ "$(basename "$GGUFS")" != "$MODEL_FILE" ]; then
  echo "FAIL: $MODELS_DIR holds $(basename "$GGUFS"), but pins.json names $MODEL_FILE" >&2
  exit 1
fi

ACTUAL_BYTES="$(stat -f '%z' "$GGUFS")"
if [ "$ACTUAL_BYTES" != "$MODEL_BYTES" ]; then
  echo "FAIL: $GGUFS is $ACTUAL_BYTES bytes, pins.json expects $MODEL_BYTES" >&2
  echo "      A truncated download is the usual cause; re-run the download in SETUP.md." >&2
  exit 1
fi

# The drafter is checked the same way the target is: a missing or truncated
# draft model would otherwise degrade into plain decoding with no error, which is
# the one failure this pairing exists to prevent.
DRAFT_PATH="$HOME/$DRAFT_DIR/$DRAFT_FILE"
if [ ! -f "$DRAFT_PATH" ]; then
  echo "FAIL: draft model not found at $DRAFT_PATH" >&2
  echo "      Download the pinned drafter first; see SETUP.md in the repo root." >&2
  exit 1
fi
DRAFT_ACTUAL_BYTES="$(stat -f '%z' "$DRAFT_PATH")"
if [ "$DRAFT_ACTUAL_BYTES" != "$DRAFT_BYTES" ]; then
  echo "FAIL: $DRAFT_PATH is $DRAFT_ACTUAL_BYTES bytes, pins.json expects $DRAFT_BYTES" >&2
  exit 1
fi

echo "==> llama.cpp $LLAMA_CPP_RELEASE"
echo "    binary  $BIN"
echo "    model   $MODELS_DIR/$MODEL_FILE ($MODEL_BYTES bytes)"
echo "    draft   $DRAFT_DIR/$DRAFT_FILE ($DRAFT_BYTES bytes, --spec-type draft-mtp)"
echo "    router   http://$SERVER_HOST:$SERVER_PORT  (-c $CONTEXT_WINDOW, --models-max 1)"
echo "    in pi   /llama to load it, /model to select it (nothing loads until then)"
echo "    stop     Ctrl-C"

# Flag notes (see SETUP.md for the reasoning):
#   --jinja            explicit, not left to a build default; the GGUF's own
#                      gemma4 template is what parses tool calls and the
#                      thinking toggle (chat_template_kwargs.enable_thinking).
#   -ngl 99            all layers of this model on the GPU; "all" is also
#                      accepted. Offload is the one silent slowdown, so the
#                      gate asserts this flag is still here.
#   --cache-type-k/v   q8_0 halves KV cache; it is not the memory lever.
#   -c, --parallel 1   one slot, one window as declared.
#   --cache-ram 0      disables the host-RAM prompt cache (0 disables); it is
#                      not a reservation.
#   --spec-type draft-mtp, --spec-draft-model
#                      speculative decoding with the pinned MTP drafter, which
#                      shares the target's KV. The flag pair is asserted by the
#                      gate so a silent drop to plain decoding is caught.
#   --spec-draft-n-max 1
#                      tokens drafted per step. 1 is the measured optimum on
#                      bandwidth-limited Apple silicon, where the verify forward
#                      scales with draft depth while acceptance does not; the
#                      build's own default is 3. Raise it only with --measure
#                      evidence. (--draft-n is gone; it now errors.)
#   no --batch-size    it bounds the logical batch, not prefill compute.
#   no --swa-full      unnecessary: the window-sized SWA cache is the norm.
#   no --reasoning-effort  the flag exists (default "default") but this model's
#                      template does not read it: thinking is a boolean the
#                      request sets through chat_template_kwargs, so no
#                      server-side default is imposed here.
#   no --reasoning-format  the default "auto" is what puts thoughts in
#                      message.reasoning_content for the harness to read. The
#                      gate no longer asserts this; verify it by hand (SETUP.md).
exec "$BIN" \
  --models-dir "$MODELS_DIR" \
  --models-max 1 \
  --no-models-autoload \
  --jinja \
  -ngl 99 \
  -c "$CONTEXT_WINDOW" \
  --parallel 1 \
  --cache-type-k q8_0 \
  --cache-type-v q8_0 \
  -fa on \
  --cache-ram 0 \
  --spec-type draft-mtp \
  --spec-draft-model "$DRAFT_PATH" \
  --spec-draft-n-max 1 \
  --host "$SERVER_HOST" \
  --port "$SERVER_PORT"
