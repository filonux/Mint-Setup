#!/bin/bash
# Install / uninstall suite. Everything runs in a throw-away HOME; the central
# guarantee is "no trace": after an uninstall with --purge the sandbox is
# byte-for-byte what it was before the install.
# shellcheck disable=SC2016  # ms_lib payloads are intentionally single-quoted
set -u
umask 022   # fixture modes must not depend on the contributor's umask

# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
ms_init

BIN="$HOME_DIR/.local/bin/mint-setup"
ICON="$HOME_DIR/.local/share/icons/hicolor/256x256/apps/mint-setup.png"
DESKTOP="$HOME_DIR/.local/share/applications/mint-setup.desktop"
MANIFEST="$HOME_DIR/.local/share/mint-setup/install.manifest"
ICON_SHA=$(sed -n 's/^ICON_SHA256="\([0-9a-f]*\)"$/\1/p' "$SCRIPT")
mkdir -p "$HOME_DIR/.cache"
snap() { echo "[home]"; ms_tree "$HOME_DIR"; echo "[config]"; ms_tree "$CFG"; }
check_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected [$3], got [$2])"; fi; }
mode() { stat -c %a "$1" 2>/dev/null; }
png_size() { python3 -c 'import struct,sys; d=open(sys.argv[1],"rb").read(24); print(struct.unpack(">II", d[16:24]) if d[:8]==b"\x89PNG\r\n\x1a\n" else "not-png")' "$1"; }

# --- command line ------------------------------------------------------------
out=$(ms_app --help 2>&1); rc=$?
check_eq "--help exits 0" "$rc" 0
ok "--help documents --install and --uninstall" bash -c 'grep -q -- "--install" <<<"$1" && grep -q -- "--uninstall" <<<"$1"' _ "$out"
ok "--help is fully English in an English locale" bash -c '! grep -q "sin opciones\|abre el programa" <<<"$1" && grep -q "(no options)" <<<"$1"' _ "$out"
es_out=$("${MS_ENV[@]}" LC_ALL=es_ES.UTF-8 LANGUAGE=es bash "$SCRIPT" --help 2>&1)
ok "--help is Spanish in a Spanish locale" bash -c 'grep -q "(sin opciones)" <<<"$1" && ! grep -q "(no options)" <<<"$1"' _ "$es_out"
ms_app --bogus >/dev/null 2>&1; check_eq "unknown option exits 2" "$?" 2
ms_app --uninstall --purge --keep-config >/dev/null 2>&1; check_eq "--purge with --keep-config exits 2" "$?" 2
ms_app --purge >/dev/null 2>&1; check_eq "--purge without --uninstall exits 2" "$?" 2
check_eq "--version still works" "$(ms_app --version)" "Mint-Setup $(sed -n 's/^APP_VERSION="\(.*\)"$/\1/p' "$SCRIPT")"

# --- fresh install -------------------------------------------------------------
out=$(ms_app --install 2>&1); rc=$?
check_eq "install exits 0" "$rc" 0
ok "installed program is identical to the script" cmp -s "$SCRIPT" "$BIN"
check_eq "program mode is 755" "$(mode "$BIN")" 755
check_eq "launcher mode is 644" "$(mode "$DESKTOP")" 644
check_eq "icon mode is 644" "$(mode "$ICON")" 644
check_eq "manifest mode is 600" "$(mode "$MANIFEST")" 600
check_eq "icon is a 256x256 PNG" "$(png_size "$ICON")" "(256, 256)"
check_eq "icon matches the embedded checksum" "$(sha256sum "$ICON" | cut -d' ' -f1)" "$ICON_SHA"
ok "launcher points to the installed program" grep -Fxq "Exec=$BIN" "$DESKTOP"
ok "launcher uses the installed icon name" grep -Fxq 'Icon=mint-setup' "$DESKTOP"
ok "launcher carries the ownership marker" grep -Fxq 'X-MintSetup-Managed=true' "$DESKTOP"
if command -v desktop-file-validate >/dev/null 2>&1; then
    ok "launcher passes desktop-file-validate" desktop-file-validate "$DESKTOP"
else
    printf 'SKIP: launcher validation with desktop-file-validate (not installed: on Ubuntu, desktop-file-utils)\n'
fi
check_eq "installed copy runs" "$("$BIN" --version)" "Mint-Setup $(sed -n 's/^APP_VERSION="\(.*\)"$/\1/p' "$SCRIPT")"
ok "install left no temporary files" test -z "$(find "$HOME_DIR" -name '*.mstmp.*')"
ok "install output mentions completion" grep -Eq 'Installation complete' <<<"$out"

ok "install leaves nothing in ~/.cache (the lock folder is created lazily)" test ! -e "$HOME_DIR/.cache/mint-setup"

# Re-install is idempotent.
TREE1=$(snap)
ms_app --install >/dev/null 2>&1; check_eq "second install exits 0" "$?" 0
check_eq "re-install changes nothing" "$(snap)" "$TREE1"

# --- uninstall: protections ------------------------------------------------------
ms_app --uninstall </dev/null >/dev/null 2>&1; check_eq "non-interactive uninstall without --yes exits 2" "$?" 2
ok "…and removed nothing" test -f "$BIN"
printf 'n\n' | MINT_SETUP_FORCE_INTERACTIVE=1 ms_app --uninstall >/dev/null 2>&1
ok "answering no cancels the uninstall" test -f "$BIN"

printf '# edited by the user\n' >> "$DESKTOP"
out=$(ms_app --uninstall --yes 2>&1)
ok "a launcher edited by the user is kept" test -f "$DESKTOP"
ok "…and reported as kept" grep -Fq 'Kept (you modified it)' <<<"$out"
ok "the unmodified program was removed" test ! -e "$BIN"
rm -f "$DESKTOP"
rm -rf "$HOME_DIR/.local"

# A tampered manifest can never make the uninstaller delete outside HOME.
echo precious > "$TMP/outside.txt"
ms_app --install >/dev/null 2>&1
printf 'F %s %q\nF %s %q\n' "$(sha256sum "$TMP/outside.txt" | cut -d' ' -f1)" "$TMP/outside.txt" \
    "$(sha256sum "$TMP/outside.txt" | cut -d' ' -f1)" "$HOME_DIR/../outside.txt" >> "$MANIFEST"
ms_app --uninstall --yes >/dev/null 2>&1
ok "files outside HOME listed in the manifest are never removed" test -f "$TMP/outside.txt"
ok "the real files were still removed" test ! -e "$BIN"

