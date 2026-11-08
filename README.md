# QueueHuggingFace (`qhf`)

Zero-dependency, single-instance FIFO queue in front of the Hugging Face CLI.
Invoke `qhf download ...` instead of `hf download ...`: the first process owns
the queue, shows the active command and everything waiting behind it, and
streams the real `hf` output underneath. Later invocations hand their
arguments to that owner and exit.

The command is deliberately short: type `q`, complete to `qhf`, paste a repo.

Status: working, tested 2026-11-07. Python 3.9+ standard library only
(Linux/POSIX). The `hf` executable must be on `PATH`.

## Requirements

- Linux/POSIX: `pty`, Unix domain sockets, `flock`, terminal scroll regions.
- Python 3.9+ (the executable imports only the standard library).
- The Hugging Face CLI (`hf` from `huggingface_hub`) on `PATH`.
- A terminal for the live view. Piped output falls back to a plain log.

## Install

### Automatic

```console
$ ./setup.sh
```

The script:

1. creates or reuses `.venv` and installs `huggingface_hub` (the `hf` CLI)
   inside it;
2. symlinks `qhf` into `~/.local/bin`;
3. symlinks the venv's `hf` only if no `hf` already exists there, so an
   existing user-managed install is left untouched;
4. adds `~/.local/bin` to the shell path if needed (fish:
   `~/.config/fish/conf.d/qhf.fish`; bash/zsh: a marked block in the rc).

Re-run it after moving the repo or updating the CLI. Overrides:
`QHF_VENV`, `QHF_BIN_DIR`, `PYTHON`.

### Manual

If `hf` is already on `PATH`, only the executable link is needed:

```console
$ mkdir -p ~/.local/bin
$ ln -s "$PWD/qhf" ~/.local/bin/qhf
```

`qhf` itself has no third-party dependencies; the venv exists only for the
wrapped CLI.

### Verify

```console
$ command -v qhf hf
$ qhf --help
$ hf --version
```

## Usage

### Queue a download

```console
$ qhf download Qwen/Qwen3-8B --local-dir ~/models/qwen3-8b
```

The first invocation takes over the terminal:

```text
QueueHuggingFace
Downloads
> hf download Qwen/Qwen3-8B --local-dir /home/me/models/qwen3-8b

Fetching 12 files: 100%|██████████| 12/12 [00:42<00:00, ...]
```

### Add more from any terminal

```console
$ qhf download meta-llama/Llama-3.1-8B --include "*.safetensors"
queued: hf download meta-llama/Llama-3.1-8B --include *.safetensors (1 pending)
```

The owner redraws the list with the new command at the bottom. When the
active download exits, the next one starts immediately.

### Pass-through

Every argument is forwarded verbatim to `hf`:

```console
$ qhf download <repo> --revision main --include "*.json" --quiet
$ qhf upload ...
$ qhf download --help        # hf's help, queued and run
```

The only interception is a bare `qhf --help` / `qhf -h`, which prints this
tool's usage. Running `qhf` with no arguments also prints usage (exit 2).

### Stop

`Ctrl-C` in the owner's terminal sends SIGINT to the active `hf` process
group, discards the remaining queue, restores the terminal, and exits. Closing
the owner's terminal has the same effect. There is no daemon and no
persistence.

## How it works

- The first invocation acquires an exclusive `flock` on
  `$XDG_RUNTIME_DIR/qhf/qhf.lock` and becomes the **owner**.
- Later invocations connect to `qhf.sock`, send
  `{argv, cwd}`, receive an ack, print a receipt, and exit.
- The owner keeps an in-memory FIFO and runs one `hf` child at a time, in its
  own session, with the client's working directory preserved.
- TTY mode runs the child on a PTY so progress bars behave normally, and
  forwards every byte into a scroll region below the queue.
- Non-TTY mode runs the child through a pipe and prints the header once plus
  plain `queued:` / `running:` status lines.

Design details: [`docs/design.md`](docs/design.md).

## Display

TTY mode clears the screen and lays out:

```text
QueueHuggingFace              header
Downloads
> active command              first entry = running
  queued command
  ...
                              blank gap
<live hf output>              scroll region
```

- Long commands are truncated to the terminal width.
- Past `rows - 6` queue entries the tail collapses to `... N more`.
- The header redraws on enqueue/dequeue without losing the stream's cursor.
- Terminal resize re-renders the header and resizes the child PTY.

