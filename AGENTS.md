# AGENTS.md — QueueHuggingFace (`qhf`)

Context for AI-assisted contributors. Read before editing.

## Overview

- **What this is:** QueueHuggingFace (`qhf`), a single-file, zero-dependency
  (Python stdlib only) console wrapper around the Hugging Face CLI. The first
  process owns an in-memory FIFO queue; later processes hand it argv + cwd
  over a Unix socket and exit. The owner runs `hf` children sequentially and
  renders the queue above their live output.
- **User-facing behaviour:** `README.md`.
- **Vocabulary:** `CONTEXT.md`.
- **Internals:** `docs/design.md`.
- **Current state / next actions:** `docs/handover.md`.
- **Remote:** `origin` → `https://github.com/hughyyy/queuehuggingface.git`,
  branch `main`.

## Entry points

- `qhf` — the whole application: client path, owner/server, display, PTY
  forwarding. Keep it a single file; it is deployed by symlink.
- `tests/test_queue.py` — end-to-end tests against a stub `hf`.
- `tests/stub/hf` — stub CLI; prints its cwd and args and records
  `START`/`END` lines in `$QHF_TEST_LOG`.
- `docs/plan-configurator.md` — the proposed subcommand/listing/selector
  design; not implemented.
- `setup.sh` — venv, `hf`, and PATH provisioning.

## Invariants

- **One owner.** Ownership is an exclusive non-blocking `flock` on
  `$QHF_RUNTIME_DIR/qhf.lock`. Never start a second downloader path.
- **FIFO, one child at a time.** The main thread pops from `self.queue`; the
  client thread only appends and writes a wake byte. Do not run children in
  parallel.
- **Only the main thread may redraw the TTY.** The socket thread may write
  `queued:` notices only in non-TTY mode.
- **Clients never block for the download.** They wait for an ack line, then
  exit. An owner that is draining rejects with `retry`; the client falls back
  to acquiring the lock itself.
- **Ordering on shutdown.** Close the listener, unlink the socket, then drop
  the lock (main closes the fd). Set `closing` under `q_lock` before exiting
  so late clients retry instead of enqueueing into a dead owner.
- **Display math.** `Ui.header_h` tracks the rendered header height. Grow =
  insert lines at the top of the old output region; shrink = delete lines at
  the top of the new one. `Ui.out_lines` counts newlines in forwarded output
  so a redraw can restore the stream cursor. `CSI r` homes the cursor:
  always reposition after setting or resetting margins.
- **Child processes** run in their own session (`pty.fork` / `start_new_session`)
  with `cwd=item.cwd`; shutdown signals go to the process group end.

## Commands

- Setup: `./setup.sh` — creates/reuses `.venv`, installs `huggingface_hub`
  (the `hf` CLI) there, links `qhf` into `~/.local/bin`, and links the venv's
  `hf` only when no `hf` already exists. Overrides: `QHF_VENV`,
  `QHF_BIN_DIR`, `PYTHON`.
- Test: `python3 -m unittest discover -s tests -v`
- Syntax: `python3 -m py_compile qhf`
- Manual smoke: prepend `tests/stub` to `PATH`, set `QHF_TEST_LOG`, run
  `./qhf download a`, then `./qhf download b` from another shell.
- Real smoke (network): `qhf download sshleifer/tiny-gpt2 --local-dir
  /tmp/qhf-smoke`.

## Scope guardrails

- No third-party dependencies in `qhf`. The `.venv` exists only for the
  wrapped `hf` CLI; never import its packages from the executable.
- No persistence, daemonisation, priorities, retries, or config files unless
  requested; the queue is deliberately in-memory and foreground.
- Keep the display plain (no colour, no alternate screen, no dashboard).
- Do not change the socket protocol silently; document it in `docs/design.md`.
- Update `README.md` when user-facing behaviour changes; update `CONTEXT.md`
  when terminology or boundaries change; update `docs/handover.md` when state
  or next actions change.
- After edits: `python3 -m py_compile qhf` and the full test suite. Verify
  both TTY and non-TTY paths when touching display or child execution.
