#!/bin/bash
set -u
umask 022   # fixture modes must not depend on the contributor's umask

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/script/mint-setup.sh"
OUT="${NATIVE_ZENITY_OUT:-${TMPDIR:-/tmp}/mint-setup-native-zenity-results}"
SCREEN_W="${NATIVE_ZENITY_SCREEN_W:-1280}"
SCREEN_H="${NATIVE_ZENITY_SCREEN_H:-900}"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }
skip() { printf 'SKIP: %s\n' "$1"; exit 77; }

run_in_container() {
    local runtime="$1"
    local image="${NATIVE_ZENITY_IMAGE:-ubuntu:24.04}"
    local host_out command
    # Absolute (a relative path would be a named volume) and outside the working tree, like $OUT.
    mkdir -p "$OUT" && host_out=$(CDPATH='' cd -- "$OUT" && pwd) || return 1
    command='apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bash ca-certificates locales python3 zenity xvfb xdotool x11-utils imagemagick tesseract-ocr tesseract-ocr-spa dbus-x11 fonts-dejavu-core fonts-noto-color-emoji language-pack-gnome-es-base && printf "en_US.UTF-8 UTF-8\\nes_ES.UTF-8 UTF-8\\n" > /etc/locale.gen && locale-gen >/dev/null && NATIVE_ZENITY_OUT=/out bash /workspace/tests/test-native-zenity.sh'
    if [ "$runtime" = docker ]; then
        docker run --rm --pull=missing \
            -e NATIVE_ZENITY_SCREEN_W="$SCREEN_W" -e NATIVE_ZENITY_SCREEN_H="$SCREEN_H" \
            -v "$ROOT:/workspace:ro" -v "$host_out:/out" -w /workspace "$image" bash -lc "$command"
    else
        podman run --rm --pull=missing \
            -e NATIVE_ZENITY_SCREEN_W="$SCREEN_W" -e NATIVE_ZENITY_SCREEN_H="$SCREEN_H" \
            -v "$ROOT:/workspace:ro" -v "$host_out:/out" -w /workspace "$image" bash -lc "$command"
    fi
}

case "${1:-}" in
    --container)
        if command -v docker >/dev/null 2>&1; then run_in_container docker; exit $?; fi
        if command -v podman >/dev/null 2>&1; then run_in_container podman; exit $?; fi
        skip "--container requested but neither Docker nor Podman is available."
        ;;
    --help|-h)
        printf '%s\n' "Usage: bash tests/test-native-zenity.sh [--container]"
        printf '%s\n' "Runs the real Zenity GUI under Xvfb and captures bilingual dialogs."
        printf '%s\n' "Captures go to NATIVE_ZENITY_OUT (default: ${TMPDIR:-/tmp}/mint-setup-native-zenity-results)."
        printf '%s\n' "Use NATIVE_ZENITY_IMAGE=linuxmintd/mint22.3-amd64 to override the container image."
        exit 0
        ;;
esac

command -v zenity >/dev/null 2>&1 || {
    if command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1; then
        skip "Zenity is not installed. Re-run with --container to execute the native suite in an Ubuntu 24.04 container."
    fi
    skip "Zenity is not installed and no container runtime is available."
}
command -v Xvfb >/dev/null 2>&1 || skip "Xvfb is required for the native headless GUI test."
command -v xdotool >/dev/null 2>&1 || skip "xdotool is required for native GUI interaction."
command -v import >/dev/null 2>&1 || skip "ImageMagick 'import' is required for native GUI screenshots."
command -v identify >/dev/null 2>&1 || skip "ImageMagick 'identify' is required for screenshot checks."
command -v python3 >/dev/null 2>&1 || skip "Python 3 is required for native screenshot checks."
command -v xprop >/dev/null 2>&1 || skip "xprop is required for native Zenity window checks."
command -v tesseract >/dev/null 2>&1 || skip "Tesseract OCR is required for native rendered-text checks."
locale -a 2>/dev/null | grep -qx 'en_US.utf8' || skip "en_US.UTF-8 locale is required for the native English run."
locale -a 2>/dev/null | grep -qx 'es_ES.utf8' || skip "es_ES.UTF-8 locale is required for the native Spanish run."

