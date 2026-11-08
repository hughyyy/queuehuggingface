# Handover — QueueHuggingFace (`qhf`)

As of 2026-11-07. Start with [`README.md`](../README.md) for usage, then this
page for state and next actions.

## State

- Working: single-owner FIFO queue, pass-through `qhf <hf args>`, live TTY
  view, PTY forwarding, non-TTY log mode, Ctrl-C cleanup, resize handling.
- Tests: 5/5 (`python3 -m unittest discover -s tests -v`); CI runs the suite
  on Python 3.10 and 3.12.
- Real CLI verified: `qhf download sshleifer/tiny-gpt2 --local-dir ...`
  completed with a current `hf` install.
- Renamed from `hfq`; runtime/env identifiers are now `qhf` / `QHF_*`.
- Remote: `https://github.com/hughyyy/queuehuggingface.git` (**public**),
  branch `main`.
- License: MIT (`LICENSE`).
- Not implemented: download configurator. Proposal:
  [`plan-configurator.md`](plan-configurator.md).

## Run it now

```console
$ cd /path/to/queue-huggingface
$ ./setup.sh          # idempotent; recreates a stale venv and links qhf
$ qhf download <repo> --local-dir <dir>
```

`~/.local/bin/qhf` is the installed entry point. A user-managed `hf` on
`PATH` is used as-is; the project `.venv` is a fallback that setup only links
when no `hf` exists.

## Verify a change

```console
$ python3 -m py_compile qhf
$ python3 -m unittest discover -s tests -v
```

Manual TTY check (fast, offline):

```console
$ export PATH="$PWD/tests/stub:$PATH"
$ export QHF_TEST_LOG=/tmp/qhf-test.log
$ export QHF_TEST_DELAY=0.3 QHF_TEST_STEPS=4
$ ./qhf download alpha
# from another shell, with the same env:
$ ./qhf download beta
```

Real CLI smoke (network, ~4.6 MB):

```console
$ qhf download sshleifer/tiny-gpt2 --local-dir /tmp/qhf-smoke
```

## Architecture in one screen

`qhf` is one stdlib-only file.

| Area | What happens |
|------|--------------|
| Entry | `main()`: `--help`, runtime dir, try `try_enqueue()`, else `acquire_lock()` → `Server.run()`. |
| Client | Sends `{"argv", "cwd"}` as one JSON line; prints `queued:` after an `ok` ack. `retry` loops; it may become the next owner. |
| Owner | `Server`: listener thread + main selector loop. Holds the lock for its lifetime. |
| Queue | `Server.queue` (`list[Item]`), `q_lock`; main thread pops, listener appends and writes `b"q"` to the wake pipe. |
| Child | `Child.spawn`: `pty.fork` in TTY mode, `subprocess.Popen` in log mode; runs in `item.cwd`, own session. |
| Display | `Ui`: fixed header rows, scroll region below, `header_h`/`out_lines` bookkeeping; only the main thread writes the TTY. |
| Shutdown | `_cleanup`: `closing=True`, close listener, unlink socket, terminate child, reset margins, restore cursor. |

Protocol and display math: [`design.md`](design.md).

## Where to change what

- **CLI/dispatch/owner-client logic** → `main()`, `Server`, `try_enqueue()`.
- **Wire protocol** → `Server._handle_client()` + `try_enqueue()`; update
  `docs/design.md`.
- **Display** → `Ui.build_header()` / `Ui.render()`; keep the cursor math in
  sync with `docs/design.md`.
- **Child lifecycle** → `Child`; signals go to the process group.
- **Setup/PATH** → `setup.sh`; keep `QHF_*` overrides documented.
- **Tests** → `tests/test_queue.py`, stub in `tests/stub/hf`.
- **Configurator** → not present; follow `plan-configurator.md`, starting at
  phase 1.

## Gotchas

- **CSI `r` homes the cursor.** Setting/resetting the scroll region moves the
  cursor to home on VT100-style terminals. Every render path repositions;
  `_cleanup` computes the stream row before the final newline. Do not drop
  those moves.
- **One writer.** Never render from the listener thread in TTY mode. It only
  appends under `q_lock`, writes the wake byte, and emits `queued:` notices
  in non-TTY mode.
- **Drain race.** `_next_item()` sets `closing` under the lock when the queue
  is empty. Late clients get `retry`; they then acquire the freed lock and
  become the next owner. Do not send `ok` after `closing`.
- **Lock ordering.** Keep the lock fd open for the owner's whole run. Close
  the listener and unlink the socket before releasing it.
- **Scroll-region output loss.** Growing the header inserts lines at the top
  of the output region; a full region loses its bottom line. This is
  deliberate and rare (enqueues only).
- **Cursor tracking is newline-based.** `out_lines` counts `\n`, not wrapped
  lines or arbitrary cursor moves. `hf`/tqdm progress bars rewrite one line
  with `\r`, so this is stable in practice; long wrapped lines can shift a
  redraw by a row.
- **Non-TTY mode is a separate path.** No PTY, no scroll region; setup/header
  is printed once. Test both paths.
- **In-memory queue.** Owner exit loses pending items. That is a design
  choice, not a bug.
- **Owner environment.** Children inherit the owner's env; client env (token,
  proxies) is not forwarded.
- **Existing `hf` installs.** `setup.sh` leaves a non-dangling `hf` symlink
  alone; check `command -v hf` before debugging version issues.
- **Test PTY size.** `tests/test_queue.py` sets 100×30 on the slave PTY;
  without it the display clamps to 20×8 and header assertions truncate.

## Next steps

1. **Configurator phase 1** (no network): `parse_target()`,
   `build_download_argv()`, `pick` dispatch, `--all`, `--local-dir`,
   `--revision`, `--dry-run`; defer owner acquisition until after argv
   construction. Table tests.
2. **Phase 2**: stdlib Hub tree listing with auth, pagination, error mapping,
   `QHF_API_BASE` fixture override. Consider pinning the returned `sha`.
3. **Phase 3**: line-mode selector, destination/revision prompts, include
   construction; then the optional curses skin.
4. **Phase 4**: directory-prefix collapsing, argv guard, protocol `label`,
   shell completion.
5. Keep `qhf download ...` untouched throughout.

Acceptance criteria and risks: [`plan-configurator.md`](plan-configurator.md).

## Gates before a PR/push

- `python3 -m py_compile qhf`
- `python3 -m unittest discover -s tests -v` (all green)
- CI green on Python 3.10 and 3.12 (`.github/workflows/ci.yml`)
- No third-party imports in `qhf`
- Protocol or display changes reflected in `docs/design.md`
- README/CONTEXT/handover updated if behaviour or state changed
- Manual TTY smoke for display/PTY changes; non-TTY smoke for log changes
