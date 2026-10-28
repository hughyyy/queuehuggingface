#!/usr/bin/env bash
# setup.sh - provision hfq: a venv for the wrapped HF CLI, links on PATH.
#
# Idempotent. Re-run after upgrading Python or to refresh huggingface_hub.
# Overrides: HFQ_VENV, HFQ_BIN_DIR, PYTHON.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
VENV_DIR="${HFQ_VENV:-$REPO_DIR/.venv}"
BIN_DIR="${HFQ_BIN_DIR:-${HOME:?HOME is not set}/.local/bin}"
PYTHON="${PYTHON:-python3}"

say() { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die() { printf 'setup: %s\n' "$*" >&2; exit 1; }

say "hfq setup"
note "repo: $REPO_DIR"
note "venv: $VENV_DIR"
note "bin:  $BIN_DIR"

command -v "$PYTHON" >/dev/null 2>&1 || die "$PYTHON not found"

# 1. Virtual environment for the wrapped CLI. hfq itself needs only stdlib.
if [ ! -x "$VENV_DIR/bin/python" ]; then
    note "creating virtual environment"
    "$PYTHON" -m venv "$VENV_DIR" || die "could not create $VENV_DIR"
else
    note "reusing existing virtual environment"
fi

# 2. Install/refresh the Hugging Face CLI inside the venv.
note "installing/updating huggingface_hub (provides the hf CLI)"
"$VENV_DIR/bin/python" -m pip install \
    --disable-pip-version-check --no-input --upgrade huggingface_hub \
    || die "pip install failed"

if [ ! -x "$VENV_DIR/bin/hf" ]; then
    die "$VENV_DIR/bin/hf was not installed"
fi

hf_version="$("$VENV_DIR/bin/hf" --version 2>/dev/null | head -n 1 || true)"
note "hf installed${hf_version:+: $hf_version}"

# 3. Put hfq (and hf, when it does not collide) on PATH.
mkdir -p "$BIN_DIR" || die "cannot create $BIN_DIR"

link_into_bin() {
    src=$1
    name=$2
    dest="$BIN_DIR/$name"
    if [ -L "$dest" ]; then
        current="$(readlink -f -- "$dest" 2>/dev/null || true)"
        target="$(readlink -f -- "$src" 2>/dev/null || printf '%s' "$src")"
        if [ "$current" = "$target" ]; then
            note "$name: already linked to $src"
            return 0
        fi
        note "WARNING: $dest -> ${current:-?} (not ours); leaving it"
        return 1
    fi
    if [ -e "$dest" ]; then
        note "WARNING: $dest exists and is not a symlink; leaving it"
        return 1
    fi
    ln -s -- "$src" "$dest"
    note "$name -> $src"
    return 0
}

if ! link_into_bin "$VENV_DIR/bin/hf" hf; then
    note "hfq will use the existing hf: $(command -v hf 2>/dev/null || echo none)"
fi

link_into_bin "$REPO_DIR/hfq" hfq || die "could not link hfq into $BIN_DIR"

PATH="$BIN_DIR:$PATH" command -v hf >/dev/null 2>&1 \
    || die "hf is not resolvable from $BIN_DIR"

# 4. Make sure a new shell sees BIN_DIR. Only edit shell config when needed.
case ":${PATH:-}:" in
    *":$BIN_DIR:"*)
        note "PATH already includes $BIN_DIR"
        ;;
    *)
        shell_name="$(basename -- "${SHELL:-bash}")"
        case "$shell_name" in
            fish)
                conf="$HOME/.config/fish/conf.d/hfq.fish"
                mkdir -p -- "$(dirname -- "$conf")"
                if [ ! -e "$conf" ]; then
                    {
                        printf '# added by hfq setup.sh\n'
                        printf 'contains -- %s $PATH; or fish_add_path --global %s\n' \
                            "$BIN_DIR" "$BIN_DIR"
                    } >"$conf"
                    note "added $conf"
                else
                    note "WARNING: $conf exists; leaving it"
                fi
                ;;
            *)
                case "$shell_name" in
                    zsh) rc="$HOME/.zshrc" ;;
                    *) rc="$HOME/.bashrc" ;;
                esac
                touch "$rc"
                if ! grep -qF '# >>> hfq setup >>>' "$rc" 2>/dev/null; then
                    {
                        printf '\n# >>> hfq setup >>>\n'
                        printf 'case ":$PATH:" in *":%s:"*) ;; *) export PATH="%s:$PATH" ;; esac\n' \
                            "$BIN_DIR" "$BIN_DIR"
                        printf '# <<< hfq setup <<<\n'
                    } >>"$rc"
                    note "appended PATH block to $rc"
                else
                    note "$rc already has the hfq PATH block"
                fi
                ;;
        esac
        note "open a new terminal (or restart the shell) to pick up $BIN_DIR"
        ;;
esac

# 5. Verify from a PATH that starts with BIN_DIR.
PATH="$BIN_DIR:$PATH" command -v hfq >/dev/null 2>&1 || die "hfq is not resolvable"
"$BIN_DIR/hfq" --help >/dev/null || die "$BIN_DIR/hfq --help failed"

say
say "ready"
note "hfq: $BIN_DIR/hfq"
note "hf:  $(PATH="$BIN_DIR:$PATH" command -v hf)"
say
say "  hfq download <repo> [hf options]"
say
say "The first invocation owns the queue; later invocations enqueue and exit."
say "The venv only supplies the wrapped hf CLI; hfq itself is stdlib-only."