mkdir -p "$OUT"
rm -f "$OUT"/*
TMP=$(mktemp -d)
XVFB_PID=""
trap 'if [ -n "$XVFB_PID" ]; then kill "$XVFB_PID" 2>/dev/null || true; fi; rm -rf "$TMP"' EXIT

DISPLAY_NUM=99
while [ -e "/tmp/.X${DISPLAY_NUM}-lock" ]; do DISPLAY_NUM=$((DISPLAY_NUM + 1)); done
export DISPLAY=":$DISPLAY_NUM"
export GDK_BACKEND=x11
export XDG_CURRENT_DESKTOP=Cinnamon
export XDG_SESSION_TYPE=x11
export GDK_DPI_SCALE=1
export GSK_RENDERER=cairo   # GTK4 Zenity: software rendering, capturable under Xvfb
if [ -n "${NATIVE_ZENITY_GTK_THEME:-}" ]; then export GTK_THEME="$NATIVE_ZENITY_GTK_THEME"; else unset GTK_THEME 2>/dev/null || true; fi
export XDG_RUNTIME_DIR="$TMP/xdg-runtime"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

Xvfb "$DISPLAY" -screen 0 "${SCREEN_W}x${SCREEN_H}x24" -nolisten tcp >/dev/null 2>&1 &
XVFB_PID=$!
sleep 1
kill -0 "$XVFB_PID" 2>/dev/null || fail "Xvfb failed to start"

wait_for_window() {
    local title="$1" wid=""
    for _ in $(seq 1 100); do
        wid=$(xdotool search --onlyvisible --name "$title" 2>/dev/null | head -1 || true)
        [ -n "$wid" ] && { printf '%s\n' "$wid"; return 0; }
        sleep 0.1
    done
    return 1
}

capture_window() {
    local wid="$1" name="$2" min_width="$3" min_height="$4" geom width height entropy
    local img="$OUT/$name.png"
    xdotool windowactivate --sync "$wid" 2>/dev/null || true
    geom=$(xdotool getwindowgeometry --shell "$wid" 2>/dev/null) || fail "$name geometry unavailable"
    printf '%s\n' "$geom" > "$OUT/$name.geometry"
    xprop -id "$wid" WM_CLASS WM_NAME _NET_WM_WINDOW_TYPE > "$OUT/$name.xprop" 2>/dev/null || fail "$name X11 properties unavailable"
    # GTK3 Zenity reports class "Zenity" and a DIALOG window type; GTK4 Zenity
    # (4.x, Mint 22 / Ubuntu 24.04) reports "zenity" and a NORMAL toplevel.
    grep -Eiq 'WM_CLASS.*"zenity", "zenity"' "$OUT/$name.xprop" || fail "$name is not a real Zenity window"
    grep -Eq '_NET_WM_WINDOW_TYPE_(DIALOG|NORMAL)' "$OUT/$name.xprop" || fail "$name has no X11 toplevel window type"
    import -window "$wid" "$img" >/dev/null 2>&1 || fail "$name screenshot failed"
    [ -s "$img" ] || fail "$name screenshot is empty"
    width=$(awk -F= '$1=="WIDTH"{print $2}' <<<"$geom")
    height=$(awk -F= '$1=="HEIGHT"{print $2}' <<<"$geom")
    [ "${width:-0}" -ge "$min_width" ] || fail "$name window too narrow (${width:-0}, expected >= $min_width)"
    [ "${height:-0}" -ge "$min_height" ] || fail "$name window too short (${height:-0}, expected >= $min_height)"
    entropy=$(identify -format '%[entropy]' "$img" 2>/dev/null || printf '0')
    python3 - "$entropy" <<'PY' || fail "$name screenshot has insufficient visual content"
import sys
assert float(sys.argv[1]) > 0.05
PY
}

run_function_dialog() {
    local name="$1" lang="$2" function_name="$3" title="$4" locale="$5"
    local home="$TMP/home-$name-$lang" cfg="$TMP/cfg-$name-$lang" backups="$TMP/backups-$name-$lang"
    local pid wid
    mkdir -p "$home" "$cfg" "$backups"
    if [ "$function_name" = do_restore ]; then
        mkdir -p "$backups/demo/terminal"
        printf 'NAME=Native test\nDATE=2026-09-10\n' > "$backups/demo/manifest.conf"
        : > "$backups/demo/terminal/.bashrc"
    fi
    HOME="$home" XDG_CONFIG_HOME="$cfg" MINT_SETUP_BACKUPS_DIR="$backups" MINT_SETUP_TEST=1 LC_ALL="$locale" \
        bash -c 'source "$1"; set_language "$2"; "$3"' _ "$SCRIPT" "$lang" "$function_name" >/dev/null 2>&1 &
    pid=$!
    wid=$(wait_for_window "$title") || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fail "$lang $name dialog did not appear"; }
    case "$name" in
        main) capture_window "$wid" "$name-$lang" 440 340 ;;
        save) capture_window "$wid" "$name-$lang" 700 500 ;;
        advanced|advanced-xlocale) capture_window "$wid" "$name-$lang" 460 380 ;;
        *) capture_window "$wid" "$name-$lang" 320 220 ;;
    esac
    xdotool key Escape
    wait "$pid" 2>/dev/null || true
    pass "native Zenity $lang $name"
}

native_text_check() {
    local image="$1" lang="$2" needle="$3"
    command -v tesseract >/dev/null 2>&1 || return 0
    local ocr_lang=eng
    [ "$lang" = es ] && ocr_lang=spa
    local text out_name
    out_name="$OUT/$(basename "$image" .png).ocr.txt"
    # One line without trailing whitespace: tests/lint.sh rejects a .txt that has it.
    text=$(tesseract "$image" stdout -l "$ocr_lang" --psm 6 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)
    printf '%s\n' "$text" > "$out_name"
    case "$text" in
        *"$needle"*) ;;
        *) fail "native rendered text missing in $image: $needle" ;;
    esac
}

version=$(zenity --version 2>/dev/null || true)
[ -n "$version" ] || fail "native Zenity did not report a version"
printf '%s\n' "$version" > "$OUT/zenity-version.txt"

# Actual bilingual dialogs, using the real Zenity process and real locale.
run_function_dialog main en main_menu 'Mint-Setup' en_US.UTF-8
run_function_dialog main es main_menu 'Mint-Setup' es_ES.UTF-8
run_function_dialog save en do_save 'Mint-Setup - Save' en_US.UTF-8
run_function_dialog save es do_save 'Mint-Setup - Guardar' es_ES.UTF-8
run_function_dialog advanced en do_advanced 'Mint-Setup - Advanced settings' en_US.UTF-8
run_function_dialog advanced es do_advanced 'Mint-Setup - Avanzado' es_ES.UTF-8

# The language of the program decides the text of its own dialogs, not the system
# locale: the program in Spanish on an English system and in English on a Spanish one.
# A dialog without --text shows the text zenity writes itself, translated with the system
# locale, so only a system language whose zenity catalog is installed can show the
# defect (Ubuntu keeps it in a language pack: language-pack-gnome-es-base).
zenity_spanish_catalog() { compgen -G '/usr/share/locale*/es*/LC_MESSAGES/zenity.mo' >/dev/null; }
run_function_dialog advanced-xlocale es do_advanced 'Mint-Setup - Avanzado' en_US.UTF-8
xlocale_en=0
if zenity_spanish_catalog; then
    run_function_dialog advanced-xlocale en do_advanced 'Mint-Setup - Advanced settings' es_ES.UTF-8
    xlocale_en=1