# --- uninstall: keep configuration ---------------------------------------------------
rm -rf "$HOME_DIR/.local"
ms_app --install >/dev/null 2>&1
mkdir -p "$CFG/mint-setup" "$BACKUPS/Mi_copia" "$HOME_DIR/.cache/mint-setup"
printf 'es\n' > "$CFG/mint-setup/language"
printf 'NAME=x\nDATE=y\nMODULES=terminal\n' > "$BACKUPS/Mi_copia/manifest.conf"
: > "$HOME_DIR/.cache/mint-setup/.Mint-Setup-pkexec.lock"
out=$(ms_app --uninstall --yes 2>&1)
check_eq "uninstall --yes exits 0" "$?" 0
ok "program, icon, launcher and manifest are gone" test ! -e "$BIN" -a ! -e "$ICON" -a ! -e "$DESKTOP" -a ! -e "$MANIFEST"
ok "directories created by the install are gone" test ! -e "$HOME_DIR/.local"
ok "runtime lock directory is gone" test ! -e "$HOME_DIR/.cache/mint-setup"
ok "--yes keeps the language preference" test -f "$CFG/mint-setup/language"
ok "--yes keeps the saved backups" test -f "$BACKUPS/Mi_copia/manifest.conf"
ok "the report says what was kept (Spanish: the language preference is es)" grep -Fq 'Se han conservado tus configuraciones' <<<"$out"

# --- uninstall: the pkexec lock wherever prun put it -------------------------------------
# In a graphical session it is in XDG_RUNTIME_DIR; otherwise in $XDG_CACHE_HOME/mint-setup.
# Both lie outside $HOME here, as /run/user/UID does. Only the lock (and its own folder)
# may go; the neighbouring files stay.
lk_saved=("${MS_ENV[@]}")
rm -rf "$HOME_DIR/.local" "$TMP/lk"; mkdir -p "$TMP/lk/run" "$TMP/lk/cache/mint-setup"
ms_app --install >/dev/null 2>&1
: > "$TMP/lk/run/.Mint-Setup-pkexec.lock"; : > "$TMP/lk/run/other"
: > "$TMP/lk/cache/mint-setup/.Mint-Setup-pkexec.lock"; : > "$TMP/lk/cache/other"
ms_env_set XDG_RUNTIME_DIR "$TMP/lk/run"; ms_env_set XDG_CACHE_HOME "$TMP/lk/cache"
ms_app --uninstall --yes >/dev/null 2>&1; check_eq "uninstall with XDG_RUNTIME_DIR and XDG_CACHE_HOME set exits 0" "$?" 0
MS_ENV=("${lk_saved[@]}")
ok "the lock in XDG_RUNTIME_DIR is gone" test ! -e "$TMP/lk/run/.Mint-Setup-pkexec.lock"
ok "…and the runtime folder and its other files stay" test -f "$TMP/lk/run/other"
ok "the lock folder in XDG_CACHE_HOME is gone" test ! -e "$TMP/lk/cache/mint-setup"
ok "…and XDG_CACHE_HOME itself and its other files stay" test -f "$TMP/lk/cache/other"

# --- uninstall: purge, and the "no trace" guarantee ------------------------------------
rm -rf "$HOME_DIR/.cache/mint-setup"
ms_app --install >/dev/null 2>&1
printf 'edited\n' > "$HOME_DIR/bashrc.test"
printf '%q\n' "$HOME_DIR/bashrc.test.mint-setup.bak" > "$CFG/mint-setup/recovery-copies.list"
printf 'old\n' > "$HOME_DIR/bashrc.test.mint-setup.bak"
printf 'keep me\n' > "$BACKUPS/notes.txt"
mkdir -p "$BACKUPS/LuksHeaders"; printf 'header\n' > "$BACKUPS/LuksHeaders/luks-header_test.img"
ms_app --uninstall --yes --purge >/dev/null 2>&1; check_eq "purge exits 0" "$?" 0
ok "purge removed the language preference and its folder" test ! -e "$CFG/mint-setup"
ok "purge removed the recovery copy listed in the journal" test ! -e "$HOME_DIR/bashrc.test.mint-setup.bak"
ok "purge removed the recognised backup" test ! -e "$BACKUPS/Mi_copia"
ok "purge never deletes unrelated files in the backup folder" test -f "$BACKUPS/notes.txt"
ok "purge keeps the LuksHeaders folder (documented in the README)" grep -Fxq header "$BACKUPS/LuksHeaders/luks-header_test.img"
ok "the user's own file was not touched" grep -Fxq edited "$HOME_DIR/bashrc.test"
rm -rf "$BACKUPS/LuksHeaders"
rm -f "$BACKUPS/notes.txt" "$HOME_DIR/bashrc.test"
rmdir "$BACKUPS" 2>/dev/null; mkdir -p "$BACKUPS"

# 12.38: --purge ran rm -rf on each saved copy without looking at the result. A copy with a
# folder without write permission (copied from read-only media) was left half deleted
# (manifest.conf gone, so it could no longer be listed or deleted from the program), rm's
# own messages reached the terminal and the report still said "No Mint-Setup files are
# left" with exit 0. The folders are opened first (rm_backup_dir); what still cannot be
# deleted is named on stderr and the run ends with a warning and exit 1. The rm of this
# test refuses names ending in "_stuck" (works for root too) and prints rm's usual message.
PG_ROOT="$TMP/purge-stuck"; rm -rf "$PG_ROOT"; mkdir -p "$PG_ROOT"
ms_stub rm 'for a in "$@"; do
    case "$a" in *_stuck) echo "rm: cannot remove '"'"'$a'"'"': Operation not permitted" >&2; exit 1 ;; esac
