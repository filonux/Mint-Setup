#!/bin/bash
set -euo pipefail
umask 022   # fixture modes must not depend on the contributor's umask

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/script/mint-setup.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

bash -n "$SCRIPT"
pass "shell syntax"

# Language must not alter semantic identifiers or pure helpers.
for lang in es en; do
    out=$(MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/cfg-$lang" LC_ALL=C HOME="$TMP/home-common" bash -c '
        source "$1"
        set_language "$2"
        printf "%s\n" "${MODULE_KEYS[*]}"
        printf "%s\n" "$(modules_need_root "network bluetooth docker software" terminal; echo $?)"
        printf "%s\n" "$(modules_need_root "network bluetooth docker software" terminal network; echo $?)"
        printf "%s\n" "$(uri_encode_path "/tmp/Prueba con ñ.txt")"
        printf "%s\n" "$(xdg_dir PICTURES "$HOME/Pictures")"
    ' _ "$SCRIPT" "$lang")
    printf '%s\n' "$out" > "$TMP/helpers-$lang"
done
diff -u "$TMP/helpers-es" "$TMP/helpers-en" >/dev/null || fail "language changed semantic module/helper results"
pass "semantic helpers invariant across languages"

# Menu action values 1..5 must remain the same; only displayed text may differ.
for lang in es en; do
    mkdir -p "$TMP/bin-$lang"
    cat > "$TMP/bin-$lang/zenity" <<'ZENITY'
#!/bin/bash
printf '%s\n' "$*" >> "${ZENITY_LOG:?}"
if [[ "$*" == *--list* ]]; then
    if [[ "$*" == *'Save configuration'* || "$*" == *'Guardar configuración'* ]]; then :; fi
    printf '%s\n' "${ZENITY_CHOICE:-5}"
fi
exit 0
ZENITY
    chmod +x "$TMP/bin-$lang/zenity"
    log="$TMP/menu-$lang.log"
    XDG_CONFIG_HOME="$TMP/menu-cfg-$lang" HOME="$TMP/menu-home-$lang" LC_ALL=C \
    MINT_SETUP_TEST=1 APP_LANG="$lang" ZENITY_LOG="$log" ZENITY_CHOICE=5 \
    PATH="$TMP/bin-$lang:/usr/bin:/bin" bash -c '
        source "$1"
        set_language "$2"
        main_menu
    ' _ "$SCRIPT" "$lang" >/dev/null 2>&1
    grep -Fq '5 ' "$log" || fail "menu did not expose exit action in $lang"
    grep -Fq 'L ' "$log" || fail "menu did not expose language action in $lang"
done
pass "main menu semantic choices invariant"

# The checklist must return internal module keys, never translated labels.
for lang in es en; do
    mkdir -p "$TMP/check-$lang"
    cat > "$TMP/check-$lang/zenity" <<'ZENITY'
#!/bin/bash
printf '%s\n' "$*" >> "${ZENITY_LOG:?}"
case "$*" in
  *--checklist*) printf 'terminal' ;;
  *--entry*) printf 'Invariant' ;;
  *--progress*) cat >/dev/null ;;
esac
exit 0
ZENITY
    chmod +x "$TMP/check-$lang/zenity"
    log="$TMP/check-$lang.log"
    backup="$TMP/backup-$lang"
    mkdir -p "$backup"
    XDG_CONFIG_HOME="$TMP/check-cfg-$lang" HOME="$TMP/check-home-$lang" MINT_SETUP_BACKUPS_DIR="$TMP/check-backups-$lang" \
    LC_ALL=C MINT_SETUP_TEST=1 APP_LANG="$lang" ZENITY_LOG="$log" PATH="$TMP/check-$lang:/usr/bin:/bin" \
    bash -c '
        source "$1"
        set_language "$2"
        root_preauth(){ return 0; }
        save_terminal(){ mkdir -p "$3/terminal" 2>/dev/null || mkdir -p "$1/terminal"; }
        # Drive do_save with a fixed module selection and fixed name.
        export ZENITY_CHOICE=terminal
        # The fake entry is handled by the mock only; do_save writes the manifest from selection.
        do_save
    ' _ "$SCRIPT" "$lang" >/dev/null 2>&1 || true
    grep -Fq -- 'terminal' "$log" || fail "terminal key not present in $lang checklist"
    # A translated label must not be fed back as the selection value.
    grep -Fq -- '--print-column=4' "$log" || fail "internal key column missing in $lang checklist"
    grep -Fq -- '--hide-column=4' "$log" || fail "internal key column not hidden in $lang checklist"
