#!/usr/bin/env python3
"""Print pins.json as shell assignments for `eval` in serve.sh and gate.sh.

Keeps the JSON readable and nested while giving the shell a flat namespace of
the values that are otherwise easy to retype. One declaration below drives both
the emitted names and the completeness check, so a pin cannot exist in one and
be missing from the other.

Two values are derived rather than pinned. `RUNTIME_DIR` is the directory the
release archive unpacks to: the archive's single top-level directory is
`llama-<release>`, verified against the pinned asset. `MODEL_ID` is declared in
pins.json and only checked here against the model file name, because the router
catalog id is what the harness has to agree with and a declaration that is
verified beats a convention that is assumed.

The draft model (`DRAFT_*`) is deliberately named by file only: it ships in the
same repository at the same revision as the target, so `DRAFT_REPO` and
`DRAFT_REVISION` are emitted from `model.repo` and `model.revision` rather than
declared a second time. A repo bump therefore moves both artifacts, and there is
no second revision to drift.
"""

import json
import pathlib
import shlex
import sys

PINS_PATH = pathlib.Path(__file__).resolve().parent / "pins.json"

# (shell name, path into pins.json). Order is the emitted order.
PINNED = (
    ("LLAMA_CPP_RELEASE", "llamaCpp.release"),
    ("LLAMA_CPP_COMMIT", "llamaCpp.commit"),
    ("LLAMA_CPP_ASSET_URL", "llamaCpp.assetUrl"),
    ("LLAMA_CPP_ASSET_BYTES", "llamaCpp.assetBytes"),
    ("LLAMA_CPP_ASSET_SHA256", "llamaCpp.assetSha256"),
    ("MODEL_REPO", "model.repo"),
    ("MODEL_REVISION", "model.revision"),
    ("MODEL_FILE", "model.file"),
    ("MODEL_ID", "model.id"),
    ("MODEL_BYTES", "model.bytes"),
    ("MODEL_SHA256", "model.sha256"),
    ("DRAFT_REPO", "model.repo"),
    ("DRAFT_REVISION", "model.revision"),
    ("DRAFT_FILE", "model.draft.file"),
    ("DRAFT_BYTES", "model.draft.bytes"),
    ("DRAFT_SHA256", "model.draft.sha256"),
    ("SERVER_HOST", "server.host"),
    ("SERVER_PORT", "server.port"),
    ("CONTEXT_WINDOW", "server.contextWindow"),
    ("MODELS_DIR", "server.modelsDir"),
    ("DRAFT_DIR", "server.draftsDir"),
    ("RUNTIME_ROOT", "server.runtimeDir"),
)


def lookup(pins, dotted):
    value = pins
    for part in dotted.split("."):
        value = value[part]
    return value


def main():
    pins = json.loads(PINS_PATH.read_text())

    missing = [name for name, path in PINNED if lookup(pins, path) in (None, "")]
    if missing:
        print(
            "pins.json is incomplete: missing " + ", ".join(missing),
            file=sys.stderr,
        )
        return 1

    flat = {name: lookup(pins, path) for name, path in PINNED}
    flat["RUNTIME_DIR"] = f"{flat['RUNTIME_ROOT']}/llama-{flat['LLAMA_CPP_RELEASE']}"

    stem = flat["MODEL_FILE"].removesuffix(".gguf")
    if flat["MODEL_ID"] != stem:
        print(
            f"pins.json is inconsistent: model.id is {flat['MODEL_ID']!r} "
            f"but model.file implies {stem!r}",
            file=sys.stderr,
        )
        return 1

    if not flat["DRAFT_FILE"].endswith(".gguf") or flat["DRAFT_FILE"] == flat["MODEL_FILE"]:
        print(
            f"pins.json is inconsistent: model.draft.file is {flat['DRAFT_FILE']!r}, "
            "which must be a .gguf other than the target model.file",
            file=sys.stderr,
        )
        return 1

    for key, value in flat.items():
        print(f"export {key}={shlex.quote(str(value))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