done
exec /bin/rm "$@"'
pg_copy() {   # pg_copy NAME [ro]: a saved copy in $BACKUPS (with unwritable folders if "ro")
    mkdir -p "$BACKUPS/$1"; printf 'NAME=%s\nDATE=d\nMODULES=terminal\n' "$1" > "$BACKUPS/$1/manifest.conf"
    if [ "${2:-}" = ro ]; then mkdir -p "$BACKUPS/$1/ro/sub"; printf x > "$BACKUPS/$1/ro/sub/f"; chmod 555 "$BACKUPS/$1/ro/sub" "$BACKUPS/$1/ro"; fi
}
pg_reset() { chmod -R u+rwX "$BACKUPS" 2>/dev/null; rm -rf "$BACKUPS"; mkdir -p "$BACKUPS"; rm -rf "$HOME_DIR/.local" "$CFG/mint-setup"; }
pg_run() {   # pg_run LANG: install, then --uninstall --yes --purge; $pg_out and $pg_err (separate), $pg_rc
    local lang_env=()
    [ "$1" = es ] && lang_env=(LC_ALL=es_ES.UTF-8 LANGUAGE=es)
    ms_app --install >/dev/null 2>&1
    mkdir -p "$CFG/mint-setup"; printf '%s\n' "$1" > "$CFG/mint-setup/language"   # something for --purge to remove, in this run's language
    pg_out=$("${MS_ENV[@]}" "${lang_env[@]}" bash "$SCRIPT" --uninstall --yes --purge 2>"$PG_ROOT/err"); pg_rc=$?
    pg_err=$(sed '/^bash: warning: setlocale: /d' "$PG_ROOT/err")   # host without es_ES: not the script's output
}
for pg_lang in es en; do
    if [ "$pg_lang" = es ]; then
        pg_done='Desinstalación completada. No queda ningún archivo de Mint-Setup.'
        pg_left() { printf '  ! No se pudo eliminar: %s' "$1"; }
        pg_warn='Desinstalación incompleta: no se pudieron eliminar algunas copias guardadas (sin permiso de escritura o disco de solo lectura). Bórralas a mano.'
    else
        pg_done='Uninstall complete. No Mint-Setup files are left.'
        pg_left() { printf '  ! Could not remove: %s' "$1"; }
        pg_warn='Uninstall incomplete: some saved backups could not be removed (no write permission or read-only disk). Delete them manually.'
    fi
    # control: nothing in the way
    pg_reset; pg_copy Copia_a; pg_copy Copia_b
    pg_run "$pg_lang"
    { [ "$pg_rc" -eq 0 ] && grep -Fxq "$pg_done" <<<"$pg_out" && [ -z "$pg_err" ] && [ ! -e "$BACKUPS/Copia_a" ] && [ ! -e "$BACKUPS/Copia_b" ]; } \
        || fail "purge ($pg_lang): control run is not a clean success (rc=$pg_rc, out: $pg_out, err: $pg_err)"
    # folders without write permission: the copy goes away completely, in silence
    pg_reset; pg_copy Copia_ro ro
    pg_run "$pg_lang"
    { [ "$pg_rc" -eq 0 ] && grep -Fxq "$pg_done" <<<"$pg_out" && [ -z "$pg_err" ] && [ ! -e "$BACKUPS/Copia_ro" ]; } \
        || fail "purge ($pg_lang): a copy with read-only folders was not deleted (rc=$pg_rc, err: $pg_err; left: $(find "$BACKUPS" -mindepth 1 -printf '%P ' 2>/dev/null))"
    # one copy that cannot be deleted between two that can (the glob goes a, stuck, z: the run must not stop at the failure)
    pg_reset; pg_copy Copia_a; pg_copy Copia_stuck; pg_copy Copia_z
    pg_run "$pg_lang"
    [ "$pg_rc" -eq 1 ] || fail "purge ($pg_lang): a copy that could not be deleted must exit 1, got $pg_rc"
    [ "$pg_err" = "$(pg_left "$BACKUPS/Copia_stuck")"$'\n'"$pg_warn" ] \
        || fail "purge ($pg_lang): wrong warning on stderr: $pg_err"
    ! grep -Fq 'rm:' <<<"$pg_out$pg_err" || fail "purge ($pg_lang): rm's own message reached the terminal: $pg_err"
    if grep -Fq "No Mint-Setup files are left" <<<"$pg_out" || grep -Fq 'No queda ningún archivo' <<<"$pg_out"; then
        fail "purge ($pg_lang): says nothing is left although a copy remains: $pg_out"
    fi
    { [ ! -e "$BACKUPS/Copia_a" ] && [ ! -e "$BACKUPS/Copia_z" ] && [ -f "$BACKUPS/Copia_stuck/manifest.conf" ]; } \
        || fail "purge ($pg_lang): wrong set of copies left: $(find "$BACKUPS" -mindepth 1 -maxdepth 1 -printf '%f ')"
    grep -Fxq "  ✘ $(if [ "$pg_lang" = es ]; then echo Eliminado; else echo Removed; fi): $BACKUPS/Copia_a" <<<"$pg_out" \
        || fail "purge ($pg_lang): the copies that were deleted are not listed: $pg_out"
    { [ ! -e "$BIN" ] && [ ! -e "$CFG/mint-setup" ]; } || fail "purge ($pg_lang): the rest of the uninstall did not go on after the failure"
    # every copy fails: the same warning, one line each
    pg_reset; pg_copy Copia_stuck
    pg_run "$pg_lang"
    { [ "$pg_rc" -eq 1 ] && [ "$pg_err" = "$(pg_left "$BACKUPS/Copia_stuck")"$'\n'"$pg_warn" ] && [ -d "$BACKUPS/Copia_stuck" ]; } \
        || fail "purge ($pg_lang): total failure reported wrongly (rc=$pg_rc, err: $pg_err)"
done
# Without root only: a backup folder that cannot be modified fails for real, not by the test rm.
if [ "$(id -u)" -ne 0 ]; then
    pg_reset; pg_copy Copia_a
    ms_app --install >/dev/null 2>&1
    chmod 500 "$BACKUPS"
    pg_out=$(ms_app --uninstall --yes --purge 2>"$PG_ROOT/err"); pg_rc=$?; pg_err=$(cat "$PG_ROOT/err")
    chmod 700 "$BACKUPS"
    { [ "$pg_rc" -eq 1 ] && grep -Fq "! Could not remove: $BACKUPS/Copia_a" <<<"$pg_err" && ! grep -Fq 'rm:' <<<"$pg_err" \
        && ! grep -Fq "No Mint-Setup files are left" <<<"$pg_out"; } \
        || fail "purge: a backup folder without write permission was reported as deleted (rc=$pg_rc, out: $pg_out, err: $pg_err)"
fi
chmod -R u+rwX "$BACKUPS" 2>/dev/null; rm -f "$MOCK/rm"
pg_reset
pass "uninstall --purge: read-only folders are opened first; a copy that cannot be deleted is named, ends the run with a warning and exit 1 (es/en)"

