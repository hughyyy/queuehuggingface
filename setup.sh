#!/usr/bin/env bash
# setup.sh - provision qhf: a venv for the wrapped HF CLI, links on PATH.
#
# Idempotent. Re-run after upgrading Python or to refresh huggingface_hub.
# Overrides: QHF_VENV, QHF_BIN_DIR, PYTHON.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
VENV_DIR="${QHF_VENV:-$REPO_DIR/.venv}"
BIN_DIR="${QHF_BIN_DIR:-${HOME:?HOME is not set}/.local/bin}"
PYTHON="${PYTHON:-python3}"

say() { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die() { printf 'setup: %s\n' "$*" >&2; exit 1; }

say "qhf setup"
note "repo: $REPO_DIR"
note "venv: $VENV_DIR"
note "bin:  $BIN_DIR"

command -v "$PYTHON" >/dev/null 2>&1 || die "$PYTHON not found"

# 1. Virtual environment for the wrapped CLI. qhf itself needs only stdlib.
recreate_venv=0
if [ ! -x "$VENV_DIR/bin/python" ]; then
    recreate_venv=1
elif [ -e "$VENV_DIR/bin/hf" ]; then
    shebang="$(head -n 1 "$VENV_DIR/bin/hf" 2>/dev/null || true)"
    case "$shebang" in
        "#!$VENV_DIR/bin/python"*) ;;
        *)
            note "venv console scripts point at an old path; recreating"
            recreate_venv=1
            ;;
    esac
fi

if [ "$recreate_venv" = 1 ]; then
    rm -rf -- "$VENV_DIR"
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

# 3. Put qhf (and hf, when it does not collide) on PATH.
mkdir -p "$BIN_DIR" || die "cannot create $BIN_DIR"

link_into_bin() {
    src=$1
    name=$2
    dest="$BIN_DIR/$name"
    if [ -L "$dest" ] && [ ! -e "$dest" ]; then
        note "$name: replacing dangling link $(readlink -- "$dest" 2>/dev/null || true)"
        ln -sfn -- "$src" "$dest"
        return 0
    fi
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

legacy="$BIN_DIR/hfq"
if [ -L "$legacy" ] && [ ! -e "$legacy" ]; then
    target="$(readlink -- "$legacy" 2>/dev/null || true)"
    case "$target" in
        */hfq | */hfq/*)
            rm -f -- "$legacy"
            note "removed legacy link $legacy"
            ;;
    esac
fi

if ! link_into_bin "$VENV_DIR/bin/hf" hf; then
    note "qhf will use the existing hf: $(command -v hf 2>/dev/null || echo none)"
fi

link_into_bin "$REPO_DIR/qhf" qhf || die "could not link qhf into $BIN_DIR"

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
                conf="$HOME/.config/fish/conf.d/qhf.fish"
                mkdir -p -- "$(dirname -- "$conf")"
                if [ ! -e "$conf" ]; then
                    {
                        printf '# added by qhf setup.sh\n'
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
                if ! grep -qF '# >>> qhf setup >>>' "$rc" 2>/dev/null; then
                    {
                        printf '\n# >>> qhf setup >>>\n'
                        printf 'case ":$PATH:" in *":%s:"*) ;; *) export PATH="%s:$PATH" ;; esac\n' \
                            "$BIN_DIR" "$BIN_DIR"
                        printf '# <<< qhf setup <<<\n'
                    } >>"$rc"
                    note "appended PATH block to $rc"
                else
                    note "$rc already has the qhf PATH block"
                fi
                ;;
        esac
        note "open a new terminal (or restart the shell) to pick up $BIN_DIR"
        ;;
esac

# 5. Verify from a PATH that starts with BIN_DIR.
PATH="$BIN_DIR:$PATH" command -v qhf >/dev/null 2>&1 || die "qhf is not resolvable"
"$BIN_DIR/qhf" --help >/dev/null || die "$BIN_DIR/qhf --help failed"

say
say "ready"
note "qhf: $BIN_DIR/qhf"
note "hf:  $(PATH="$BIN_DIR:$PATH" command -v hf)"
say
say "  qhf download <repo> [hf options]"
say
say "The first invocation owns the queue; later invocations enqueue and exit."
say "The venv only supplies the wrapped hf CLI; qhf itself is stdlib-only."
