# llm-serve

The local model runtime as one repo: a pinned llama.cpp `llama-server`
(router mode, MTP drafter, speculative decoding), its read-only gate, and
a thin verb CLI as the only interface.

Nothing here vendors binaries or weights — `pins.json` names the exact
build and the model/drafter pair, and the host owner downloads both (see
[SETUP.md](SETUP.md)). Nothing runs at login and nothing starts a server
for you; the server is up when you start it, and not otherwise.

## Usage

```bash
llm serve          # eval pins, preflight, exec llama-server (foreground)
llm verify         # the gate: read-only assertions against a running server
llm url            # print http://$SERVER_HOST:$SERVER_PORT from pins.json
llm state probe    # one JSON sample of the server, no herdr calls
```

`bin/llm` is the single entrypoint; put the repo's `bin/` on your PATH.
The URL is the only fact callers learn — pins schema, drafter pairing,
flag reasoning, and gate phases are implementation.

Layout:

    bin/llm            dispatcher: serve | verify | url | state probe
    serve.sh           launcher, moved verbatim
    gate.sh            the gate, moved verbatim
    pins.py pins.json  the pins: exact llama.cpp build + model/draft pair
    SETUP.md           provisioning steps and flag reasoning
    llama-state/       the herdr sidebar plugin (reports server state)
    tests/             offline tests (no server, no runtime needed)

## Verify

Run `tests/run.sh` for the offline suite: `llm url` against a bare
checkout, and every `llm serve` preflight failure. The live gate is
`llm verify` against a running pinned server.

## License

CC0-1.0. See [LICENSE](LICENSE) and [CITATION.cff](CITATION.cff).