# 12.39: --purge keeps the LuksHeaders folder (documented in the README), but the closing
# line said "No Mint-Setup files are left". A header copy plus the passphrase unlocks the
# disk, so the report now says that the copies were kept and where. A folder with no file in
# it holds nothing, and the usual line stays. Uses the helpers of the 12.38 block above.
pg_luks() {   # pg_luks [empty]: the LuksHeaders folder, with one header copy in it unless "empty"
    mkdir -p "$BACKUPS/LuksHeaders"
    [ "${1:-}" = empty ] || printf 'header\n' > "$BACKUPS/LuksHeaders/luks-header_test.img"
}
for pg_lang in es en; do
    if [ "$pg_lang" = es ]; then
        pg_done='Desinstalación completada. No queda ningún archivo de Mint-Setup.'
        pg_kept='Desinstalación completada. Se han conservado tus copias del header LUKS (--purge no las borra):'
        pg_bullet="  • Conservado: $BACKUPS/LuksHeaders"
    else
        pg_done='Uninstall complete. No Mint-Setup files are left.'
        pg_kept='Uninstall complete. Your LUKS header backups were kept (--purge does not delete them):'
        pg_bullet="  • Kept: $BACKUPS/LuksHeaders"
    fi
    # a header copy is left: the report says so and names the folder; the rest is purged
    pg_reset; pg_copy Copia_a; pg_luks
    pg_run "$pg_lang"
    { [ "$pg_rc" -eq 0 ] && [ -z "$pg_err" ] && [ "$(tail -n 2 <<<"$pg_out")" = "$pg_kept"$'\n'"$pg_bullet" ] \
        && [ "$(cat "$BACKUPS/LuksHeaders/luks-header_test.img" 2>/dev/null)" = header ] && [ ! -e "$BACKUPS/Copia_a" ] \
        && [ ! -e "$CFG/mint-setup" ]; } \
        || fail "purge ($pg_lang): LuksHeaders kept but not reported as kept (rc=$pg_rc, out: $pg_out, err: $pg_err)"
    if grep -Fq "$pg_done" <<<"$pg_out"; then fail "purge ($pg_lang): says nothing is left although a header copy remains: $pg_out"; fi
    # controls: no LuksHeaders folder, and one with no file in it
    pg_reset; pg_copy Copia_a
    pg_run "$pg_lang"
    { [ "$pg_rc" -eq 0 ] && [ -z "$pg_err" ] && [ "$(tail -n 1 <<<"$pg_out")" = "$pg_done" ] && ! grep -Fq "$pg_bullet" <<<"$pg_out"; } \
        || fail "purge ($pg_lang): control without LuksHeaders changed (rc=$pg_rc, out: $pg_out, err: $pg_err)"
    pg_reset; pg_copy Copia_a; pg_luks empty
    pg_run "$pg_lang"
    { [ "$pg_rc" -eq 0 ] && [ -z "$pg_err" ] && [ "$(tail -n 1 <<<"$pg_out")" = "$pg_done" ] && ! grep -Fq "$pg_bullet" <<<"$pg_out"; } \
        || fail "purge ($pg_lang): an empty LuksHeaders folder is reported as kept (rc=$pg_rc, out: $pg_out, err: $pg_err)"
done
pg_reset
pass "uninstall --purge: a kept LuksHeaders folder with header copies is reported instead of \"nothing is left\" (es/en)"

# 12.40: uninstall_file ignored the result of "rm -f": a file that could not be removed (the
# command in a folder without write permission...) stayed on disk, rm's own message reached
# the terminal and the report said "No Mint-Setup files are left" with exit 0. Now it is named
# on stderr, the run goes on with the rest and ends with a warning and exit 1. The rm of this
# test refuses the globs listed in $PG_ROOT/refuse (works for root too).
: > "$PG_ROOT/refuse"
ms_stub rm 'refuse='"'$PG_ROOT/refuse'"'
for a in "$@"; do
    while IFS= read -r pat; do
        case "$a" in $pat) echo "rm: cannot remove '"'"'$a'"'"': Operation not permitted" >&2; exit 1 ;; esac
    done < "$refuse"
done
exec /bin/rm "$@"'
fu_clean() { rm -rf "$HOME_DIR/bashrc.test.mint-setup.bak" "$HOME_DIR/zzz.mint-setup.bak" "$TMP/fu-run" "$HOME_DIR/.cache/mint-setup"; }
fu_run() {   # fu_run LANG [options]: install, leave something for --purge to remove, --uninstall --yes [options]
    local lang_env=(XDG_RUNTIME_DIR="$TMP/fu-run") l="$1"; shift
    [ "$l" = es ] && lang_env+=(LC_ALL=es_ES.UTF-8 LANGUAGE=es)
    ms_app --install >/dev/null 2>&1
    mkdir -p "$CFG/mint-setup" "$TMP/fu-run" "$HOME_DIR/.cache/mint-setup"; printf '%s\n' "$l" > "$CFG/mint-setup/language"
    : > "$TMP/fu-run/.Mint-Setup-pkexec.lock"; : > "$HOME_DIR/.cache/mint-setup/.Mint-Setup-pkexec.lock"
    printf 'old\n' > "$HOME_DIR/bashrc.test.mint-setup.bak"; printf 'old\n' > "$HOME_DIR/zzz.mint-setup.bak"
    printf '%q\n' "$HOME_DIR/bashrc.test.mint-setup.bak" "$HOME_DIR/zzz.mint-setup.bak" > "$CFG/mint-setup/recovery-copies.list"
    pg_out=$("${MS_ENV[@]}" "${lang_env[@]}" bash "$SCRIPT" --uninstall --yes "$@" 2>"$PG_ROOT/err"); pg_rc=$?
    pg_err=$(sed '/^bash: warning: setlocale: /d' "$PG_ROOT/err")
}
for pg_lang in es en; do
    if [ "$pg_lang" = es ]; then
        pf_done='Desinstalación completada'
        pf_left() { printf '  ! No se pudo eliminar: %s' "$1"; }
        pf_warn='Desinstalación incompleta: no se pudieron eliminar algunos archivos (sin permiso de escritura o disco de solo lectura). Bórralos a mano.'
        pf_bwarn='Desinstalación incompleta: no se pudieron eliminar algunas copias guardadas (sin permiso de escritura o disco de solo lectura). Bórralas a mano.'
    else
        pf_done='Uninstall complete'
        pf_left() { printf '  ! Could not remove: %s' "$1"; }
        pf_warn='Uninstall incomplete: some files could not be removed (no write permission or read-only disk). Delete them manually.'
        pf_bwarn='Uninstall incomplete: some saved backups could not be removed (no write permission or read-only disk). Delete them manually.'
    fi
    # one run per kind of file uninstall_file removes; --purge reaches all of them
    for fu_t in desktop manifest language journal recovery cachelock rtlock; do
        case "$fu_t" in
            desktop)  fu_pat='*.desktop';                fu_path=$DESKTOP ;;
            manifest) fu_pat='*/install.manifest';       fu_path=$MANIFEST ;;
            language) fu_pat='*/mint-setup/language';    fu_path="$CFG/mint-setup/language" ;;
            journal)  fu_pat='*/recovery-copies.list';   fu_path="$CFG/mint-setup/recovery-copies.list" ;;
            recovery) fu_pat='*/bashrc.test.mint-setup.bak'; fu_path="$HOME_DIR/bashrc.test.mint-setup.bak" ;;
            cachelock) fu_pat='*/mint-setup/.Mint-Setup-pkexec.lock'; fu_path="$HOME_DIR/.cache/mint-setup/.Mint-Setup-pkexec.lock" ;;
            rtlock)   fu_pat='*/fu-run/.Mint-Setup-pkexec.lock'; fu_path="$TMP/fu-run/.Mint-Setup-pkexec.lock" ;;
        esac
        pg_reset; fu_clean; printf '%s\n' "$fu_pat" > "$PG_ROOT/refuse"
        fu_run "$pg_lang" --purge
        [ "$pg_rc" -eq 1 ] || fail "uninstall ($pg_lang, $fu_t): a file that could not be removed must exit 1, got $pg_rc (out: $pg_out)"
        [ "$pg_err" = "$(pf_left "$fu_path")"$'\n'"$pf_warn" ] || fail "uninstall ($pg_lang, $fu_t): wrong stderr: $pg_err"
        ! grep -Fq 'rm:' <<<"$pg_out$pg_err" || fail "uninstall ($pg_lang, $fu_t): rm's own message reached the terminal: $pg_err"
        if grep -Fq "$pf_done" <<<"$pg_out"; then fail "uninstall ($pg_lang, $fu_t): says it is complete although a file remains: $pg_out"; fi
        { [ -f "$fu_path" ] && [ ! -e "$BIN" ] && [ ! -e "$HOME_DIR/zzz.mint-setup.bak" ]; } || fail "uninstall ($pg_lang, $fu_t): the run did not go on after the failure"
    done
    # without --purge the closing for kept configurations must not claim completion either
    pg_reset; fu_clean; printf '%s\n' '*.desktop' > "$PG_ROOT/refuse"
    pg_copy Copia_a
    fu_run "$pg_lang"
    { [ "$pg_rc" -eq 1 ] && [ "$pg_err" = "$(pf_left "$DESKTOP")"$'\n'"$pf_warn" ] && ! grep -Fq "$pf_done" <<<"$pg_out" && [ -d "$BACKUPS/Copia_a" ]; } \
        || fail "uninstall ($pg_lang): failure with kept configurations reported wrongly (rc=$pg_rc, out: $pg_out, err: $pg_err)"
    # a file and a saved copy fail in the same run: both are named, both warnings are given
    pg_reset; fu_clean; printf '%s\n' '*.desktop' '*_stuck' > "$PG_ROOT/refuse"
    pg_copy Copia_stuck
    fu_run "$pg_lang" --purge
    { [ "$pg_rc" -eq 1 ] && [ "$pg_err" = "$(pf_left "$DESKTOP")"$'\n'"$(pf_left "$BACKUPS/Copia_stuck")"$'\n'"$pf_warn"$'\n'"$pf_bwarn" ]; } \
        || fail "uninstall ($pg_lang): a file and a copy failing together were reported wrongly (rc=$pg_rc, err: $pg_err)"
