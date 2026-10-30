#!/bin/bash
# Shared helpers for the Mint-Setup test suites. Source it, do not run it:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#   ms_init
#   ok "description" test -f "$HOME_DIR/file"
#   ms_finish
#
# ms_init builds an isolated sandbox (HOME, XDG_CONFIG_HOME, backups, stub
# commands first in PATH, no display/D-Bus) so a suite can never touch the real
# user environment or open a real dialog. Everything is removed on exit.
#
# Provided variables: ROOT SCRIPT TMP MOCK HOME_DIR CFG BACKUPS ZEN
# Provided functions: ok fail pass skip_suite ms_init ms_finish ms_app ms_lib
#                     ms_tree ms_stub

# shellcheck shell=bash
# shellcheck disable=SC2016  # stub bodies and bash -c payloads are intentionally single-quoted

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/script/mint-setup.sh"
SAFE_PATH="/usr/bin:/bin"
PASSES=0
FAILURES=0

pass() { PASSES=$((PASSES + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAILURES=$((FAILURES + 1)); printf 'FAIL: %s\n' "$1" >&2; }

# ok "description" command [args...]  -> PASS when the command succeeds.
ok() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# skip_suite "reason" -> exit 77 (SKIP for tests/run.sh).
skip_suite() { printf 'SKIP: %s\n' "$1"; exit 77; }

ms_cleanup() { [ -n "${TMP:-}" ] || return 0; chmod -R u+rwX -- "$TMP" 2>/dev/null; rm -rf -- "$TMP"; }   # a test may leave read-only folders

# ms_stub NAME [BODY]: create an executable stub in $MOCK. Without BODY the
# stub just exits 0. The body is a /bin/sh script.
ms_stub() {
    local name="$1" body="${2:-exit 0}"
    printf '#!/bin/sh\n%s\n' "$body" > "$MOCK/$name"
    chmod +x "$MOCK/$name"
}

ms_init() {
    TMP=$(mktemp -d) || { echo "FAIL: cannot create temp dir" >&2; exit 1; }
    trap ms_cleanup EXIT
    MOCK="$TMP/bin"; HOME_DIR="$TMP/home"; CFG="$TMP/config"; BACKUPS="$TMP/backups"
    ZEN="$TMP/zenity"
    mkdir -p "$MOCK" "$HOME_DIR/.config" "$CFG" "$BACKUPS" "$ZEN"

    # `id -u` reports an unprivileged user so the root guard never fires when
    # the suite itself runs as root (CI containers, local sudo).
    ms_stub id '[ "${1:-}" = "-u" ] && { echo "${MS_FAKE_UID:-1000}"; exit 0; }
exec /usr/bin/id "$@"'

    # Scripted zenity. Every call is appended to $ZENITY_CAPTURE/calls.
    # Answers: ZENITY_LIST_CHOICES (one line per --list call, in order),
    # ZENITY_ENTRY, ZENITY_QUESTION_RC, ZENITY_FILE. Dialog texts are appended
    # to texts; a text that would break Pango markup (a lone & or <) and was not
    # protected with --no-markup is appended to markup-issues.
    ms_stub zenity '
out=${ZENITY_CAPTURE:?}; mkdir -p "$out"
n=0; [ -f "$out/index" ] && n=$(cat "$out/index"); n=$((n + 1)); printf "%s\n" "$n" > "$out/index"
printf "%s\n" "$*" >> "$out/calls"
text=""; nomarkup=0
for a in "$@"; do
    case "$a" in
        --text=*) text=${a#--text=} ;;
        --no-markup) nomarkup=1 ;;
    esac
done
if [ -n "$text" ]; then
    printf "%s\n---\n" "$text" >> "$out/texts"
    parses=1; honors=0
    case "$*" in *--entry*) parses=0 ;; esac
    case "$*" in *--info*|*--error*|*--warning*|*--question*) honors=1 ;; esac
    if [ "$parses" -eq 1 ] && { [ "$nomarkup" -eq 0 ] || [ "$honors" -eq 0 ]; }; then
        stripped=$(printf "%s" "$text" | sed -e "s@</\?b>@@g" -e "s@&\(amp\|lt\|gt\|quot\|apos\|#[0-9]\+\);@@g")
        case "$stripped" in *"&"*|*"<"*) printf "%s\n" "$text" >> "$out/markup-issues" ;; esac
    fi
fi
case "$*" in
    *--list*) choice=$(printf "%s" "${ZENITY_LIST_CHOICES:-}" | sed -n "${n}p"); [ -n "$choice" ] && printf "%s\n" "$choice"; exit 0 ;;
    *--entry*) printf "%s\n" "${ZENITY_ENTRY:-}"; exit 0 ;;
    *--file-selection*) [ -n "${ZENITY_FILE:-}" ] && printf "%s\n" "$ZENITY_FILE"; exit 0 ;;
    *--question*) exit "${ZENITY_QUESTION_RC:-0}" ;;
    *--progress*) cat >/dev/null; exit 0 ;;
esac
exit 0'

    # Commands the program calls that must never reach the real system.
    local c
    for c in dconf gsettings apt-get apt-mark apt-cache pkexec gio pgrep code flatpak pactl \
             fc-cache xdg-user-dir xdg-open systemctl update-desktop-database \
             gtk-update-icon-cache notify-send; do
        ms_stub "$c"
    done
    ms_stub iconv 'exec /usr/bin/iconv "$@"'

    # Clean, deterministic environment shared by ms_app / ms_lib.
    MS_ENV=(env -u DISPLAY -u WAYLAND_DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u XDG_RUNTIME_DIR
        -u XDG_DATA_HOME -u XDG_CACHE_HOME -u XDG_STATE_HOME -u XDG_DATA_DIRS
        HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS"
        PATH="$MOCK:$SAFE_PATH" LC_ALL=C.UTF-8 ZENITY_CAPTURE="$ZEN")
}

# ms_env_set NAME VALUE: override a variable for every later ms_app / ms_lib call.
ms_env_set() { MS_ENV+=("$1=$2"); }

# ms_app [args...]: run the program itself inside the sandbox.
ms_app() { "${MS_ENV[@]}" bash "$SCRIPT" "$@"; }

# ms_lib 'code' [args...]: source the program as a library (MINT_SETUP_TEST=1)
# and run `code`; extra arguments become $1, $2... of that code.
ms_lib() {
    local code="$1"
    shift
    "${MS_ENV[@]}" MINT_SETUP_TEST=1 bash -c 'source "$1" || exit 98; declare -F ms_commit >/dev/null || exit 99
code=$2; shift 2; eval "$code"' _ "$SCRIPT" "$code" "$@"
}

# ms_tree DIR: stable listing (path, type, mode) used for before/after comparisons.
ms_tree() { [ -e "$1" ] && (cd "$1" && find . -printf '%p %y %m\n' | LC_ALL=C sort); true; }

ms_finish() {
    printf '\n%s: %d passed, %d failed\n' "$(basename -- "${0:-suite}")" "$PASSES" "$FAILURES"
    [ "$FAILURES" -eq 0 ]
    exit $?
}