else
    printf 'SKIP: native English-on-Spanish run (no Spanish zenity catalog installed: on Ubuntu, language-pack-gnome-es-base)\n'
fi

# Restore picker and the real checklist are two separate native dialogs.
for lang in en es; do
    local_locale=en_US.UTF-8; [ "$lang" = es ] && local_locale=es_ES.UTF-8
    home="$TMP/home-restore-$lang"; cfg="$TMP/cfg-restore-$lang"; backups="$TMP/backups-restore-$lang"
    mkdir -p "$home" "$cfg" "$backups/demo/terminal"
    printf 'NAME=Native test\nDATE=2026-09-10\n' > "$backups/demo/manifest.conf"
    : > "$backups/demo/terminal/.bashrc"
    HOME="$home" XDG_CONFIG_HOME="$cfg" MINT_SETUP_BACKUPS_DIR="$backups" MINT_SETUP_TEST=1 LC_ALL="$local_locale" \
        bash -c 'source "$1"; set_language "$2"; do_restore' _ "$SCRIPT" "$lang" >/dev/null 2>&1 &
    pid=$!
    title="Mint-Setup - Restore"; [ "$lang" = es ] && title="Mint-Setup - Restaurar"
    wid=$(wait_for_window "$title") || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fail "$lang restore picker did not appear"; }
    capture_window "$wid" "restore-picker-$lang" 520 360
    xdotool key Return
    # The checklist is a larger window; GTK4 may reuse the picker's X11 id, so
    # detect it by size instead of by a different window id.
    checklist=""
    for _ in $(seq 1 100); do
        cand=$(xdotool search --onlyvisible --name "$title" 2>/dev/null | tail -1 || true)
        if [ -n "$cand" ]; then
            cand_w=$(xdotool getwindowgeometry --shell "$cand" 2>/dev/null | awk -F= '$1=="WIDTH"{print $2}')
            if [ "${cand_w:-0}" -ge 700 ]; then checklist="$cand"; break; fi
        fi
        sleep 0.1
    done
    [ -n "$checklist" ] || fail "$lang restore checklist did not appear"
    capture_window "$checklist" "restore-checklist-$lang" 700 500
    xdotool key Escape
    wait "$pid" 2>/dev/null || true
    pass "native Zenity $lang restore picker + checklist"