done
# Without root only: a folder that cannot be modified fails for real, not by the test rm.
rm -f "$MOCK/rm"
if [ "$(id -u)" -ne 0 ]; then
    pg_reset; fu_clean
    ms_app --install >/dev/null 2>&1
    chmod 555 "$(dirname -- "$BIN")"
    pg_out=$(ms_app --uninstall --yes 2>"$PG_ROOT/err"); pg_rc=$?; pg_err=$(cat "$PG_ROOT/err")
    chmod 755 "$(dirname -- "$BIN")"
    { [ "$pg_rc" -eq 1 ] && grep -Fq "! Could not remove: $BIN" <<<"$pg_err" && ! grep -Fq 'rm:' <<<"$pg_err" \
        && ! grep -Fq "Uninstall complete" <<<"$pg_out" && [ -f "$BIN" ]; } \
        || fail "uninstall: a command in a folder without write permission was reported as removed (rc=$pg_rc, out: $pg_out, err: $pg_err)"
fi
fu_clean; rm -f "$PG_ROOT/refuse"
pg_reset
pass "uninstall: a file that cannot be removed is named, ends the run with a warning and exit 1, for every kind of file (es/en)"

# Full round trip from a pristine sandbox: install then purge leaves no trace at all.
rm -rf "$HOME_DIR/.local" "$CFG/mint-setup"
CLEAN=$(snap)
ms_app --install >/dev/null 2>&1
ms_app --uninstall --yes --purge >/dev/null 2>&1
check_eq "install + uninstall --purge leaves the sandbox exactly as it was" "$(snap)" "$CLEAN"

# --- uninstall: interactive answers, missing manifest, self-removal ---------------------
mkdir -p "$CFG/mint-setup" "$BACKUPS/Otra"
printf 'NAME=x\nDATE=y\nMODULES=terminal\n' > "$BACKUPS/Otra/manifest.conf"
ms_app --install >/dev/null 2>&1
printf 's\nn\nn\n' | MINT_SETUP_FORCE_INTERACTIVE=1 ms_app --uninstall >/dev/null 2>&1
ok "interactive: declining the final confirmation keeps the backups" test -f "$BACKUPS/Otra/manifest.conf"
ok "interactive: the program itself was still removed" test ! -e "$BIN"
ms_app --install >/dev/null 2>&1
printf 's\nn\ns\n' | MINT_SETUP_FORCE_INTERACTIVE=1 ms_app --uninstall >/dev/null 2>&1
ok "interactive: confirming deletion removes the backups" test ! -e "$BACKUPS/Otra"

# 12.50: sí and SÍ were matched with [íÍ], one byte (not the letter) outside a UTF-8 locale, so they
# were refused there and the default applied. Default n: the accented yes must give 0, the rest 1.
ay_bad=""
for ay_loc in C.UTF-8 C; do
    for ay_in in 'sí' 'SÍ' 'Sí' 'sÍ' 'sí\n' 'si'; do
        ay_got=$( ( ms_env_set LC_ALL "$ay_loc"; printf '%b' "$ay_in" | ms_lib 'ask_yes_no "? " n 2>/dev/null; echo $?' ) )
        [ "$ay_got" = 0 ] || ay_bad+=" [$ay_loc $ay_in: wanted 0, got $ay_got]"
    done
    for ay_in in 'sa' 'sure' 'no'; do
        ay_got=$( ( ms_env_set LC_ALL "$ay_loc"; printf '%b' "$ay_in" | ms_lib 'ask_yes_no "? " n 2>/dev/null; echo $?' ) )
        [ "$ay_got" = 1 ] || ay_bad+=" [$ay_loc $ay_in: wanted 1, got $ay_got]"
    done