done
pass "checklist return channel remains internal-key based"

# Saving the same terminal fixture in both languages must create identical functional files.
for lang in en es; do
    HOME_DIR="$TMP/save-home-$lang"; BACKUP_ROOT="$TMP/save-backups-$lang"; mkdir -p "$HOME_DIR/.config" "$BACKUP_ROOT" "$TMP/bin-save-$lang"
    printf 'original\n' > "$HOME_DIR/.bashrc"
    printf 'alias ll="ls -la"\n' > "$HOME_DIR/.bash_aliases"
    printf 'starship\n' > "$HOME_DIR/.config/starship.toml"
    cat > "$TMP/bin-save-$lang/dconf" <<'DC'
#!/bin/sh
[ "${1:-}" = dump ] && printf '[profile]\nvisible-name='
DC
    chmod +x "$TMP/bin-save-$lang/dconf"
    target="$BACKUP_ROOT/config"
    mkdir -p "$target"
    XDG_CONFIG_HOME="$TMP/cfg-save-$lang" HOME="$HOME_DIR" LC_ALL=C APP_LANG="$lang" \
    PATH="$TMP/bin-save-$lang:/usr/bin:/bin" MINT_SETUP_TEST=1 \
    bash -c 'source "$1"; set_language "$2"; save_terminal "$3"' _ "$SCRIPT" "$lang" "$target" >/dev/null
    find "$target" -type f ! -name '*.log' -printf '%P\n' | sort > "$TMP/save-files-$lang"
    (cd "$target" && while IFS= read -r f; do sha256sum "$f"; done < "$TMP/save-files-$lang") > "$TMP/save-hash-$lang"
done
diff -u "$TMP/save-files-en" "$TMP/save-files-es" >/dev/null || fail "terminal backup file set differs by language"
diff -u "$TMP/save-hash-en" "$TMP/save-hash-es" >/dev/null || fail "terminal backup file content differs by language"
pass "terminal backup invariance across languages"

# Static guard: a translated UI label must never be used as a program control value.
if grep -nE '\[[^]]*\$\(T(_FMT)?|case [^;]*\$\(T(_FMT)?' "$SCRIPT" | grep -v 'device.*manual_label'; then
    fail "translated UI text is used as a control value"
fi
pass "no translated prose used as control data"

# All printf-format call sites must have matching catalog placeholders.
# shellcheck source=../script/mint-setup.sh
MINT_SETUP_TEST=1 source "$SCRIPT"
while IFS= read -r line; do
    [ -n "$line" ] || continue
    src=$(printf '%s\n' "$line" | sed -n "s/.*T_FMT[[:space:]]*'\([^']*\)'.*/\1/p")
    [ -n "$src" ] || continue
    en="${T_EXACT[$src]:-}"
    [ -n "$en" ] || fail "T_FMT template not in catalog: $src"
    [ "$(grep -o '%s' <<<"$src" | wc -l)" -eq "$(grep -o '%s' <<<"$en" | wc -l)" ] || fail "T_FMT placeholder mismatch: $src"
done < <(grep 'T_FMT' "$SCRIPT")
pass "T_FMT semantic format parity"

