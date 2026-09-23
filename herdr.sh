#!/bin/bash
set -euo pipefail
#
# Register the vendored llama-state plugin with herdr. Reached as
# `llm herdr --install` (or --uninstall); herdr keeps registrations in its own
# runtime state (~/.config/herdr/plugins.json), so this is idempotent: a stale
# registration is unlinked before the link, reconciling a moved checkout
# instead of silently keeping it.
#
# HERDR_BIN_PATH (what herdr sets for its own plugin processes) is honoured so
# the verb works from inside a herdr pane too.

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="llama-state"
PLUGIN_SRC="$DIR/llama-state"
HERDR="${HERDR_BIN_PATH:-herdr}"

usage() {
  echo "usage: llm herdr --install | --uninstall" >&2
}

# The registry is read once into a variable: piping `herdr plugin list` into
# `grep -q` dies of SIGPIPE at the first match and reports 141 under pipefail.
# Entries are listed as `- <id> (<name>) enabled [source]`, so the trailing
# space anchors the id without matching a prefix of a longer one.
INSTALLED="$("$HERDR" plugin list 2>/dev/null || true)"
registered() {
  case "$INSTALLED" in
  *"- $1 "*) return 0 ;;
  *) return 1 ;;
  esac
}

[ $# -ge 1 ] || { usage; exit 2; }

case "$1" in
--install)
  # A manifest herdr rejects must fail loudly, not scroll past as one warning.
  [ -f "$PLUGIN_SRC/herdr-plugin.toml" ] || {
    echo "llm herdr: missing $PLUGIN_SRC/herdr-plugin.toml" >&2
    exit 1
  }
  if registered "$PLUGIN_ID"; then
    "$HERDR" plugin unlink "$PLUGIN_ID"
  fi
  "$HERDR" plugin link "$PLUGIN_SRC"
  echo "==> linked herdr plugin: $PLUGIN_ID -> $PLUGIN_SRC"
  ;;
--uninstall)
  if registered "$PLUGIN_ID"; then
    "$HERDR" plugin unlink "$PLUGIN_ID"
    echo "==> unlinked herdr plugin: $PLUGIN_ID"
  fi
  ;;
*)
  usage
  exit 2
  ;;
esac