done
check_eq "ask_yes_no: sí and SÍ are accepted in a non-UTF-8 locale too, other words are not" "$ay_bad" ""

# 12.49: an answer with no newline before EOF (printf 's', or typing it and pressing Ctrl-D) counts. It
# used to be dropped and the default applied: a "yes" became a "no" and a "no" became a "yes".
# Table: answer (printf %b) | default | exit status ask_yes_no must give.
ay_bad=""
while IFS='|' read -r ay_in ay_def ay_want; do
    ay_got=$(printf '%b' "$ay_in" | ms_lib 'ask_yes_no "? " "$1" 2>/dev/null; echo $?' "$ay_def")
    [ "$ay_got" = "$ay_want" ] || ay_bad+=" [$ay_in/$ay_def: wanted $ay_want, got $ay_got]"
done <<'EOF'
y|n|0
s|n|0
si|n|0
Yes|n|0
n|y|1
no|y|1
y\n|n|0
n\n|y|1
|y|0
|n|1
\n|y|0
\n|n|1
maybe|y|0
maybe|n|1
maybe\n|n|1
n\ny\n|y|1
y\nn\n|n|0
EOF
check_eq "ask_yes_no: an answer with no final newline counts; empty or unknown gives the default" "$ay_bad" ""

ay_setup() {   # installed, with preferences and one saved copy: the three questions are asked
    mkdir -p "$CFG/mint-setup" "$BACKUPS/Otra"
    printf 'NAME=x\nDATE=y\nMODULES=terminal\n' > "$BACKUPS/Otra/manifest.conf"
    ms_app --install >/dev/null 2>&1
}
ay_setup
printf 's' | MINT_SETUP_FORCE_INTERACTIVE=1 ms_app --uninstall >/dev/null 2>&1
ok "interactive: a yes with no final newline to the first question uninstalls" test ! -e "$BIN"
ay_setup
out=$(printf 's\nn' | MINT_SETUP_FORCE_INTERACTIVE=1 ms_app --uninstall 2>&1)
ok "interactive: a no to \"keep\" with no final newline asks about deleting" grep -Fq 'will be deleted forever' <<<"$out"
ok "…and with no answer to that, the backups are kept" test -f "$BACKUPS/Otra/manifest.conf"
ay_setup
printf 's\nn\ns' | MINT_SETUP_FORCE_INTERACTIVE=1 ms_app --uninstall >/dev/null 2>&1
ok "interactive: confirming the deletion with no final newline removes the backups" test ! -e "$BACKUPS/Otra"

ms_app --install >/dev/null 2>&1
rm -f "$MANIFEST"
ms_app --uninstall --yes >/dev/null 2>&1
ok "an interrupted install (no manifest) is still cleaned by known paths" test ! -e "$BIN" -a ! -e "$ICON" -a ! -e "$DESKTOP"
ok "…and so are its icon folders, once one of its files was recognised" test ! -e "$HOME_DIR/.local/share/icons/hicolor/256x256"
ms_app --install >/dev/null 2>&1
rm -f "$MANIFEST" "$BIN" "$ICON"
ms_app --uninstall --yes >/dev/null 2>&1
ok "…a single recognised file (the launcher) is enough proof" test ! -e "$DESKTOP" -a ! -e "$HOME_DIR/.local/share/icons/hicolor/256x256"

# With nothing of ours on disk (and no manifest) there is no proof that the icon
# folders are ours: empty ones left by other programs must survive.
mkdir -p "$HOME_DIR/.local/share/icons/hicolor/256x256/apps"
FOREIGN=$(snap)
ms_app --uninstall --yes >/dev/null 2>&1
check_eq "uninstalling when nothing is installed leaves other programs' empty folders alone" "$(snap)" "$FOREIGN"
rmdir "$HOME_DIR/.local/share/icons/hicolor/256x256/apps" "$HOME_DIR/.local/share/icons/hicolor/256x256"

out=$(ms_app --uninstall --yes 2>&1); rc=$?
check_eq "uninstalling when nothing is installed exits 0" "$rc" 0
ok "…and says so" grep -Fq 'Nothing to uninstall' <<<"$out"
ok "…without announcing an uninstall that does not happen" bash -c '! grep -Fq "Uninstalling" <<<"$1"' _ "$out"
ok "…and still closes with the final report" grep -Fq 'Uninstall complete. No Mint-Setup files are left.' <<<"$out"

ms_app --install >/dev/null 2>&1
out=$(ms_app --uninstall --yes 2>&1)
ok "control: a real uninstall still announces itself" grep -Fxq 'Uninstalling Mint-Setup...' <<<"$out"

ms_app --install >/dev/null 2>&1
env -u DISPLAY HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" PATH="$MOCK:$SAFE_PATH" "$BIN" --uninstall --yes --purge >/dev/null 2>&1
check_eq "the installed copy can uninstall itself" "$?" 0
ok "…and its file is gone" test ! -e "$BIN"

# --- atomicity: a failure half-way leaves nothing behind ----------------------------------
rm -rf "$HOME_DIR/.local"
CLEAN=$(snap)
ms_lib 'icon_extract() { return 1; }; do_install' >/dev/null 2>&1; rc=$?
check_eq "a failing step makes the install fail" "$rc" 1
check_eq "…and the rollback restores the exact previous state" "$(snap)" "$CLEAN"

# 12.48: a mkdir -p can create some levels and then fail on the last one (full disk, quota). Those
# levels must be recorded, or the rollback leaves them behind while the message says it undid all.
# The stub creates the parent of $MKFAIL_LAST and fails on that folder.
mkdir -p "$TMP/mkfail"
cat > "$TMP/mkfail/mkdir" <<'SH'
#!/bin/sh
for last; do :; done
if [ "$last" = "${MKFAIL_LAST:-}" ]; then
    /usr/bin/mkdir -p -- "$(dirname -- "$last")"
    echo "mkdir: cannot create directory '$last': No space left on device" >&2
    exit 1