# Formatting must decode catalog escapes without interpreting argument data.
fmt_result=$(MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/tfmt-cfg" bash -c '
source "$1"
set_language en
T_FMT '"'"'Aviso: no se pudo guardar «%s» de forma íntegra (¿disco lleno o permisos?); se omite.'"'"' "100% ready\nnext"
' _ "$SCRIPT")
expected=$'Warning: “100% ready\\nnext” could not be saved intact (disk full or permissions?); skipped.'
[ "$fmt_result" = "$expected" ] || fail "T_FMT altered format or argument escapes"
pass "T_FMT keeps argument data literal"

# dconf dumps must be discarded completely when the command fails midway.
DCF_TMP="$TMP/dconf-atomic"; mkdir -p "$DCF_TMP"
DCF_RESULT=$(MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/dconf-atomic-cfg" bash -c '
source "$1"
dconf() {
    [ "${1:-}" = dump ] || return 0
    printf "partial\n"
    return 7
}
dconf_dump_atomic /demo/path "$2"
' _ "$SCRIPT" "$DCF_TMP/test.dconf" 2>&1 || true)
[ ! -e "$DCF_TMP/test.dconf" ] || fail "failed dconf dump left a partial destination"
printf '%s\n' "$DCF_RESULT" | grep -Fq 'test.dconf' || fail "failed dconf dump was not reported"
pass "dconf dump atomicity"

# A failed ordinary file copy must also discard its temporary destination.
COPY_TMP="$TMP/save-copy-atomic"; mkdir -p "$COPY_TMP"
printf 'source\n' > "$COPY_TMP/source.txt"
COPY_RESULT=$(MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/save-copy-cfg" bash -c '
source "$1"
cp() { printf "partial" > "$2"; return 7; }
save_copy "$2" "$3"
' _ "$SCRIPT" "$COPY_TMP/source.txt" "$COPY_TMP/dest.txt" 2>&1 || true)
[ ! -e "$COPY_TMP/dest.txt" ] || fail "failed save_copy published a partial destination"
printf '%s\n' "$COPY_RESULT" | grep -Fq 'source.txt' || fail "failed save_copy was not reported"
pass "ordinary file copy atomicity"

# Simulate a disk-full write with the shell's file-size limit. The child
# writer fails after the existing destination is untouched.
FULL_TMP="$TMP/disk-full-atomic"; mkdir -p "$FULL_TMP"
printf 'previous\n' > "$FULL_TMP/dest.txt"
printf '%*s' 4096 '' | tr ' ' X > "$FULL_TMP/source.txt"
(
    ulimit -f 1
    MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/disk-full-cfg" bash -c '
source "$1"
atomic_copy "$2/source.txt" "$2/dest.txt"
' _ "$SCRIPT" "$FULL_TMP" >/dev/null 2>&1
) || true
grep -qx 'previous' "$FULL_TMP/dest.txt" || fail "size-limit copy replaced the previous destination"
[ "$(wc -c < "$FULL_TMP/source.txt")" -eq 4096 ] || fail "size-limit fixture is invalid"
find "$FULL_TMP" -name '.*.mstmp.*' -print -quit | grep -q . && fail "size-limit copy left an atomic temporary"

TAR_FULL_TMP="$TMP/disk-full-tar-atomic"; mkdir -p "$TAR_FULL_TMP/source"
printf 'previous tar\n' > "$TAR_FULL_TMP/dest.tar.gz"
dd if=/dev/urandom of="$TAR_FULL_TMP/source/data.txt" bs=8192 count=1 status=none
(
    ulimit -f 1
    MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/disk-full-tar-cfg" bash -c '
source "$1"
atomic_tar "$2/dest.tar.gz" -C "$2/source" data.txt
' _ "$SCRIPT" "$TAR_FULL_TMP" >/dev/null 2>&1
) || true
before_tar_hash=$(printf 'previous tar\n' | sha256sum | cut -d' ' -f1)
# The fixture is intentionally not a valid archive; atomic_tar must keep it untouched on failure.
after_tar_hash=$(sha256sum "$TAR_FULL_TMP/dest.tar.gz" | cut -d' ' -f1)
[ "$after_tar_hash" = "$before_tar_hash" ] || fail "size-limit tar replaced the previous archive"
find "$TAR_FULL_TMP" -name '.*.mstmp.*' -print -quit | grep -q . && fail "size-limit tar left an atomic temporary"
pass "disk-write-limit tar atomicity"
pass "disk-write-limit atomicity"

printf 'All language-invariance tests passed.\n'