done

# The confirmation of a full restore (12.55). The real do_restore builds its text and the real
# confirm() shows it; only the picker and the checklist are answered by a stand-in, so the dialog is
# reached without clicking. The OCR reads a "\n" shown literally as a backslash followed by an n.
for lang in en es; do
    local_locale=en_US.UTF-8; [ "$lang" = es ] && local_locale=es_ES.UTF-8
    home="$TMP/home-confirm-$lang"; cfg="$TMP/cfg-confirm-$lang"; backups="$TMP/backups-confirm-$lang"
    mkdir -p "$home" "$cfg" "$backups/demo/terminal"
    printf 'NAME=Native test\nDATE=2026-09-10\n' > "$backups/demo/manifest.conf"
    : > "$backups/demo/terminal/.bashrc"
    HOME="$home" XDG_CONFIG_HOME="$cfg" MINT_SETUP_BACKUPS_DIR="$backups" MINT_SETUP_TEST=1 LC_ALL="$local_locale" \
        PICKED_BACKUP="$backups/demo" bash -c 'source "$1"; set_language "$2"
pick_backup_dir() { printf "%s\n" "$PICKED_BACKUP"; }
zenity() { case "$*" in *--list*) printf "terminal\n" ;; *) command zenity "$@" ;; esac; }
do_restore' _ "$SCRIPT" "$lang" >/dev/null 2>&1 &
    pid=$!
    wid=$(wait_for_window 'Mint-Setup') || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fail "$lang restore confirmation did not appear"; }
    capture_window "$wid" "restore-confirm-$lang" 320 220
    xdotool key Escape
    wait "$pid" 2>/dev/null || true
    pass "native Zenity $lang restore confirmation"
done

# Actual locale detection: no set_language override, locale alone must decide.
for lang in en es; do
    locale=en_US.UTF-8; [ "$lang" = es ] && locale=es_ES.UTF-8
    home="$TMP/home-autodetect-$lang"; cfg="$TMP/cfg-autodetect-$lang"; backups="$TMP/backups-autodetect-$lang"
    mkdir -p "$home" "$cfg" "$backups"
    HOME="$home" XDG_CONFIG_HOME="$cfg" MINT_SETUP_BACKUPS_DIR="$backups" MINT_SETUP_TEST=1 LC_ALL="$locale" \
        bash -c 'source "$1"; main_menu' _ "$SCRIPT" >/dev/null 2>&1 &
    pid=$!
    wid=$(wait_for_window 'Mint-Setup') || fail "$lang native locale detection menu did not appear"
    capture_window "$wid" "autodetect-$lang" 440 340
    xdotool key Escape
    wait "$pid" 2>/dev/null || true
    pass "native Zenity locale detection $lang"
done