fi
exec /usr/bin/mkdir "$@"
SH
chmod +x "$TMP/mkfail/mkdir"
mkfail_env() { ms_env_set PATH "$TMP/mkfail:$MOCK:$SAFE_PATH"; ms_env_set MKFAIL_LAST "$1"; }   # use inside ( )
out=$( ( mkfail_env "$HOME_DIR/.local/share/icons/hicolor/256x256/apps"; ms_app --install 2>&1 ) ); rc=$?
check_eq "a mkdir that fails after creating some levels makes the install fail" "$rc" 1
ok "…and the message says it was rolled back" grep -Fq 'Everything created so far was rolled back.' <<<"$out"
check_eq "…and no folder it created is left behind" "$(snap)" "$CLEAN"
check_eq "install_mkdir returns the failure and records the levels it did create, parents first" \
    "$( ( mkfail_env "$HOME_DIR/x/y/z"; ms_lib 'install_mkdir "$HOME/x/y/z"; echo "rc=$?"; printf "%s\n" "${INSTALL_NEW_DIRS[@]}"; install_rollback
        [ -e "$HOME/x" ] && echo LEFT || echo CLEAN' ) 2>/dev/null )" \
    "$(printf 'rc=1\n%s\n%s\nCLEAN' "$HOME_DIR/x" "$HOME_DIR/x/y")"
check_eq "install_mkdir records only the levels it creates, and makes them 755 under any umask" \
    "$( umask 077; ms_lib 'mkdir -p "$HOME/p"; install_mkdir "$HOME/p/q/r"; echo "rc=$?"; printf "%s\n" "${INSTALL_NEW_DIRS[@]}"
        install_mkdir "$HOME/p/q/r"; echo "again rc=$? n=${#INSTALL_NEW_DIRS[@]}"; stat -c "mode %a" "$HOME/p/q" "$HOME/p/q/r"' )" \
    "$(printf 'rc=0\n%s\n%s\nagain rc=0 n=2\nmode 755\nmode 755' "$HOME_DIR/p/q" "$HOME_DIR/p/q/r")"
rm -rf "$HOME_DIR/p" "$TMP/mkfail"

# --- foreign files are never overwritten --------------------------------------------------
mkdir -p "$HOME_DIR/.local/bin"
printf '#!/bin/sh\necho mine\n' > "$BIN"; chmod 755 "$BIN"
ms_app --install >/dev/null 2>&1; check_eq "install refuses to overwrite a foreign program" "$?" 1
ok "…and leaves it untouched" grep -Fq 'echo mine' "$BIN"
rm -rf "$HOME_DIR/.local"

# --- launcher Exec= and the characters the Desktop Entry specification reserves ---------------
# exec_check DESKTOP_FILE EXPECTED_PATH reads the Exec key the way the specification
# defines it (string escapes \s \n \t \r \\ first, then double-quote splitting) and
# prints OK only if it yields exactly one argument equal to EXPECTED_PATH, with no
# reserved character outside quotes (forbidden there) and no field code left.
cat > "$TMP/exec_check.py" <<'PY'
import re, sys

path, want = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().split("\n")
raw = [l for l in lines if l.startswith("Exec=")]
if len(raw) != 1:
    print("BAD: %d Exec= lines" % len(raw)); sys.exit(0)
esc = {"s": " ", "n": "\n", "t": "\t", "r": "\r", "\\": "\\"}
val = re.sub(r"\\(.)", lambda m: esc.get(m.group(1), m.group(0)), raw[0][5:])
reserved = set(" \t\n\"'\\><~|&;$*?#()`")
args, cur, quoted, started, i = [], [], False, False, 0
while i < len(val):
    c = val[i]
    if quoted:
        if c == "\\" and i + 1 < len(val) and val[i + 1] in '"`$\\':
            cur.append(val[i + 1]); i += 2; continue
        if c == '"': quoted = False
        else: cur.append(c)
    elif c == '"':
        quoted = started = True
    elif c in " \t":
        if started or cur: args.append("".join(cur)); cur = []; started = False
    elif c == "%":
        print("BAD: field code or bare % in the command"); sys.exit(0)
    elif c in reserved:
        print("BAD: reserved character %r outside quotes" % c); sys.exit(0)
    else:
        cur.append(c)
    i += 1
if quoted:
    print("BAD: unterminated quote"); sys.exit(0)
if started or cur: args.append("".join(cur))
print("OK" if args == [want] else "BAD: got %r" % (args,))
PY
exec_check() { python3 "$TMP/exec_check.py" "$1" "$2"; }

RES_ROOT="$TMP/reserved"; mkdir -p "$RES_ROOT"
# Reserved characters (and a few that are not) inside HOME: the launcher must still
# start the installed program, and the uninstall must find and remove everything.
for c in ' ' $'\t' "'" '>' '<' '~' '|' '&' ';' '*' '?' '#' '(' ')' '[' '=' '!' ',' 'ñ'; do
    label=$(printf '%q' "$c")
    rh="$RES_ROOT/h${c}x"; mkdir -p "$rh/.config"
    rbin="$rh/.local/bin/mint-setup"; rdesk="$rh/.local/share/applications/mint-setup.desktop"
    ( ms_env_set HOME "$rh"; ms_app --install >/dev/null 2>&1 ); rc=$?
    check_eq "HOME with $label: install exits 0" "$rc" 0
    check_eq "HOME with $label: Exec= reads back as exactly the program path" "$(exec_check "$rdesk" "$rbin")" OK
    ( ms_env_set HOME "$rh"; ms_app --uninstall --yes >/dev/null 2>&1 )
    ok "HOME with $label: uninstall removes the program and the launcher" test ! -e "$rbin" -a ! -e "$rdesk"
    rm -rf "$rh"
done

# Characters that would need escaping inside the quotes are refused outright, and the
# failed install leaves no trace.
for c in "\\" '"' '$' '`' '%' $'\n'; do
    label=$(printf '%q' "$c")
    rh="$RES_ROOT/r${c}x"; mkdir -p "$rh/.config"
    before=$(ms_tree "$rh")
    out=$( ( ms_env_set HOME "$rh"; ms_app --install 2>&1 ) ); rc=$?
    check_eq "HOME with $label: install is refused (exit 1)" "$rc" 1
    ok "HOME with $label: the refusal says why" grep -Fq 'characters a launcher does not support' <<<"$out"
    check_eq "HOME with $label: nothing was created" "$(ms_tree "$rh")" "$before"
    rm -rf "$rh"
done

