#!/usr/bin/env python3
"""llama-state — the local llama-server's state, in herdr's sidebar.

Observation only. This plugin does not start, stop, load, or unload anything:
`serve.sh` in this repo is the only launcher and pi's `/llama` is
the only loader. It polls llama-server's own HTTP API and hands herdr two facts
— lifecycle state and a label — for the pane it runs in.

Everything it knows comes from the server, so there is no second copy of the
pins: the connection point is `$LLAMA_BASE_URL` (the export your shell dotfiles
derive from pins.json) and the model name is whatever
`GET /models` reports as loaded.

Usage:
  llama-state.py monitor [--base-url URL] [--interval N] [--verbose]
        Pane entrypoint. Polls, prints on change, reports to herdr.
  llama-state.py toggle
        Open the monitor pane, or dismiss it when it is already open.
  llama-state.py probe [--base-url URL]
        One sample as JSON, no herdr calls. Test seam.
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

SOURCE = "herdr:llama-state"
AGENT = "llama-server"
PLUGIN_ID = "llama-state"
ENTRYPOINT = "monitor"
DEFAULT_BASE_URL = "http://127.0.0.1:8080"  # llama-server's own default
HTTP_TIMEOUT = 2.0
LOADED = ("loaded", "sleeping")  # sleeping: loaded and idle after --sleep
TOKENS_TOTAL = "llamacpp:tokens_predicted_total"
TOKENS_SECONDS = "llamacpp:tokens_predicted_seconds_total"
PREDICTED_TPS = "llamacpp:predicted_tokens_seconds"  # gauge: server's own throughput
REQUESTS_PROCESSING = "llamacpp:requests_processing"


# --- llama-server ----------------------------------------------------------


def _text(url: str) -> str | None:
    """GET as text, or None when the server is unreachable or 404s.

    Every probe is optional: llama-server's older builds answer /metrics but not
    /slots and vice versa, and a mid-restart server answers neither.
    """
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
            return response.read().decode("utf-8", "replace")
    except (urllib.error.URLError, OSError, TimeoutError):
        return None


def _json(url: str):
    body = _text(url)
    if body is None:
        return None
    try:
        return json.loads(body)
    except ValueError:
        return None


def _model_query(model: str | None) -> str:
    """`?model=<id>` for the router, `""` for the single-model server.

    Router mode (serve.sh runs --models-dir) proxies /metrics and /slots to a
    per-model child and answers 400 unless `?model=` names one; the
    single-model server ignores the param, so it is safe to always send it
    once /models has told us which model is loaded.
    """
    return f"?model={urllib.parse.quote(model)}" if model else ""


def _metrics(base_url: str, model: str | None = None) -> dict:
    """Prometheus values, or {} when /metrics is off (serve.sh does not pass --metrics)."""
    body = _text(f"{base_url}/metrics{_model_query(model)}")
    if body is None:
        return {}
    values = {}
    for line in body.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        try:
            values[parts[0]] = float(parts[1])
        except ValueError:
            pass
    return values


def sample(base_url: str) -> dict:
    """One observation of the server. No interpretation (see classify)."""
    facts: dict = {
        "base_url": base_url,
        "reachable": False,
        "health": None,
        "loaded": [],  # model ids the server reports as loaded
        "loading": [],  # model ids the server reports as loading
        "metrics": {},  # prometheus values; empty when /metrics is unreachable
        "busy": None,  # True/False from metrics or slots, None when unknown
    }

    health = _json(f"{base_url}/health")
    if health is None:
        return facts  # offline: nothing else is worth probing
    facts["reachable"] = True
    facts["health"] = health.get("status")

    catalogue = _json(f"{base_url}/models") or {}
    for model in catalogue.get("data", []):
        value = (model.get("status") or {}).get("value")
        if value in LOADED:
            facts["loaded"].append(model.get("id"))
        elif value == "loading":
            facts["loading"].append(model.get("id"))

    model = facts["loaded"][0] if facts["loaded"] else None
    facts["metrics"] = _metrics(base_url, model)
    if REQUESTS_PROCESSING in facts["metrics"]:
        facts["busy"] = facts["metrics"][REQUESTS_PROCESSING] > 0
    else:
        slots = _json(f"{base_url}/slots{_model_query(model)}")
        if isinstance(slots, list):
            facts["busy"] = any(slot.get("is_processing") for slot in slots)

    return facts


def _gauge_tps(metrics: dict) -> float | None:
    """The server's own throughput gauge, needing no previous sample.

    /metrics reports `llamacpp:predicted_tokens_seconds` ("average generation
    throughput in tokens/s") alongside the counters. A single `probe` has no
    earlier sample to diff counters against, so the gauge is what lets it show
    a rate while `monitor` keeps using the live counter interval.
    """
    gauge = metrics.get(PREDICTED_TPS)
    return gauge if gauge else None


def rate(facts: dict, previous: tuple[float, float] | None) -> tuple[float | None, tuple[float, float] | None]:
    """Tokens/second over the gap since the previous sample, from counters.

    Prometheus counters are cumulative, so the interval rate is the only live
    figure: a finished request must decay to 0 t/s rather than keep its average.
    The first sample (and any server without counters) falls back to the gauge.
    """
    metrics = facts["metrics"]
    if TOKENS_TOTAL not in metrics or TOKENS_SECONDS not in metrics:
        return _gauge_tps(metrics), previous
    current = (metrics[TOKENS_TOTAL], metrics[TOKENS_SECONDS])
    if previous is None:
        return _gauge_tps(metrics), current
    tokens = current[0] - previous[0]
    seconds = current[1] - previous[1]
    if seconds <= 0:
        return 0.0, current
    return tokens / seconds, current


def classify(facts: dict, tps: float | None) -> tuple[str, str, str]:
    """Facts -> (herdr state, sidebar label, info token). Pure; the one decision point.

    The info token carries no spaces: herdr tokens are NAME=VALUE, and the
    sidebar renders the value as-is.
    """
    if not facts["reachable"]:
        return "blocked", "server offline", "offline"
    if facts["loading"]:
        return "working", f"loading {facts['loading'][0]}", "loading"
    if not facts["loaded"]:
        return "idle", "no model loaded", "ready-to-load"
    model = facts["loaded"][0]
    if facts["busy"]:
        label = f"{tps:.1f} t/s" if tps else "working"
        return "working", label, f"working:{model}"
    return "idle", f"ready: {model}", f"ready:{model}"


# --- herdr -----------------------------------------------------------------


def _herdr(*args: str) -> subprocess.CompletedProcess:
    """Invoke herdr. HERDR_BIN_PATH is what herdr sets for its own plugin processes."""
    binary = os.environ.get("HERDR_BIN_PATH", "herdr")
    return subprocess.run([binary, *args], capture_output=True, text=True, timeout=10)


def report(pane: str, state: str, label: str, info: str) -> None:
    """Push state + label for our own pane. report-agent must come first.

    --state-label is STATUS=TEXT and STATUS must be one of herdr's own state
    names (``ready=...`` is rejected), which is why the state is passed twice.
    """
    _herdr(
        "pane", "report-agent", pane,
        "--source", SOURCE,
        "--agent", AGENT,
        "--state", state,
    )
    _herdr(
        "pane", "report-metadata", pane,
        "--source", SOURCE,
        "--title", AGENT,
        "--state-label", f"{state}={label}",
        "--token", f"info={info}",
    )


def release(pane: str) -> None:
    """Give the pane back to herdr's own detection when the monitor exits."""
    _herdr(
        "pane", "release-agent", pane,
        "--source", SOURCE,
        "--agent", AGENT,
    )


def own_pane() -> str | None:
    pane = os.environ.get("HERDR_PANE_ID")
    if pane:
        return pane
    result = _herdr("pane", "current")
    try:
        return json.loads(result.stdout)["result"]["pane"]["pane_id"]
    except (ValueError, KeyError, TypeError):
        return None


def _panes() -> list[dict]:
    """Every live pane, or [] when herdr cannot be asked."""
    result = _herdr("pane", "list")
    try:
        return json.loads(result.stdout)["result"]["panes"]
    except (ValueError, KeyError, TypeError):
        return []


# --- commands --------------------------------------------------------------


def base_url(argument: str | None) -> tuple[str, str]:
    """(url, where it came from) — printed so a wrong port is never silent."""
    if argument:
        return argument, "--base-url"
    exported = os.environ.get("LLAMA_BASE_URL")
    if exported:
        return exported.rstrip("/"), "LLAMA_BASE_URL"
    return DEFAULT_BASE_URL, "default (llama-server's own port)"


def cmd_probe(args: argparse.Namespace) -> int:
    base, source = base_url(args.base_url)
    facts = sample(base)
    tps, _ = rate(facts, None)
    state, label, info = classify(facts, tps)
    print(json.dumps(
        {"base_url": base, "url_source": source, "state": state, "label": label,
         "info": info, "facts": facts},
        indent=2, sort_keys=True,
    ))
    return 0


def cmd_toggle(_args: argparse.Namespace) -> int:
    """Open the monitor pane, or dismiss it when it is already there.

    herdr has no toggle primitive -- `plugin pane open` always opens another
    split -- so find the pane the monitor registered itself in (it reports the
    agent name AGENT) and act on that. Focused means the key is a dismiss;
    otherwise it is a reveal. Any surplus panes from before this toggle existed
    are closed, so it converges on at most one monitor.
    """
    mine = [pane for pane in _panes() if pane.get("agent") == AGENT]
    if not mine:
        _herdr("plugin", "pane", "open", "--plugin", PLUGIN_ID,
               "--entrypoint", ENTRYPOINT, "--placement", "split", "--focus")
        return 0
    if any(pane.get("focused") for pane in mine):
        for pane in mine:
            _herdr("plugin", "pane", "close", pane["pane_id"])
    else:
        _herdr("plugin", "pane", "focus", mine[0]["pane_id"])
        for pane in mine[1:]:
            _herdr("plugin", "pane", "close", pane["pane_id"])
    return 0


def cmd_monitor(args: argparse.Namespace) -> int:
    base, source = base_url(args.base_url)
    pane = own_pane()
    if not pane:
        print("llama-state: no herdr pane (HERDR_PANE_ID unset and "
              "`herdr pane current` failed)", file=sys.stderr)
        return 1

    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    print(f"llama-state  pane {pane}  base {base}  ({source})", flush=True)
    previous_counters = None
    previous_report = None
    try:
        while not stopping:
            facts = sample(base)
            tps, previous_counters = rate(facts, previous_counters)
            state, label, info = classify(facts, tps)
            changed = (state, label) != previous_report
            if changed:
                # Report on change only: each report is two herdr subprocesses.
                report(pane, state, label, info)
            if args.verbose or changed:
                stamp = time.strftime("%H:%M:%S")
                print(f"{stamp}  {state:<8} {label}", flush=True)
                previous_report = (state, label)
            # Sleep in slices so Ctrl-C is responsive at long intervals.
            deadline = time.monotonic() + args.interval
            while not stopping and time.monotonic() < deadline:
                time.sleep(0.2)
    finally:
        release(pane)
        print("llama-state: stopped reporting", flush=True)
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    subcommands = parser.add_subparsers(dest="command", required=True)

    monitor = subcommands.add_parser("monitor", help="poll and report to herdr")
    monitor.add_argument("--base-url", help="override $LLAMA_BASE_URL")
    monitor.add_argument("--interval", type=float, default=2.0, help="seconds between samples")
    monitor.add_argument("--verbose", action="store_true", help="print every sample, not just changes")
    monitor.set_defaults(func=cmd_monitor)

    toggle = subcommands.add_parser("toggle", help="open the monitor pane, or dismiss it if open")
    toggle.set_defaults(func=cmd_toggle)

    probe = subcommands.add_parser("probe", help="one sample as JSON, no herdr calls")
    probe.add_argument("--base-url", help="override $LLAMA_BASE_URL")
    probe.set_defaults(func=cmd_probe)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
