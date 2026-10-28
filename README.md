# hfq

Zero-dependency, single-instance FIFO queue in front of the Hugging Face CLI.
Invoke `hfq download ...` instead of `hf download ...`: the first process owns
the queue and works through every command handed to it, one at a time, in
arrival order.

Status: working, tested 2026-10-28. Python 3.9+ standard library only
(Linux/POSIX). The `hf` executable must be on `PATH`.

## Why

`hf download` has no queue of its own. Starting several downloads in parallel
splits the link and makes progress hard to read. `hfq` serialises them: the
first invocation becomes the owner, later invocations append to its queue and
exit immediately.

## Install

```console
$ ./setup.sh
```

The script creates `.venv`, installs `huggingface_hub` (which provides the
`hf` CLI) inside it, and symlinks `hf` and `hfq` into `~/.local/bin`:

```console
$ hfq download ...
```

`~/.local/bin` is added to your shell path if necessary (fish gets
`~/.config/fish/conf.d/hfq.fish`; bash/zsh get a marked block in their rc).
Re-run the script to update the CLI. Overrides: `HFQ_VENV`, `HFQ_BIN_DIR`,
`PYTHON`.

`hfq` itself has no third-party dependencies; only the wrapped `hf` CLI lives
in the venv.

## Use

```console
$ hfq download Qwen/Qwen3-8B --local-dir ~/models/qwen3-8b
```

The first invocation takes over the terminal:

```text
Huggingface Queue Utility
Downloads
> hf download Qwen/Qwen3-8B --local-dir /home/me/models/qwen3-8b

Fetching 12 files: 100%|██████████| 12/12 ...
```

From any other terminal, keep adding work:

```console
$ hfq download meta-llama/Llama-3.1-8B --include "*.safetensors"
queued: hf download meta-llama/Llama-3.1-8B --include *.safetensors (1 pending)
```

The owner redraws the list with the new command at the bottom of the queue.
When the active download exits, the next one starts immediately.

## Behaviour

- **One owner.** An exclusive `flock` on the runtime lock decides ownership.
  Other invocations never download; they hand their arguments to the owner
  over a Unix socket and exit.
- **FIFO.** Commands run in the order the owner accepted them, each to
  completion, with no overlap.
- **Failures do not stop the queue.** A non-zero `hf` exit is annotated as
  `[hfq] hf exited with status N` and the next command starts.
- **The invoking directory is preserved.** A relative `--local-dir` resolves
  against the directory the client was in, not the owner's.
- **One environment.** Every child runs with the owner's environment
  (`HF_TOKEN`, `HF_HOME`, proxies). Only argv and the client's cwd are
  forwarded.
- **Ctrl-C** forwards SIGINT to the active `hf` process group, discards the
  remaining queue, and returns the terminal to the shell.
- **In-memory queue.** Closing the owner loses anything still queued; this is
  a foreground helper, not a daemon.

## Display

TTY mode clears the screen, reserves the top rows for the header and queue,
and confines child output to a scroll region underneath:

- the first entry (`>`) is the active download;
- the rest are pending, in order;
- one blank line separates the list from the live `hf` output;
- long commands are truncated to the terminal width; past `rows - 6` entries
  the tail collapses to `... N more`;
- terminal resize redraws the header and resizes the child PTY.

Non-TTY output (pipes, logs) degrades to plain text: the header block once,
then `queued:` / `running:` lines interleaved with raw `hf` output. Children
run without a PTY in that mode; whatever `hf` prints is forwarded verbatim.

## Runtime state

`$XDG_RUNTIME_DIR/hfq` (fallback `/tmp/hfq-<uid>`, mode `0700`) holds:

| File | Purpose |
|------|---------|
| `hfq.lock` | exclusive owner lock |
| `hfq.sock` | client enqueue socket (mode `0600`) |

Override the directory with `HFQ_RUNTIME_DIR`. Stale sockets are removed by
the next owner; the lock is released automatically when the owner exits.

## Development

```console
$ python3 -m unittest discover -s tests -v
```

The suite drives the real executable with `tests/stub/hf` on `PATH`; it covers
FIFO ordering, sequential execution, live header rendering, concurrent
clients, cwd preservation, non-TTY operation, and owner handover after the
queue drains. Design notes: `docs/design.md`.
