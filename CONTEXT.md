# Context — QueueHuggingFace (`qhf`)

As of 2026-11-07. Product docs: [`README.md`](README.md). Internals:
[`docs/design.md`](docs/design.md). Current state: `docs/handover.md`.

## Problem

`hf download` has no queue. Running several downloads at once splits the link
and interleaves output. `qhf` serialises them into one visible FIFO without
replacing the CLI's transfer engine, authentication, caching, or retries.

The command name is the UX: type `q`, complete to `qhf`, paste a repo.

## Terms

| Term | Meaning |
|------|---------|
| **Owner** | The single `qhf` process holding the runtime lock. It accepts queue requests, runs one `hf` child at a time, and renders the display. |
| **Client** | Any other `qhf` process. Sends one request over the socket, prints a receipt, exits. |
| **Item** | One queued command: `argv` (everything after `qhf`) plus the invoking `cwd`. |
| **Active item** | The item whose `hf` child is currently running; first entry in the display. |
| **Pending** | Items behind the active one, in arrival order, held only in memory. |
| **Queue** | The in-memory `list[Item]` plus the active item. No persistence. |
| **Pass-through** | `qhf <args>` ≡ queued `hf <args>`. No parsing or prompts. |
| **Configurator / picker** | Planned mode that lists a repo's files, lets the user select a subset and destination, then builds one `hf download` command client-side. Not implemented. |
| **Runtime directory** | `$QHF_RUNTIME_DIR`, else `$XDG_RUNTIME_DIR/qhf`, else `/tmp/qhf-<uid>`; mode `0700`. |
| **Owner protocol** | One JSON line over an AF_UNIX stream: request `{argv, cwd}`; replies `{ok, pending}`, `{ok:false, retry:true}`, or an error. |
| **Label** | Proposed display-only string for a long constructed command (protocol v2). The executed argv never changes. |
| **`hf`** | The external Hugging Face CLI, resolved from `PATH` at runtime. Never imported by `qhf`. |
| **PTY mode** | Owner stdout is a TTY: the child runs on a PTY and its bytes are forwarded into a scroll region below the header. |
| **Log mode** | Owner stdout is not a TTY: header printed once, plain `queued:` / `running:` lines, raw child output. |

## System boundaries

- `qhf` is a queue and a display. It does **not** implement transfers,
  authentication, resumption, hashing, or CDN logic.
- `hf` owns those concerns. `qhf` only chooses the working directory,
  environment, and moment to run it.
- The executable is Python stdlib only. The `.venv` provisioned by
  `setup.sh` supplies `hf` when the machine has no CLI; `qhf` never imports
  its packages.
- The planned picker uses the public Hub tree HTTP API for **read-only**
  listing. Transfers still run through `hf`.
- One owner per runtime directory. Clients are short-lived and never hold the
  lock while downloading.

## Invariants

- Exactly one owner: exclusive non-blocking `flock` on `qhf.lock`.
- FIFO; one child at a time; next starts immediately after the previous is
  reaped.
- Clients block only for the ack, then exit.
- Only the owner's main thread writes the TTY; the socket thread appends to
  the queue under `q_lock` and wakes the main loop.
- The owner's argv is first in the queue; listener startup comes after that
  insert.
- Client `cwd` is preserved per item; the owner's environment is shared.
- The queue is in-memory; owner exit loses pending work.
- `qhf download ...` remains a byte-for-byte pass-through.
- Runtime files are per-user: directory `0700`, socket `0600`.
- Display bookkeeping must recover the stream cursor after header redraws;
  see the CSI-r note in `AGENTS.md`.

## Current state

| Area | State |
|------|-------|
| Queue/owner/client | working, tested |
| TTY display + PTY forwarding | working, tested |
| Non-TTY log mode | working, tested |
| Setup script + venv + PATH links | working |
| Real CLI download | verified 2026-11-07 (`hf` 2.4.0, tiny test model) |
| Configurator | **not implemented** — plan in `docs/plan-configurator.md` |

## Environment as of 2026-11-07

- [V] Development host: Linux, Python 3.14, fish shell, `~/.local/bin`
  already on `PATH`.
- [V] A pre-existing `hf` 2.0+ install resolves from `~/.local/bin/hf`; the
  setup script installs a venv fallback but does not replace that symlink.
- [V] Remote: `github.com/hughyyy/queuehuggingface` (public), branch `main`.
- [V] The Hub tree API response shape and pagination were checked against a
  live public repo; see the plan doc.

## Open decisions

- Picker UI: line-oriented selector first, optional curses tree.
- Whether listing pins to the resolved commit SHA to avoid a branch race.
- Display label (protocol v2) for long `--include` lists.
- Directory-glob collapse for large selections, after verifying `hf`'s
  include semantics.
- Single-file executable vs. a split stdlib package if the picker grows it
  past ~1200 lines.