# --- uninstall: install locations outside $HOME (12.51) ---------------------------------------
# --uninstall took manifest paths only if they matched "$HOME"/?*, so the files and folders the
# program derives from XDG_DATA_HOME were dropped in silence when it pointed outside HOME (or HOME
# ended in "/" and XDG_DATA_HOME was written with a single one): the launcher, the icon, the
# manifest and their folders stayed, and the report still said "No Mint-Setup files are left" with
# exit 0. Each case gets its own sandbox (HOME, config, backups), apart from the shared one.
XD="$TMP/xdg-cases"
xd_app() {   # the program in the current case: HOME=$XD_HOME and, unless it is "-", XDG_DATA_HOME=$XD_DATA
    (   cd "$XD" || exit 1
        ms_env_set HOME "$XD_HOME"; ms_env_set XDG_CONFIG_HOME "$XD/config"; ms_env_set MINT_SETUP_BACKUPS_DIR "$XD/backups"
        [ "$XD_DATA" = - ] || ms_env_set XDG_DATA_HOME "$XD_DATA"
        ms_app "$@" )
}
# xd_new HOME XDG|- [folder...]: clean sandbox (and the folders), then --install. Sets $xd_irc,
# $xd_data (data folder in use), $xd_before (tree before the install) and $xd_has (launcher installed).
xd_new() {
    XD_HOME=$1; XD_DATA=$2; shift 2
    rm -rf "$XD"; mkdir -p "$XD/config" "${XD_HOME%/}" "$@"
    case "$XD_DATA" in -) xd_data="${XD_HOME%/}/.local/share" ;; /*) xd_data=$XD_DATA ;; *) xd_data="$XD/$XD_DATA" ;; esac
    xd_before=$(ms_tree "$XD")
    xd_app --install >/dev/null 2>&1; xd_irc=$?
    xd_has=no; [ ! -f "$xd_data/applications/mint-setup.desktop" ] || xd_has=yes
}
xd_round() {   # xd_round LABEL: --uninstall --yes --purge after xd_new; exit 0, the true report and the tree as before
    local out rc delta
    out=$(xd_app --uninstall --yes --purge 2>&1); rc=$?
    delta=$(diff <(printf '%s\n' "$xd_before") <(ms_tree "$XD") | sed -n -e 's/^> \([^ ]*\) .*/+\1/p' -e 's/^< \([^ ]*\) .*/-\1/p' | tr '\n' ' ')
    check_eq "$1" "install=$xd_irc launcher=$xd_has uninstall=$rc closing=$(tail -n 1 <<<"$out") tree=[$delta]" \
        "install=0 launcher=yes uninstall=0 closing=Uninstall complete. No Mint-Setup files are left. tree=[]"
}
xd_new "$XD/home" "$XD/xdg";                      xd_round "XDG_DATA_HOME outside HOME: nothing is left behind"
xd_new "$XD/home" "$XD/shared/xdg" "$XD/shared";  xd_round "…and a folder above it that was already there stays (it is not ours)"
xd_new "$XD/home/" "$XD/home/data";               xd_round "HOME ending in \"/\" with XDG_DATA_HOME written with one slash: nothing is left behind"
xd_new "$XD/home/" -;                             xd_round "control: HOME ending in \"/\" with the default XDG_DATA_HOME"
xd_new "$XD/home" xdg-rel;                        xd_round "relative XDG_DATA_HOME (invalid per the XDG spec): no endless loop, nothing is left behind"

# An interrupted install (no manifest) is still cleaned by known paths, outside HOME too.
xd_new "$XD/home" "$XD/xdg"; rm -f "$xd_data/mint-setup/install.manifest"
xd_app --uninstall --yes >/dev/null 2>&1; rc=$?
check_eq "XDG_DATA_HOME outside HOME, no manifest: the files and the icon folders are still cleaned" \
    "rc=$rc left=[$(find "$xd_data" "$XD/home/.local/bin" \( -type f -o -name 256x256 -o -name apps \) | tr '\n' ' ')]" "rc=0 left=[]"

# A forged manifest cannot widen what is removed outside HOME: only the install's own files and
# folders count. What it names stays, also inside our folders and under near-names of our files.
xd_new "$XD/home" "$XD/xdg"
xd_foreign=("$XD/foreign.txt" "$xd_data/applications/other.desktop" "$xd_data/applications/mint-setup.desktop.orig"
            "$xd_data/icons/hicolor/256x256/apps/mint-setup.png.orig" "$xd_data/mint-setup/install.manifest.orig")
mkdir "$XD/foreign-dir" "$xd_data/icons/foreign-dir"
for f in "${xd_foreign[@]}"; do
    echo precious > "$f"; printf 'F %s %q\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f"
done >> "$xd_data/mint-setup/install.manifest"
printf 'D %q\n' "$XD/foreign-dir" "$xd_data/icons/foreign-dir" >> "$xd_data/mint-setup/install.manifest"
xd_app --uninstall --yes >/dev/null 2>&1; rc=$?
xd_lost=""; xd_left=""
for f in "${xd_foreign[@]}"; do [ -f "$f" ] || xd_lost+=" ${f##*/}"; done
for f in "$XD/foreign-dir" "$xd_data/icons/foreign-dir"; do [ -d "$f" ] || xd_lost+=" ${f##*/}"; done
for f in "$XD/home/.local/bin/mint-setup" "$xd_data/applications/mint-setup.desktop" "$xd_data/icons/hicolor/256x256/apps/mint-setup.png" "$xd_data/mint-setup/install.manifest"; do
    [ ! -e "$f" ] || xd_left+=" ${f##*/}"
done
check_eq "a forged manifest: what it names outside HOME stays (even inside our folders) and our own files still go" \
    "rc=$rc lost=[${xd_lost# }] left=[${xd_left# }]" "rc=0 lost=[] left=[]"

# HOME itself, spelled both ways in a forged manifest: once everything is removed it is empty and
# its parent is writable, so rmdir would take it.
for xd_h in "$XD/home" "$XD/home/"; do
    for xd_x in - "$XD/xdg"; do
        xd_new "$xd_h" "$xd_x"
        printf 'D %q\n' "$XD/home" "$XD/home/" >> "$xd_data/mint-setup/install.manifest"
        xd_app --uninstall --yes >/dev/null 2>&1; rc=$?
        check_eq "a forged manifest naming HOME (HOME=$xd_h XDG_DATA_HOME=$xd_x): HOME stays, the install is removed" \
            "rc=$rc home=$([ -d "$XD/home" ] && echo kept || echo GONE) bin=$([ -e "$XD/home/.local/bin/mint-setup" ] && echo present || echo absent)" \
            "rc=0 home=kept bin=absent"
    done
done
rm -rf "$XD"

# --- both languages --------------------------------------------------------------------------
mkdir -p "$CFG/mint-setup"; printf 'es\n' > "$CFG/mint-setup/language"
ok "Spanish install message" grep -Fq 'Instalación completada' <<<"$(ms_app --install 2>&1)"
ms_app --uninstall --yes --purge >/dev/null 2>&1
ok "English install message (control)" grep -Fq 'Installation complete' <<<"$(ms_app --install 2>&1)"
ms_app --uninstall --yes --purge >/dev/null 2>&1

ms_finish