# Native UI text checks use OCR only when tesseract is available in the test environment.
native_text_check "$OUT/main-en.png" en 'What do you want to do?'
native_text_check "$OUT/main-es.png" es 'Qué deseas hacer'
native_text_check "$OUT/main-en.png" en 'Change language'
native_text_check "$OUT/main-es.png" es 'Cambiar idioma'
native_text_check "$OUT/save-en.png" en 'What do you want to save?'
native_text_check "$OUT/save-es.png" es '¿Qué deseas guardar?'
native_text_check "$OUT/advanced-en.png" en 'Advanced settings'
native_text_check "$OUT/advanced-es.png" es 'Avanzado'
native_text_check "$OUT/advanced-xlocale-es.png" es 'Qué deseas hacer'
if [ "$xlocale_en" -eq 1 ]; then native_text_check "$OUT/advanced-xlocale-en.png" en 'What do you want to do?'; fi
native_text_check "$OUT/restore-checklist-en.png" en 'Restore'
native_text_check "$OUT/restore-checklist-es.png" es 'Restaurar'
native_text_check "$OUT/restore-checklist-en.png" en 'Terminal'
native_text_check "$OUT/restore-checklist-es.png" es 'Terminal'
native_text_check "$OUT/restore-confirm-en.png" en 'You are about to restore ALL modules'
native_text_check "$OUT/restore-confirm-es.png" es 'Vas a restaurar TODOS'
for img in restore-confirm-en restore-confirm-es; do
    if [ -f "$OUT/$img.ocr.txt" ] && grep -Fq '\n' "$OUT/$img.ocr.txt"; then
        fail "$img shows a literal \\n in the dialog text: $(cat "$OUT/$img.ocr.txt")"
    fi
done
native_text_check "$OUT/autodetect-en.png" en 'What do you want to do?'
native_text_check "$OUT/autodetect-es.png" es 'Qué deseas hacer'

# Real GUI language toggle: select the final L row and confirm the redraw.
home="$TMP/home-toggle"; cfg="$TMP/cfg-toggle"; backups="$TMP/backups-toggle"
mkdir -p "$home" "$cfg" "$backups"
HOME="$home" XDG_CONFIG_HOME="$cfg" MINT_SETUP_BACKUPS_DIR="$backups" MINT_SETUP_TEST=1 LC_ALL=en_US.UTF-8 \
    bash -c 'source "$1"; set_language en; main_menu' _ "$SCRIPT" >/dev/null 2>&1 &
pid=$!
wid=$(wait_for_window 'Mint-Setup') || fail 'native language-toggle menu did not appear'
capture_window "$wid" toggle-before-en 440 340
xdotool windowactivate --sync "$wid" 2>/dev/null || true
xdotool key End
sleep 0.15
xdotool key Return
for _ in $(seq 1 100); do
    wid2=$(xdotool search --onlyvisible --name 'Mint-Setup' 2>/dev/null | head -1 || true)
    [ -n "$wid2" ] && break
    sleep 0.1
done
[ -f "$cfg/mint-setup/language" ] || fail 'native language toggle did not persist a language setting'
[ "$(cat "$cfg/mint-setup/language")" = es ] || fail 'native language toggle did not switch en to es'
capture_window "$wid2" toggle-after-es 440 340
native_text_check "$OUT/toggle-after-es.png" es 'Qué deseas hacer'
xdotool key Escape
wait "$pid" 2>/dev/null || true
pass 'native Zenity language toggle en -> es'

# lint.sh rejects trailing whitespace in any .txt, so the captures must pass it wherever NATIVE_ZENITY_OUT points.
bad_ocr=$(grep -lE '[[:space:]]$' "$OUT"/*.ocr.txt 2>/dev/null || true)
[ -z "$bad_ocr" ] || fail "OCR text ends in whitespace: $bad_ocr"
pass 'native OCR captures have no trailing whitespace'

cat > "$OUT/native-report.txt" <<REPORT
Zenity: $version
Display: $DISPLAY
Screen: ${SCREEN_W}x${SCREEN_H}
Locale tests: en_US.UTF-8, es_ES.UTF-8
Backend: GTK/Zenity under Xvfb
OCR: $(command -v tesseract >/dev/null 2>&1 && echo enabled || echo unavailable)
REPORT

printf 'Native Zenity suite completed with Zenity %s. Screenshots and geometry: %s\n' "$version" "$OUT"