## Behaviour and limits

- **One owner.** The lock guarantees a single downloader; clients never
  download.
- **FIFO, no overlap.** Each command runs to completion before the next
  starts.
- **Failures do not stop the queue.** A non-zero exit prints
  `[qhf] hf exited with status N` and the next command starts.
- **Client cwd is preserved.** Relative `--local-dir` resolves against the
  invoking directory, not the owner's.
- **Owner environment wins.** All children inherit the owner's `HF_TOKEN`,
  `HF_HOME`, proxies, etc. Only argv and cwd are forwarded.
- **In-memory queue.** Anything pending is lost when the owner exits.
- **Single user.** The runtime directory is `0700`; the socket is `0600`.
- **For humans.** The live view is for interactive use; logs work but have no
  cursor addressing.

## Runtime state

`$XDG_RUNTIME_DIR/qhf` (fallback `/tmp/qhf-<uid>`, mode `0700`):

| File | Purpose |
|------|---------|
| `qhf.lock` | exclusive owner lock |
| `qhf.sock` | client enqueue socket (mode `0600`) |

Override with `QHF_RUNTIME_DIR`. The next owner removes a stale socket; the
lock is released automatically when the owner exits.

## Troubleshooting

**`qhf: \`hf\` not found on PATH`**

Run `./setup.sh`, or install `huggingface_hub` and ensure `hf` resolves:

```console
$ command -v hf
$ hf --version
```

**`qhf: could not reach the running queue`**

Another process may be starting or draining. Retry. Inspect:

```console
$ pgrep -af 'qhf'
$ ls -l "${XDG_RUNTIME_DIR:-/tmp}/qhf"
```

A stale socket is removed by the next owner; do not delete the lock file while
an owner is alive.

**A download fails immediately**

Run the same command directly with `hf` to see the CLI's error. Gated or
private repos need `hf auth login` or `HF_TOKEN` in the **owner's**
environment.

**The display looks wrong / no progress bars**

Use a terminal with a real size; `TERM=dumb` or piped output uses the plain
log mode. Resizing clears the visible pane and redraws the header; earlier
output stays in scrollback.

**The wrong `hf` is used**

`qhf` resolves `hf` from `PATH` at runtime. Check `command -v hf`. `setup.sh`
deliberately leaves an existing `hf` symlink alone.

**The queue disappeared**

The owner exited (Ctrl-C, terminal closed, SIGTERM). The queue is in-memory;
re-invoke the commands.

## Development

```console
$ python3 -m unittest discover -s tests -v
$ python3 -m py_compile qhf
```

The suite drives the real executable with `tests/stub/hf` on `PATH`; it covers
FIFO ordering, sequential execution, live header rendering, concurrent
clients, cwd preservation, non-TTY operation, and owner handover after the
queue drains. No network is required.

Manual stub smoke:

```console
$ export PATH="$PWD/tests/stub:$PATH"
$ export QHF_TEST_LOG=/tmp/qhf-test.log
$ ./qhf download a        # owner
$ ./qhf download b        # second terminal / shell
```

Real smoke (downloads ~4.6 MB):

```console
$ qhf download sshleifer/tiny-gpt2 --local-dir /tmp/qhf-smoke
```

## Project layout

| Path | Purpose |
|------|---------|
| `qhf` | the entire application (client, owner, display) |
| `setup.sh` | venv + `hf` + PATH provisioning |
| `tests/test_queue.py` | end-to-end suite |
| `tests/stub/hf` | stub CLI used by the tests |
| `docs/design.md` | process model, protocol, display math |
| `docs/plan-configurator.md` | proposed file-picker mode |
| `docs/handover.md` | current state, maintainer handover |
| `CONTEXT.md` | domain vocabulary and boundaries |
| `AGENTS.md` | contributor rules and invariants |

## Docs

- [Design](docs/design.md)
- [Configurator plan](docs/plan-configurator.md)
- [Handover](docs/handover.md)
- [Context](CONTEXT.md)
- [Agent instructions](AGENTS.md)

## Roadmap

`qhf <repo-or-url>` will open a download configurator: list the repo tree,
multi-select files/directories, choose a destination and revision, then queue
one constructed `hf download` command. The design, API details, phases, and
test strategy are in [`docs/plan-configurator.md`](docs/plan-configurator.md).
Not implemented yet; `qhf download ...` remains the fast path.
