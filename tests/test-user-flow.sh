#!/bin/bash
set -u
umask 022   # fixture modes must not depend on the contributor's umask

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/script/mint-setup.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

MOCK="$TMP/bin"; mkdir -p "$MOCK"
cat > "$MOCK/id" <<'ID'
#!/bin/sh
[ "${1:-}" = "-u" ] && { echo 1000; exit 0; }
exec /usr/bin/id "$@"
ID
cat > "$MOCK/zenity" <<'ZENITY'
#!/bin/bash
out=${ZENITY_CAPTURE:?}; mkdir -p "$out"
printf '%s\n' "$*" >> "$out/calls"
case "$*" in
  *--list*)
    # ZENITY_LIST_CHOICES answers the --list dialogs only, in order.
    list="$out/list-index"; n=0; [ -f "$list" ] && n=$(cat "$list"); n=$((n+1)); printf '%s\n' "$n" > "$list"
    choice=$(printf '%s' "${ZENITY_LIST_CHOICES:-}" | sed -n "${n}p"); [ -n "$choice" ] && printf '%s\n' "$choice" ;;
  *--entry*) printf '%s\n' "${ZENITY_ENTRY:-}" ;;
  *--question*) exit "${ZENITY_QUESTION_RC:-0}" ;;
  *--text-info*) for a in "$@"; do case "$a" in --filename=*) cp "${a#--filename=}" "$out/report" ;; esac; done ;;
  *--progress*) cat >/dev/null ;;
esac
ZENITY
for x in id zenity; do chmod +x "$MOCK/$x"; done
for x in dconf gsettings apt-get pkexec gio pgrep code flatpak pactl iconv fc-cache xdg-user-dir xdg-open systemctl; do
cat > "$MOCK/$x" <<'CMD'
#!/bin/sh
[ "$(basename "$0")" = "iconv" ] && exec /usr/bin/iconv "$@"
exit 0
CMD
chmod +x "$MOCK/$x"
done

HOME_DIR="$TMP/home"; CFG="$TMP/config"; BACKUPS="$TMP/backups"
mkdir -p "$HOME_DIR/.config" "$CFG" "$BACKUPS"
printf 'original\n' > "$HOME_DIR/.bashrc"
printf 'original-starship\n' > "$HOME_DIR/.config/starship.toml"
SEQ=$'1\nterminal\n5\n'
HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" PATH="$MOCK:/usr/bin:/bin" \
ZENITY_CAPTURE="$TMP/save" ZENITY_LIST_CHOICES="$SEQ" ZENITY_ENTRY='User flow' LC_ALL=C.UTF-8 \
bash "$SCRIPT" >/dev/null 2>&1 || fail "save flow exited non-zero"
backup=$(find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d -name 'User_flow_*' | head -1)
[ -n "$backup" ] || fail "save flow did not create a backup"
[ -f "$backup/terminal/.bashrc" ] || fail "terminal file missing from backup"
[ "$(stat -c '%a' "$BACKUPS")" = 700 ] || fail "backup root is not mode 700"
[ "$(stat -c '%a' "$backup")" = 700 ] || fail "backup directory is not mode 700"
if find "$backup" -type f -perm /077 -print -quit | grep -q .; then
    fail "backup contains a regular file readable by group or other"
fi
if find "$backup" -type d -perm /077 -print -quit | grep -q .; then
    fail "backup contains a directory accessible by group or other"
fi
printf 'changed\n' > "$HOME_DIR/.bashrc"
printf 'changed-starship\n' > "$HOME_DIR/.config/starship.toml"
SEQ=$(printf '2\n%s\nterminal\n5\n' "$backup")
HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" PATH="$MOCK:/usr/bin:/bin" \
ZENITY_CAPTURE="$TMP/restore" ZENITY_LIST_CHOICES="$SEQ" ZENITY_QUESTION_RC=0 LC_ALL=C.UTF-8 \
bash "$SCRIPT" >/dev/null 2>&1 || fail "restore flow exited non-zero"
grep -qx 'original' "$HOME_DIR/.bashrc" || fail "restore did not recover .bashrc"
grep -qx 'original-starship' "$HOME_DIR/.config/starship.toml" || fail "restore did not recover starship config"
pass "user save/modify/restore flow"

# zenity 4.0.1 shows a literal "\n" in --no-markup dialogs: the closing dialog of the
# restore must reach it with a real line break after the first sentence (the question
# before it is checked by 12.55).
grep -qE -- '--info .*--text=Configuration restored\.$' "$TMP/restore/calls" \
    || fail "restore closing dialog does not break its lines (literal \\n?)"
pass "restore closing dialog breaks its lines"

# Manifest values round-trip through the non-evaluating %q parser.
MANIFEST_VALUE=$'line one\n100% $(not-a-command) \"quote\" \\path'
MANIFEST_Q=$(printf '%q' "$MANIFEST_VALUE")
MANIFEST_DECODED=$(HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 bash -c '
source "$1"
manifest_decode_q decoded "$2"
printf "%s" "$decoded"
' _ "$SCRIPT" "$MANIFEST_Q")
[ "$MANIFEST_DECODED" = "$MANIFEST_VALUE" ] || fail "manifest %q decoder did not preserve the original value"
pass "manifest %q decoding preserves arbitrary data"
# Bash printf %q uses backslash escaping for spaces and backslashes; the decoder must preserve both.
MANIFEST_ESCAPE_OUT=$(HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 \
    bash -c '
source "$1"
manifest_decode_q value "$2" || exit 1
printf "V:%s\n" "$value"
' _ "$SCRIPT" 'a\\\ b' 2>&1)
printf '%s\n' "$MANIFEST_ESCAPE_OUT" | grep -Fq 'V:a\ b' || fail "manifest %q backslash-space round-trip failed"
pass "manifest %q backslash escaping preserves data"

# With control characters printf %q writes $'...' (\' for a quote, \nnn for the
# rest). The decoder must give back exactly the same bytes: a quote next to a
# control character, and a control character followed by a digit (\0010 is \001
# then "0" there, but a different byte for printf %b).
cat > "$TMP/decode-cases.sh" <<'CASES'
cases=0; bad=0
check() {   # check VALUE
    local q decoded
    q=$(printf '%q' "$1"); cases=$((cases + 1))
    if manifest_decode_q decoded "$q" && [ "$decoded" = "$1" ]; then return 0; fi
    bad=$((bad + 1)); printf 'BAD %s -> %q\n' "$q" "${decoded-}"
}
check $'it\'s\ttab'            # quote and tab
check $'\'\n'                  # quote and newline
check $'a\\\'\tb'              # backslash, quote, tab
check $'\001\060'              # \001 followed by the digit 0
check $'\0017'                 # \001 followed by 7
check $'\0371'                 # \037 followed by 1
check $'\1771'                 # DEL followed by 1
check $'\001\002\003'          # consecutive octal escapes
check $'\0018'                 # \001 followed by 8 (not an octal digit)
check $'\xc3\xa9\'\t\xe6\x97\xa5'   # UTF-8 bytes, quote and tab
check $'tab\there'             # control character without a quote
check "plain"                  # no escapes at all
check ""                       # empty value
printf 'CASES=%s BAD=%s\n' "$cases" "$bad"
CASES
for locale in C.UTF-8 C; do
    DECODE_OUT=$(HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" LC_ALL=$locale MINT_SETUP_TEST=1 \
        bash -c 'source "$1"; source "$2"' _ "$SCRIPT" "$TMP/decode-cases.sh" 2>&1)
    printf '%s\n' "$DECODE_OUT" | grep -qx 'CASES=13 BAD=0' || fail "manifest %q decoder lost data in the \$'...' form ($locale): $DECODE_OUT"
done
pass "manifest %q decoding keeps quotes and control characters (\$'...' form)"

# End to end: the cleanup of the recovery copies reads its journal with the same
# decoder, so a copy whose name has a quote and a control character must go.
ODD_BAK="$HOME_DIR/it's"$'\t'"odd.mint-setup.bak"
printf 'old\n' > "$ODD_BAK"
mkdir -p "$CFG/mint-setup"
printf '%q\n' "$ODD_BAK" > "$CFG/mint-setup/recovery-copies.list"
HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" LC_ALL=C.UTF-8 MINT_SETUP_TEST=1 \
    bash -c 'source "$1"; uninstall_recovery_copies' _ "$SCRIPT" >/dev/null 2>&1
[ ! -e "$ODD_BAK" ] || fail "uninstall left a recovery copy whose name has a quote and a control character"
rm -f "$CFG/mint-setup/recovery-copies.list"
pass "recovery copy with a quote and a control character in its name is removed"

# An unreadable optional directory must be reported as a save failure instead
# of being mistaken for an empty directory.
HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 \
    bash -c '
source "$1"
SAVE_CONTEXT=1 SAVE_MODULE_FAILED=0
find() { return 13; }
mkdir -p "$2"
if pack_dir "$2" "$3"; then exit 1; fi
[ "$SAVE_MODULE_FAILED" -eq 1 ] || exit 2
' _ "$SCRIPT" "$TMP/blocked-dir" "$TMP/blocked.tar.gz" >/dev/null 2>&1 \
    || fail "pack_dir did not propagate directory enumeration failure"
pass "pack_dir propagates directory enumeration failures"

# A folder that is a symbolic link to another folder (stow, a folder on another
# partition) is saved by content under the link's own name. Before, find did not
# enter the link: pack_dir returned success, wrote nothing and warned nobody.
LP="$TMP/link-pack"
mkdir -p "$LP/real/sub" "$LP/home" "$LP/plain/d" "$LP/empty" "$LP/restored"
printf 'theme\n' > "$LP/real/sub/a.txt"
printf 'x\n' > "$LP/plain/d/f"
ln -s /nonexistent-target "$LP/real/dangling"   # inner link: must stay a link
ln -s ../real "$LP/home/.themes"
ln -s ../empty "$LP/home/.icons"
ln -s ../gone "$LP/home/.fonts"
lp_run() {   # lp_run 'code' ARG...: the program as a library, in the sandbox
    local code="$1"; shift
    HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 \
        bash -c 'source "$1"; code=$2; shift 2; SAVE_CONTEXT=1 SAVE_MODULE_FAILED=0
eval "$code"; rc=$?; [ "$SAVE_MODULE_FAILED" -eq 0 ] || rc=9; exit "$rc"' _ "$SCRIPT" "$code" "$@" >/dev/null 2>&1
}
# shellcheck disable=SC2016  # the code passed to lp_run is evaluated inside, on purpose
{
    if ! { lp_run 'pack_dir "$1" "$2"' "$LP/home/.themes" "$LP/themes.tar.gz" && [ -s "$LP/themes.tar.gz" ]; }; then
        fail "pack_dir skipped a symlinked folder without saving its content"
    fi
    tar -tzf "$LP/themes.tar.gz" 2>/dev/null | sed 's|/\./|/|' | grep -qx '\.themes/sub/a\.txt' \
        || fail "pack_dir did not store the content of a symlinked folder under the link's name"
    tar -tvzf "$LP/themes.tar.gz" 2>/dev/null | grep -q 'dangling -> /nonexistent-target' \
        || fail "pack_dir followed a link INSIDE a symlinked folder instead of storing it as a link"
    if ! { lp_run 'unpack_dir "$1" "$2"' "$LP/themes.tar.gz" "$LP/restored" \
            && [ -d "$LP/restored/.themes" ] && [ ! -L "$LP/restored/.themes" ] \
            && grep -qx theme "$LP/restored/.themes/sub/a.txt"; }; then
        fail "a folder saved through a symlink did not restore as a real folder with its content"
    fi
    if ! { lp_run 'pack_dir "$1" "$2"' "$LP/plain" "$LP/plain.tar.gz" \
            && [ "$(tar -tzf "$LP/plain.tar.gz" 2>/dev/null | tr '\n' ' ')" = "plain/ plain/d/ plain/d/f " ]; }; then
        fail "pack_dir changed the member names of an ordinary (non-link) folder"
    fi
    if ! { lp_run 'pack_dir "$1" "$2"' "$LP/home/.icons" "$LP/icons.tar.gz" && [ ! -e "$LP/icons.tar.gz" ]; }; then
        fail "pack_dir wrote an archive for a symlink to an EMPTY folder"
    fi
    if ! { lp_run 'pack_dir "$1" "$2"' "$LP/home/.fonts" "$LP/fonts.tar.gz" && [ ! -e "$LP/fonts.tar.gz" ]; }; then
        fail "pack_dir failed or wrote an archive for a DANGLING symlink"
    fi
}
pass "pack_dir saves a symlinked folder by content, as a real folder on restore"

# A crafted manifest must be parsed as data, never executed as shell code.
MALICIOUS_ROOT="$TMP/malicious-backups"; MALICIOUS_BACKUP="$MALICIOUS_ROOT/evil"; MARKER="$TMP/manifest-pwned"
mkdir -p "$MALICIOUS_BACKUP"
printf '%s\n' "NAME=\$(touch \"$MARKER\")" 'DATE=2026-10-07' 'MODULES=terminal' > "$MALICIOUS_BACKUP/manifest.conf"
MALICIOUS_OUT=$(HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$MALICIOUS_ROOT" MINT_SETUP_TEST=1 \
    MALICIOUS_BACKUP="$MALICIOUS_BACKUP" bash -c '
source "$1"
zenity() { printf "%s\n" "$MALICIOUS_BACKUP"; }
pick_backup_dir test
' _ "$SCRIPT")
[ ! -e "$MARKER" ] || fail "manifest parser executed injected shell code"
printf '%s\n' "$MALICIOUS_OUT" | grep -Fqx "$MALICIOUS_BACKUP" || fail "pick_backup_dir did not keep the selected malicious manifest as data"
pass "manifest parsing is non-executable"

# Restore propagates module failures instead of reporting a false success.
RESTORE_FAIL_BACKUP="$TMP/restore-failure-backup"; mkdir -p "$RESTORE_FAIL_BACKUP/terminal"
printf '%s\n' dummy > "$RESTORE_FAIL_BACKUP/terminal/marker"
RESTORE_FAIL_OUT=$(HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" \
    PATH="$MOCK:/usr/bin:/bin" LC_ALL=C.UTF-8 MINT_SETUP_TEST=1 RESTORE_FAIL_BACKUP="$RESTORE_FAIL_BACKUP" bash -c '
source "$1"
pick_backup_dir() { printf "%s\n" "$RESTORE_FAIL_BACKUP"; }
confirm() { return 0; }
root_preauth() { return 0; }
zenity() {
    case "$*" in
        *--list*) printf "terminal\n" ;;
        *--progress*) cat >/dev/null ;;
        *) : ;;
    esac
}
msg_error() { printf "ERROR:%s\n" "$1"; }
msg_warn() { printf "WARN:%s\n" "$1"; }
msg_info() { printf "INFO:%s\n" "$1"; }
log_msg() { :; }
restore_terminal() { return 17; }
set +e
do_restore
rc=$?
printf "RC:%s\n" "$rc"
exit "$rc"
' _ "$SCRIPT" 2>&1)
RESTORE_FAIL_RC=$?
[ "$RESTORE_FAIL_RC" -ne 0 ] || fail "failed restore unexpectedly returned success"
printf '%s\n' "$RESTORE_FAIL_OUT" | grep -Fq 'Terminal' || fail "failed restore did not identify the failed module"
pass "restore propagates module failures"

# 12.54: restore.log was the plain concatenation of what each module printed: no header said where
# one ended and the next began, nor how it exited, so "the Network block" could not be told apart.
# Each module now goes under "== <key>: exit <N> ==", in the order the modules finish.
RLOG_ROOT="$TMP/restore-log"; mkdir -p "$RLOG_ROOT/backup"
for rlog_mod in terminal keyboard mouse; do mkdir -p "$RLOG_ROOT/backup/$rlog_mod"; printf 'x\n' > "$RLOG_ROOT/backup/$rlog_mod/f"; done
HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" PATH="$MOCK:/usr/bin:/bin" \
    LC_ALL=C.UTF-8 MINT_SETUP_TEST=1 RLOG_ROOT="$RLOG_ROOT" bash -c '
source "$1"
pick_backup_dir() { printf "%s\n" "$RLOG_ROOT/backup"; }
confirm() { return 0; }
root_preauth() { return 0; }
zenity() { case "$*" in *--list*) printf "terminal,keyboard,mouse\n" ;; *--progress*) cat >/dev/null ;; esac; }
msg_error() { printf "%s\n" "$1" >> "$RLOG_ROOT/dialogs"; }
msg_warn() { printf "%s\n" "$1" >> "$RLOG_ROOT/dialogs"; }
msg_info() { printf "%s\n" "$1" >> "$RLOG_ROOT/dialogs"; }
printf "%s|%s\n" "$(T "${MODULE_SHORT_LABELS[terminal]}")" "$(T "${MODULE_SHORT_LABELS[mouse]}")" > "$RLOG_ROOT/labels"
restore_terminal() { printf "terminal one\nterminal two\n"; return 17; }
restore_keyboard() { printf "keyboard only\n"; }
restore_mouse() { printf "mouse marks it\n"; restore_mark_failed; }
do_restore' _ "$SCRIPT" >/dev/null 2>&1
rlog_block() {   # rlog_block FILE HEADER: the header and the lines under it, up to the next header
    awk -v h="$2" '$0 == h { on = 1; print; next } /^== .* ==$/ { on = 0 } on' "$1"
}
rlog_file="$RLOG_ROOT/backup/restore.log"
[ -f "$rlog_file" ] || fail "restore.log was not written"
[ "$(rlog_block "$rlog_file" '== terminal: exit 17 ==')" = $'== terminal: exit 17 ==\nterminal one\nterminal two' ] \
    || fail "restore.log: wrong block for a module that exits with 17: $(rlog_block "$rlog_file" '== terminal: exit 17 ==' | head -c 200)"
[ "$(rlog_block "$rlog_file" '== keyboard: exit 0 ==')" = $'== keyboard: exit 0 ==\nkeyboard only' ] \
    || fail "restore.log: wrong block for a module that exits with 0: $(rlog_block "$rlog_file" '== keyboard: exit 0 ==' | head -c 200)"
[ "$(rlog_block "$rlog_file" '== mouse: exit 1 ==')" = $'== mouse: exit 1 ==\nmouse marks it' ] \
    || fail "restore.log: wrong block for a module marked as failed (exit 1): $(rlog_block "$rlog_file" '== mouse: exit 1 ==' | head -c 200)"
[ "$(grep -c '^== ' "$rlog_file")" -eq 3 ] && [ "$(wc -l < "$rlog_file")" -eq 7 ] \
    || fail "restore.log: expected 3 headers and 7 lines, got $(grep -c '^== ' "$rlog_file") and $(wc -l < "$rlog_file"): $(head -c 300 "$rlog_file")"
# The closing warning still names BOTH failed modules (one exits with 17, the other with 1).
IFS='|' read -r rlog_l1 rlog_l2 < "$RLOG_ROOT/labels"
{ grep -Fq -- "$rlog_l1" "$RLOG_ROOT/dialogs" && grep -Fq -- "$rlog_l2" "$RLOG_ROOT/dialogs"; } \
    || fail "restore: the closing dialog does not name both failed modules ($rlog_l1, $rlog_l2): $(head -c 300 "$RLOG_ROOT/dialogs")"
pass "restore.log: each module goes under a header with its exit status (0, a code of its own, and a module marked as failed)"

# 12.55: the "restore ALL modules" warning of the restore confirmation reached the dialog with a
# literal "\n\n" in front of it (zenity 4.0.1 shows it as is with --no-markup). The warning went
# through T(), which does not expand line breaks, and was then inserted as DATA (%s) of T_FMT,
# which expands only those of its own template. The restore check above looks at the closing
# --info, never at this question. Here the question is captured through the real do_restore, in
# both languages: every module, a selection, and a backup saved on another distribution (a second
# warning). The expected texts are written out in full and independent of the catalog.
CONF_ROOT="$TMP/restore-confirm"
for conf_mod in terminal keyboard mouse; do mkdir -p "$CONF_ROOT/backup/$conf_mod"; printf 'x\n' > "$CONF_ROOT/backup/$conf_mod/f"; done
conf_run() {   # conf_run LANG SELECTION OS_ID RELEASE: prints the text of the question do_restore asks
    rm -f "$CONF_ROOT/question"
    { printf 'NAME=Demo\nDATE=2026-10-29\n'; printf 'OS_ID=%q\nMINT_RELEASE=%q\n' "$3" "$4"; } > "$CONF_ROOT/backup/manifest.conf"
    HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" PATH="$MOCK:/usr/bin:/bin" \
        LC_ALL=C.UTF-8 MINT_SETUP_TEST=1 CONF_ROOT="$CONF_ROOT" CONF_SEL="$2" bash -c '
source "$1"
set_language "$2"
PLATFORM_OS_ID=linuxmint; PLATFORM_NAME="Linux Mint 22.3"
pick_backup_dir() { printf "%s\n" "$CONF_ROOT/backup"; }
confirm() { printf "%s" "$1" > "$CONF_ROOT/question"; return 0; }
root_preauth() { return 0; }
zenity() { case "$*" in *--list*) printf "%s\n" "$CONF_SEL" ;; *--progress*) cat >/dev/null ;; esac; }
msg_error() { :; }; msg_warn() { :; }; msg_info() { :; }; log_msg() { :; }
restore_terminal() { :; }; restore_keyboard() { :; }; restore_mouse() { :; }
do_restore' _ "$SCRIPT" "$1" >/dev/null 2>&1
    [ -f "$CONF_ROOT/question" ] || fail "restore question ($1, $2, $3): do_restore never asked it"
    cat "$CONF_ROOT/question"
}
W_SIGN=$'⚠️'
EN_HEAD=$'You are about to restore the following to your current system:\n\n'
EN_MID=$'\n\nThis will overwrite the current configuration of those modules.'
EN_ALL=$'\n\n@@ You are about to restore ALL modules: it may take a long time (Applications, VS Code and large browser/mail profiles take the longest) and you may be asked for the administrator password more than once.'
EN_OTHER=$'\n\n@@ This backup was saved on “Ubuntu 24.04” and this system is “Linux Mint 22.3”. Distribution-specific modules (Applications, Cinnamon, Nemo) may not apply or may apply only partially.'
EN_TAIL=$'\n\nContinue?'
ES_HEAD=$'Vas a restaurar lo siguiente sobre tu sistema actual:\n\n'
ES_MID=$'\n\nEsto sobrescribirá la configuración actual de esos módulos.'
ES_ALL=$'\n\n@@ Vas a restaurar TODOS los módulos: puede tardar bastante (Aplicaciones, VS Code o perfiles grandes de navegador/correo son los que más) y es posible que se te pida la contraseña de administrador más de una vez durante el proceso.'
ES_OTHER=$'\n\n@@ Esta configuración se guardó en «Ubuntu 24.04» y este sistema es «Linux Mint 22.3». Los módulos ligados a la distribución (Aplicaciones, Cinnamon, Nemo) pueden no aplicarse o hacerlo solo en parte.'
ES_TAIL=$'\n\n¿Deseas continuar?'
EN_ALL=${EN_ALL//@@/$W_SIGN}; EN_OTHER=${EN_OTHER//@@/$W_SIGN}; ES_ALL=${ES_ALL//@@/$W_SIGN}; ES_OTHER=${ES_OTHER//@@/$W_SIGN}
for conf_lang in en es; do
    if [ "$conf_lang" = en ]; then
        c_head=$EN_HEAD; c_mid=$EN_MID; c_all=$EN_ALL; c_other=$EN_OTHER; c_tail=$EN_TAIL; c_two='Terminal, Keyboard'; c_three='Terminal, Keyboard, Mouse'
    else
        c_head=$ES_HEAD; c_mid=$ES_MID; c_all=$ES_ALL; c_other=$ES_OTHER; c_tail=$ES_TAIL; c_two='Terminal, Teclado'; c_three='Terminal, Teclado, Ratón'
    fi
    # every module of the backup (3 of 3): the warning in its own paragraph
    conf_got=$(conf_run "$conf_lang" terminal,keyboard,mouse linuxmint 'Linux Mint 22.3')
    [ "$conf_got" = "$c_head$c_three$c_mid$c_all$c_tail" ] \
        || fail "restore question ($conf_lang, all modules): wrong text: $conf_got"
    # a selection (2 of 3): no warning at all
    conf_got=$(conf_run "$conf_lang" terminal,keyboard linuxmint 'Linux Mint 22.3')
    [ "$conf_got" = "$c_head$c_two$c_mid$c_tail" ] \
        || fail "restore question ($conf_lang, a selection): wrong text: $conf_got"
    # a backup from another distribution: the second warning follows the first, also as its own paragraph
    conf_got=$(conf_run "$conf_lang" terminal,keyboard,mouse ubuntu 'Ubuntu 24.04')
    [ "$conf_got" = "$c_head$c_three$c_mid$c_all$c_other$c_tail" ] \
        || fail "restore question ($conf_lang, another distribution): wrong text: $conf_got"
    conf_got=$(conf_run "$conf_lang" terminal ubuntu 'Ubuntu 24.04')
    [ "$conf_got" = "${c_head}Terminal$c_mid$c_other$c_tail" ] \
        || fail "restore question ($conf_lang, a selection from another distribution): wrong text: $conf_got"
    # whatever the text is, a backslash in it is a line break that did not get expanded
    case "$conf_got" in *\\*) fail "restore question ($conf_lang): literal backslash in the dialog text: $conf_got" ;; esac
done
pass "restore question: the warnings go in their own paragraph, without a literal \\n (es/en; all modules, a selection, another distribution)"

# The retry of a transient "Not authorized" (12.53) relies on PKEXEC_AGENT_SEEN, which root_preauth sets
# in the main process, reaching the subshells where do_restore runs the modules; prun alone was tested,
# this goes through do_restore, the real root_preauth and a pkexec stub: the 1st call (the preauth) works,
# then the module's call is denied and its retry works, or is denied for good.
RETRY_ROOT="$TMP/restore-retry"; mkdir -p "$RETRY_ROOT/bin" "$RETRY_ROOT/backup/network"
printf 'x\n' > "$RETRY_ROOT/backup/network/f"
cat > "$RETRY_ROOT/bin/pkexec" <<'STUBEOF'
#!/bin/sh
# Stub: call n takes the n-th word of $PKE_OUTCOMES (ok | denied); the calls are counted in $PKE_COUNT.
n=$(( $(cat "$PKE_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$PKE_COUNT"
set -- $PKE_OUTCOMES
[ "$n" -gt 1 ] && shift $((n - 1))
if [ "${1:-ok}" = denied ]; then
    echo "Error executing command as another user: Not authorized" >&2
    printf '\nThis incident has been reported.\n' >&2
    exit 127
fi
exit 0
STUBEOF
chmod +x "$RETRY_ROOT/bin/pkexec"
retry_run() {   # retry_run CASE "outcomes": do_restore of a Network module that calls prun once
    local dir="$RETRY_ROOT/$1"; mkdir -p "$dir"
    HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" PATH="$RETRY_ROOT/bin:$MOCK:/usr/bin:/bin" \
        LC_ALL=C.UTF-8 MINT_SETUP_TEST=1 RETRY_BACKUP="$RETRY_ROOT/backup" RETRY_DIR="$dir" PKE_COUNT="$dir/calls" PKE_OUTCOMES="$2" bash -c '
source "$1"
PKEXEC_DENIED_WAIT=0
pick_backup_dir() { printf "%s\n" "$RETRY_BACKUP"; }
confirm() { return 0; }
zenity() { case "$*" in *--list*) printf "network\n" ;; *--progress*) cat >/dev/null ;; esac; }
msg_error() { printf "%s\n" "$1" >> "$RETRY_DIR/problems"; }
msg_warn() { printf "%s\n" "$1" >> "$RETRY_DIR/problems"; }
msg_info() { printf "%s\n" "$1" >> "$RETRY_DIR/info"; }
restore_network() { prun true || return 1; printf "network done\n"; }
do_restore' _ "$SCRIPT" >/dev/null 2>&1
    cp "$RETRY_ROOT/backup/restore.log" "$dir/restore.log" 2>/dev/null
}
retry_run works "ok denied ok"
[ "$(cat "$RETRY_ROOT/works/calls" 2>/dev/null)" = 3 ] \
    || fail "restore retry: expected 3 pkexec calls (preauth, denied, retry), got $(cat "$RETRY_ROOT/works/calls" 2>/dev/null)"
[ "$(cat "$RETRY_ROOT/works/restore.log" 2>/dev/null)" = $'== network: exit 0 ==\nnetwork done' ] && [ ! -e "$RETRY_ROOT/works/problems" ] \
    || fail "restore retry: the module did not end well after the retry: $(head -c 300 "$RETRY_ROOT/works/restore.log") / $(head -c 200 "$RETRY_ROOT/works/problems" 2>/dev/null)"
retry_run spent "ok denied denied denied"
[ "$(cat "$RETRY_ROOT/spent/calls" 2>/dev/null)" = 4 ] \
    || fail "restore retry: expected 4 pkexec calls (preauth, denied, two retries), got $(cat "$RETRY_ROOT/spent/calls" 2>/dev/null)"
[ "$(rlog_block "$RETRY_ROOT/spent/restore.log" '== network: exit 1 ==' | sed -n '2p')" = 'Error executing command as another user: Not authorized' ] && [ -s "$RETRY_ROOT/spent/problems" ] \
    || fail "restore retry: a spent retry should leave the module failed with pkexec's message under its header: $(head -c 300 "$RETRY_ROOT/spent/restore.log")"
pass "do_restore: the retry of a transient \"Not authorized\" reaches the modules (the preauth's PKEXEC_AGENT_SEEN is inherited); with the retries spent the module fails under its header"

# A module that weighs 0 bytes (du reports 0 for an empty folder on btrfs) or
# whose size cannot be read must not break the ETA: bytes_done, its divisor,
# stayed at 0 when that module finished first after the first 2 s, and bash
# aborted do_restore with "division by 0" while the other module still ran.
ETA_ROOT="$TMP/eta-zero"; mkdir -p "$ETA_ROOT/backup/terminal" "$ETA_ROOT/backup/keyboard"
printf 'x\n' > "$ETA_ROOT/backup/keyboard/f"
run_eta_zero() {   # run_eta_zero CASE DU_OUTPUT_FOR_TERMINAL
    local case_dir="$ETA_ROOT/$1"; mkdir -p "$case_dir"
    HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" PATH="$MOCK:/usr/bin:/bin" \
        LC_ALL=C.UTF-8 MINT_SETUP_TEST=1 ETA_BACKUP="$ETA_ROOT/backup" ETA_DU="$2" ETA_MARK="$case_dir/keyboard-done" bash -c '
source "$1"
pick_backup_dir() { printf "%s\n" "$ETA_BACKUP"; }
confirm() { return 0; }
root_preauth() { return 0; }
zenity() {
    case "$*" in
        *--list*) printf "terminal,keyboard\n" ;;
        *--progress*) cat >/dev/null ;;
    esac
}
du() { case "$2" in */terminal) [ -n "$ETA_DU" ] && printf "%s\t%s\n" "$ETA_DU" "$2" ;; *) printf "100000\t%s\n" "$2" ;; esac; }
msg_error() { printf "ERROR:%s\n" "$1"; }
msg_warn() { printf "WARN:%s\n" "$1"; }
# T_FMT turns the \n of a message into real line breaks: keep one INFO line per message.
msg_info() { local nl; printf -v nl "\n"; printf "INFO:%s\n" "${1//$nl/ }"; }
log_msg() { :; }
restore_terminal() { sleep 2.2; }
restore_keyboard() { sleep 3; : > "$ETA_MARK"; }
set +e
do_restore
printf "RC:%s\n" "$?"
' _ "$SCRIPT" > "$case_dir/out" 2>&1
}
run_eta_zero zero 0 & run_eta_zero empty "" & run_eta_zero text "n/a" &
wait
for eta_case in zero empty text; do
    grep -qx 'RC:0' "$ETA_ROOT/$eta_case/out" || fail "restore with a ${eta_case}-size module did not return 0: $(cat "$ETA_ROOT/$eta_case/out")"
    grep -q 'division by 0' "$ETA_ROOT/$eta_case/out" && fail "restore with a ${eta_case}-size module hit a division by zero"
    [ -e "$ETA_ROOT/$eta_case/keyboard-done" ] || fail "restore with a ${eta_case}-size module stopped before the other module finished"
    ! grep -qv -e '^INFO:' -e '^RC:0$' "$ETA_ROOT/$eta_case/out" || fail "restore with a ${eta_case}-size module printed unexpected output: $(cat "$ETA_ROOT/$eta_case/out")"
done
pass "restore ETA survives modules of 0 bytes or unreadable size"

# "software" can end in the very turn that empties the list of running modules,
# right after the check that launches the deferred ones. VS Code and Docker
# (which wait for it) were then never started and the restore still reported
# success. DEF_MODE=race forces that turn: software looks alive to the check and
# is gone right after. DEF_MODE=overlap is the ordinary case: software ends while
# Terminal still runs, and they must start then, not once everything is over.
DEF_ROOT="$TMP/restore-deferred"; mkdir -p "$DEF_ROOT/backup"
for def_mod in software vscode docker terminal; do
    mkdir -p "$DEF_ROOT/backup/$def_mod"; printf 'x\n' > "$DEF_ROOT/backup/$def_mod/f"
done
cat > "$DEF_ROOT/harness.sh" <<'HARNESS'
source "$1"
pick_backup_dir() { printf "%s\n" "$DEF_BACKUP"; }
confirm() { return 0; }
root_preauth() { return 0; }
zenity() {
    case "$*" in
        *--list*) printf "%s\n" "$DEF_MODULES" ;;
        *--progress*) cat >/dev/null ;;
    esac
}
msg_error() { printf "ERROR:%s\n" "$1"; }
msg_warn() { printf "WARN:%s\n" "$1"; }
# T_FMT turns the \n of a message into real line breaks: keep one INFO line per message.
msg_info() { local nl; printf -v nl "\n"; printf "INFO:%s\n" "${1//$nl/ }"; }
log_msg() { :; }
def_state() { if [ -e "$DEF_DIR/$1-done" ]; then printf done; else printf pending; fi; }
restore_software() {
    printf "%s" "$BASHPID" > "$DEF_DIR/software-pid"
    if [ "$DEF_MODE" = race ]; then while [ ! -e "$DEF_DIR/go" ]; do sleep 0.01; done; else sleep 0.8; fi
    : > "$DEF_DIR/software-done"
}
restore_terminal() {   # ends only once both deferred modules have started (10 s at most)
    local i
    for i in {1..200}; do [ -e "$DEF_DIR/vscode" ] && [ -e "$DEF_DIR/docker" ] && break; sleep 0.05; done
    : > "$DEF_DIR/terminal-done"
}
restore_vscode() { printf "software=%s terminal=%s\n" "$(def_state software)" "$(def_state terminal)" > "$DEF_DIR/vscode"; }
restore_docker() { printf "software=%s terminal=%s\n" "$(def_state software)" "$(def_state terminal)" > "$DEF_DIR/docker"; }
kill() {   # race: the first look at software says alive, and it is gone right after
    if [ "$DEF_MODE" = race ] && [ "${1-}" = -0 ] && [ "${2-}" = "$(cat "$DEF_DIR/software-pid" 2>/dev/null)" ] && [ ! -e "$DEF_DIR/seen" ]; then
        : > "$DEF_DIR/seen"; : > "$DEF_DIR/go"
        while builtin kill -0 "$2" 2>/dev/null; do sleep 0.01; done
        return 0
    fi
    builtin kill "$@"
}
set +e
do_restore
printf "RC:%s\n" "$?"
HARNESS
DEF_TIMEOUT=""; command -v timeout >/dev/null 2>&1 && DEF_TIMEOUT="timeout -k 2 30"   # a loop that never ends must fail, not hang
run_restore_deferred() {   # run_restore_deferred MODE MODULES
    local case_dir="$DEF_ROOT/$1"; mkdir -p "$case_dir"
    # shellcheck disable=SC2086  # $DEF_TIMEOUT is intentionally several words
    HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" PATH="$MOCK:/usr/bin:/bin" \
        LC_ALL=C.UTF-8 MINT_SETUP_TEST=1 DEF_BACKUP="$DEF_ROOT/backup" DEF_DIR="$case_dir" DEF_MODE="$1" DEF_MODULES="$2" \
        $DEF_TIMEOUT bash "$DEF_ROOT/harness.sh" "$SCRIPT" > "$case_dir/out" 2>&1
    printf 'EXIT:%s\n' "$?" >> "$case_dir/out"
}
run_restore_deferred race "software,vscode,docker" &
run_restore_deferred overlap "software,vscode,docker,terminal" &
wait
for def_case in race overlap; do
    def_out="$DEF_ROOT/$def_case/out"
    grep -qx 'EXIT:0' "$def_out" || fail "restore ($def_case) did not finish cleanly: $(cat "$def_out")"
    grep -qx 'RC:0' "$def_out" || fail "restore ($def_case) did not return 0: $(cat "$def_out")"
    for def_mod in vscode docker; do
        [ "$(cat "$DEF_ROOT/$def_case/$def_mod" 2>/dev/null)" = 'software=done terminal=pending' ] \
            || fail "restore ($def_case): $def_mod did not start right after software ended (saw: $(cat "$DEF_ROOT/$def_case/$def_mod" 2>/dev/null || echo 'never started'))"
    done
    [ "$(grep -c '^INFO:' "$def_out")" = 1 ] || fail "restore ($def_case) did not report success once: $(cat "$def_out")"
    ! grep -qv -e '^INFO:' -e '^RC:0$' -e '^EXIT:0$' "$def_out" || fail "restore ($def_case) printed unexpected output: $(cat "$def_out")"
done
[ -e "$DEF_ROOT/race/seen" ] || fail "the race case did not force the window it tests"
[ -e "$DEF_ROOT/overlap/terminal-done" ] || fail "the overlap case did not wait for Terminal"
pass "restore starts VS Code and Docker after Applications even when it ends in the turn that empties the list"

# 12.29: Displays restores LAST and alone. It changes the resolution, and in a real
# full restore the privileged modules (Network, Bluetooth, Applications), which
# have PolicyKit dialogs open at that moment, failed. Every stand-in module
# appends its start and end to one file, in order; the assertions read that
# order. LST_MODE: all | alone | other-fails | displays-fails | cancel (the
# progress window closes at 1 s, with Applications still running).
LST_ROOT="$TMP/restore-last"; mkdir -p "$LST_ROOT/backup"
for lst_mod in software vscode docker terminal network bluetooth displays; do
    mkdir -p "$LST_ROOT/backup/$lst_mod"; printf 'x\n' > "$LST_ROOT/backup/$lst_mod/f"
done
cat > "$LST_ROOT/harness.sh" <<'HARNESS'
source "$1"
set_language en
pick_backup_dir() { printf "%s\n" "$LST_BACKUP"; }
confirm() { return 0; }
root_preauth() { return 0; }
zenity() {
    case "$*" in
        *--list*) printf "%s\n" "$LST_MODULES" ;;
        *--progress*) if [ "$LST_MODE" = cancel ]; then sleep 1; else cat >/dev/null; fi ;;
    esac
}
msg_error() { printf "ERROR:%s\n" "$1"; }
msg_warn() { printf "WARN:%s\n" "$1"; }
msg_info() { printf "INFO:%s\n" "$1"; }
log_msg() { :; }
lst_run() {   # lst_run NAME SECONDS RC
    printf 'start %s\n' "$1" >> "$LST_DIR/events"
    sleep "$2"
    printf 'end %s\n' "$1" >> "$LST_DIR/events"
    return "$3"
}
lst_rc() { if [ "$LST_MODE" = "$1" ]; then printf 1; else printf 0; fi; }
restore_software() { if [ "$LST_MODE" = cancel ]; then lst_run software 3 0; else lst_run software 0.8 0; fi; }
restore_vscode() { lst_run vscode 0.2 0; }
restore_docker() { lst_run docker 0.2 0; }
restore_terminal() { lst_run terminal 0.3 0; }
restore_network() { lst_run network 0.4 "$(lst_rc other-fails)"; }
restore_bluetooth() { lst_run bluetooth 0.5 0; }
restore_displays() { lst_run displays 0.2 "$(lst_rc displays-fails)"; }
set +e
do_restore
printf "RC:%s\n" "$?"
HARNESS
LST_TIMEOUT=""; command -v timeout >/dev/null 2>&1 && LST_TIMEOUT="timeout -k 2 30"   # a loop that never ends must fail, not hang
run_restore_last() {   # run_restore_last MODE MODULES
    local case_dir="$LST_ROOT/$1"; mkdir -p "$case_dir"
    # shellcheck disable=SC2086  # $LST_TIMEOUT is intentionally several words
    HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" PATH="$MOCK:/usr/bin:/bin" \
        LC_ALL=C.UTF-8 MINT_SETUP_TEST=1 LST_BACKUP="$LST_ROOT/backup" LST_DIR="$case_dir" LST_MODE="$1" LST_MODULES="$2" \
        $LST_TIMEOUT bash "$LST_ROOT/harness.sh" "$SCRIPT" > "$case_dir/out" 2>&1
    printf 'EXIT:%s\n' "$?" >> "$case_dir/out"
}
LST_ALL="software,vscode,docker,terminal,network,bluetooth,displays"
run_restore_last all "$LST_ALL" &
run_restore_last alone "displays" &
run_restore_last other-fails "$LST_ALL" &
run_restore_last displays-fails "$LST_ALL" &
run_restore_last cancel "$LST_ALL" &
wait
lst_index() {   # lst_index EVENT [FROM] -> first index >= FROM of the exact line EVENT in lst_ev
    local i
    for (( i = ${2:-0}; i < ${#lst_ev[@]}; i++ )); do
        if [ "${lst_ev[$i]}" = "$1" ]; then printf '%s' "$i"; return 0; fi
    done
    return 1
}
for lst_case in all alone other-fails displays-fails; do
    lst_out="$LST_ROOT/$lst_case/out"; mapfile -t lst_ev < "$LST_ROOT/$lst_case/events"
    lst_sd=$(lst_index 'start displays') || fail "restore ($lst_case): Displays never started: $(cat "$lst_out")"
    lst_ed=$(lst_index 'end displays') || fail "restore ($lst_case): Displays never ended"
    if [ "$lst_ed" != "$((lst_sd + 1))" ]; then fail "restore ($lst_case): something ran while Displays did (events: ${lst_ev[*]})"; fi
    if [ "$(printf '%s\n' "${lst_ev[@]}" | grep -c '^start displays$')" != 1 ]; then fail "restore ($lst_case): Displays started more than once"; fi
    # every other module has ended before Displays starts
    lst_last_end=-1
    for lst_i in "${!lst_ev[@]}"; do
        case "${lst_ev[$lst_i]}" in
            "end displays") ;;
            "end "*) lst_last_end=$lst_i ;;
            "start "*) if [ "${lst_ev[$lst_i]}" != "start displays" ] && [ "$lst_i" -gt "$lst_sd" ]; then fail "restore ($lst_case): ${lst_ev[$lst_i]} started after Displays"; fi ;;
        esac
    done
    if [ "$lst_last_end" -gt "$lst_sd" ]; then fail "restore ($lst_case): a module ended after Displays started (events: ${lst_ev[*]})"; fi
    if [ "$lst_case" != alone ] && [ "$(printf '%s\n' "${lst_ev[@]}" | grep -c '^end ')" != 7 ]; then fail "restore ($lst_case): not all seven modules ran (events: ${lst_ev[*]})"; fi
    grep -qx 'EXIT:0' "$lst_out" || fail "restore ($lst_case) did not finish cleanly: $(cat "$lst_out")"
done
grep -qx 'RC:0' "$LST_ROOT/all/out" || fail "restore (all) did not return 0: $(cat "$LST_ROOT/all/out")"
grep -qx 'RC:0' "$LST_ROOT/alone/out" || fail "restore (alone) did not return 0: $(cat "$LST_ROOT/alone/out")"
if [ "$(grep -c '^INFO:' "$LST_ROOT/all/out")" != 1 ]; then fail "restore (all) did not report success once: $(cat "$LST_ROOT/all/out")"; fi
grep -qx 'RC:1' "$LST_ROOT/other-fails/out" || fail "restore (other-fails) did not return 1: $(cat "$LST_ROOT/other-fails/out")"
grep -Fq 'WARN:The restore finished with errors.' "$LST_ROOT/other-fails/out" || fail "restore (other-fails): no error dialog"
grep -Fq 'Completed modules: 6 of 7, but these failed: Network.' "$LST_ROOT/other-fails/out" || fail "restore (other-fails): wrong counts or module: $(cat "$LST_ROOT/other-fails/out")"
grep -qx 'RC:1' "$LST_ROOT/displays-fails/out" || fail "restore (displays-fails) did not return 1: $(cat "$LST_ROOT/displays-fails/out")"
grep -Fq 'Completed modules: 6 of 7, but these failed: Displays.' "$LST_ROOT/displays-fails/out" || fail "restore (displays-fails): wrong counts or module: $(cat "$LST_ROOT/displays-fails/out")"
# Cancelled while Applications still runs: Displays (and the modules waiting for Applications) never start.
mapfile -t lst_ev < "$LST_ROOT/cancel/events"
if printf '%s\n' "${lst_ev[@]}" | grep -q -e '^start displays$' -e '^start vscode$' -e '^start docker$'; then fail "restore (cancel): a module that was waiting started anyway (events: ${lst_ev[*]})"; fi
grep -qx 'RC:0' "$LST_ROOT/cancel/out" || fail "restore (cancel) did not return 0: $(cat "$LST_ROOT/cancel/out")"
grep -Fq 'WARN:Restore cancelled.' "$LST_ROOT/cancel/out" || fail "restore (cancel): no cancellation dialog: $(cat "$LST_ROOT/cancel/out")"
pass "restore runs Displays last and alone (after every other module; never if cancelled; failures reported)"

# A failed atomic file replacement inside an otherwise-returning restore module
# must also make the module fail, while preserving the previous destination.
ATOMIC_RESTORE_BIN="$TMP/atomic-restore-bin"; mkdir -p "$ATOMIC_RESTORE_BIN"
cat > "$ATOMIC_RESTORE_BIN/cp" <<'CPRESTOREFail'
#!/bin/bash
target="${@: -1}"
printf 'partial\n' > "$target"
exit 7
CPRESTOREFail
chmod +x "$ATOMIC_RESTORE_BIN/cp"
ATOMIC_RESTORE_HOME="$TMP/restore-atomic-home"; ATOMIC_RESTORE_CFG="$TMP/restore-atomic-cfg"; ATOMIC_RESTORE_BACKUP="$TMP/restore-atomic-backup"
mkdir -p "$ATOMIC_RESTORE_HOME" "$ATOMIC_RESTORE_CFG" "$ATOMIC_RESTORE_BACKUP/terminal"
printf 'original-atomic\n' > "$ATOMIC_RESTORE_HOME/.bashrc"
printf 'saved-atomic\n' > "$ATOMIC_RESTORE_BACKUP/terminal/.bashrc"
ATOMIC_RESTORE_OUT=$(HOME="$ATOMIC_RESTORE_HOME" XDG_CONFIG_HOME="$ATOMIC_RESTORE_CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" \
    PATH="$ATOMIC_RESTORE_BIN:$MOCK:/usr/bin:/bin" LC_ALL=C.UTF-8 MINT_SETUP_TEST=1 \
    ATOMIC_RESTORE_BACKUP="$ATOMIC_RESTORE_BACKUP" bash -c '
source "$1"
set_language en
MINT_SETUP_TEST=1
run_restore_module terminal "$ATOMIC_RESTORE_BACKUP"
' _ "$SCRIPT" 2>&1)
ATOMIC_RESTORE_RC=$?
[ "$ATOMIC_RESTORE_RC" -ne 0 ] || fail "atomic restore failure unexpectedly returned success: $ATOMIC_RESTORE_OUT"
grep -qx 'original-atomic' "$ATOMIC_RESTORE_HOME/.bashrc" || fail "atomic restore failure replaced previous file"
find "$ATOMIC_RESTORE_HOME" -name '.*.mstmp.*' -print -quit | grep -q . && fail "atomic restore failure left temporary file"
pass "restore propagates atomic file failures"

# A user-edited destination must be backed up without overwriting previous
# recovery copies, and a second restore must create .bak.1 rather than replace
# the first backup.
KEEP_BAK_ROOT="$TMP/atomic-copy-keep-bak"
mkdir -p "$KEEP_BAK_ROOT"
printf 'current-one\n' > "$KEEP_BAK_ROOT/source"
printf 'edited-one\n' > "$KEEP_BAK_ROOT/dest"
if HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 \
    bash -c 'source "$1"; atomic_copy_keep_bak "$2/source" "$2/dest"' _ "$SCRIPT" "$KEEP_BAK_ROOT"; then
    :
else
    fail "atomic_copy_keep_bak failed during the first replacement"
fi
grep -qx 'current-one' "$KEEP_BAK_ROOT/dest" || fail "atomic_copy_keep_bak did not publish the new destination"
grep -qx 'edited-one' "$KEEP_BAK_ROOT/dest.mint-setup.bak" || fail "atomic_copy_keep_bak did not preserve the edited destination"
printf 'current-two\n' > "$KEEP_BAK_ROOT/source"
if HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 \
    bash -c 'source "$1"; atomic_copy_keep_bak "$2/source" "$2/dest"' _ "$SCRIPT" "$KEEP_BAK_ROOT"; then
    :
else
    fail "atomic_copy_keep_bak failed during the second replacement"
fi
grep -qx 'current-two' "$KEEP_BAK_ROOT/dest" || fail "atomic_copy_keep_bak did not publish the second destination"
grep -qx 'current-one' "$KEEP_BAK_ROOT/dest.mint-setup.bak.1" || fail "atomic_copy_keep_bak overwrote the previous recovery copy"
pass "restore backups preserve prior recovery copies"

# unpack_dir must expose extraction failures instead of converting them into success.
UNPACK_FAIL_ROOT="$TMP/unpack-dir-failure"
mkdir -p "$UNPACK_FAIL_ROOT/target"
printf 'before\n' > "$UNPACK_FAIL_ROOT/target/keep.txt"
printf '%s' 'not-a-valid-tarball' > "$UNPACK_FAIL_ROOT/broken.tar.gz"
# Positive control first: the same harness must succeed on a valid archive, so
# a failure below can only come from unpack_dir itself, never from the harness.
mkdir -p "$UNPACK_FAIL_ROOT/good-src" "$UNPACK_FAIL_ROOT/good-target"
printf 'fresh\n' > "$UNPACK_FAIL_ROOT/good-src/new.txt"
tar czf "$UNPACK_FAIL_ROOT/good.tar.gz" -C "$UNPACK_FAIL_ROOT/good-src" new.txt
HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 \
    bash -c 'source "$1" && unpack_dir "$2" "$3"' _ "$SCRIPT" "$UNPACK_FAIL_ROOT/good.tar.gz" "$UNPACK_FAIL_ROOT/good-target" >/dev/null 2>&1 \
    || fail "unpack_dir harness control: a valid archive was not extracted"
grep -qx 'fresh' "$UNPACK_FAIL_ROOT/good-target/new.txt" || fail "unpack_dir harness control: extracted content is missing"
if HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 \
    bash -c 'source "$1" && unpack_dir "$2" "$3"' _ "$SCRIPT" "$UNPACK_FAIL_ROOT/broken.tar.gz" "$UNPACK_FAIL_ROOT/target" >/dev/null 2>&1; then
    fail "unpack_dir returned success for a corrupt archive"
fi
grep -qx 'before' "$UNPACK_FAIL_ROOT/target/keep.txt" || fail "unpack_dir corrupt archive altered an existing file"
find "$UNPACK_FAIL_ROOT/target" -name '.*.mstmp.*' -print -quit | grep -q . && fail "unpack_dir corrupt archive left a temporary"
pass "unpack_dir propagates extraction failures"

# A symlink created by one archive must never turn a later archive merge into
# a write through that symlink. This mirrors the untrusted multi-archive case
# warned about by GNU tar: every archive is staged separately, but the final
# merge must also refuse symlink destinations.
SYMLINK_MERGE_ROOT="$TMP/symlink-merge"
mkdir -p "$SYMLINK_MERGE_ROOT/archive1/evil" "$SYMLINK_MERGE_ROOT/archive2/evil" "$SYMLINK_MERGE_ROOT/target" "$SYMLINK_MERGE_ROOT/outside"
ln -s "$SYMLINK_MERGE_ROOT/outside" "$SYMLINK_MERGE_ROOT/target/evil"
printf 'must-stay-outside\n' > "$SYMLINK_MERGE_ROOT/outside/keep.txt"
printf 'must-not-escape\n' > "$SYMLINK_MERGE_ROOT/archive2/evil/pwned.txt"
tar czf "$SYMLINK_MERGE_ROOT/second.tar.gz" -C "$SYMLINK_MERGE_ROOT/archive2" evil
# Positive control: the same call into a clean target must succeed.
mkdir -p "$SYMLINK_MERGE_ROOT/clean-target"
HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 \
    bash -c 'source "$1" && safe_extract "$2" "$3"' _ "$SCRIPT" "$SYMLINK_MERGE_ROOT/second.tar.gz" "$SYMLINK_MERGE_ROOT/clean-target" >/dev/null 2>&1 \
    || fail "safe_extract harness control: a valid archive was not extracted"
[ -f "$SYMLINK_MERGE_ROOT/clean-target/evil/pwned.txt" ] || fail "safe_extract harness control: extracted content is missing"
if HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 \
    bash -c 'source "$1" && safe_extract "$2" "$3"' _ "$SCRIPT" "$SYMLINK_MERGE_ROOT/second.tar.gz" "$SYMLINK_MERGE_ROOT/target" >/dev/null 2>&1; then
    fail "safe_extract followed an existing destination symlink during merge"
fi
grep -qx 'must-stay-outside' "$SYMLINK_MERGE_ROOT/outside/keep.txt" || fail "symlink merge altered the outside target"
[ ! -e "$SYMLINK_MERGE_ROOT/outside/pwned.txt" ] || fail "symlink merge wrote outside the restore tree"
pass "archive merge refuses destination symlinks"

# A clash at the destination (a file where the archive brings a folder, or a link to
# a folder) leaves what did NOT clash applied. The warning must say so instead of
# "skipped without touching your current configuration", and the flag that selects
# it must not leak into the next warning (a corrupt archive keeps the "damaged" text).
PM="$TMP/partial-merge"
mkdir -p "$PM/src/top/a" "$PM/src/top/b" "$PM/dest/top" "$PM/stow/real" "$PM/stow/home"
printf 'x\n' > "$PM/src/top/a/x"; printf 'y\n' > "$PM/src/top/b/y"
tar czf "$PM/top.tar.gz" -C "$PM/src" top
printf 'mine\n' > "$PM/dest/top/b"
ln -s ../real "$PM/stow/home/.themes"
pm_run() {   # pm_run LANG ARCHIVE PARENT: unpack it, then a corrupt archive; prints both results
    HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 \
        bash -c 'source "$1"; APP_LANG=$2; RESTORE_CONTEXT=1 RESTORE_MODULE_FAILED=0
unpack_dir "$3" "$4"; printf "rc=%s failed=%s\n" "$?" "$RESTORE_MODULE_FAILED"
RESTORE_MODULE_FAILED=0; unpack_dir "$5" "$6"; printf "rc=%s failed=%s\n" "$?" "$RESTORE_MODULE_FAILED"' \
        _ "$SCRIPT" "$1" "$2" "$3" "$UNPACK_FAIL_ROOT/broken.tar.gz" "$UNPACK_FAIL_ROOT/target" 2>&1
}
PM_EN=$(pm_run en "$PM/top.tar.gz" "$PM/dest")
PM_ES=$(pm_run es "$PM/top.tar.gz" "$PM/dest")
case "$(printf '%s\n' "$PM_EN" | sed -n 1p)" in *"could not be applied in full"*) ;; *) fail "partial merge (EN): wrong warning: $(printf '%s' "$PM_EN" | sed -n 1p)" ;; esac
case "$(printf '%s\n' "$PM_EN" | sed -n 3p)" in *"damaged, incomplete or unsafe"*) ;; *) fail "partial merge (EN): the flag leaked into the next warning" ;; esac
case "$(printf '%s\n' "$PM_ES" | sed -n 1p)" in *"no se pudo aplicar por completo"*) ;; *) fail "partial merge (ES): wrong warning: $(printf '%s' "$PM_ES" | sed -n 1p)" ;; esac
case "$(printf '%s\n' "$PM_ES" | sed -n 3p)" in *"dañado, incompleto o no es seguro"*) ;; *) fail "partial merge (ES): the flag leaked into the next warning" ;; esac
[ "$(printf '%s\n' "$PM_EN" | sed -n '2p;4p' | tr '\n' ' ')" = "rc=1 failed=1 rc=1 failed=1 " ] || fail "partial merge: the module was not marked as failed"
grep -qx 'x' "$PM/dest/top/a/x" 2>/dev/null || fail "partial merge: what did not clash was not applied"
grep -qx 'mine' "$PM/dest/top/b" 2>/dev/null || fail "partial merge: the clashing file was altered"
PM_LINK=$(pm_run en "$LP/themes.tar.gz" "$PM/stow/home")
case "$(printf '%s\n' "$PM_LINK" | sed -n 1p)" in *"could not be applied in full"*) ;; *) fail "link at the destination: wrong warning" ;; esac
[ -z "$(ls -A "$PM/stow/real")" ] || fail "link at the destination: a write went through the link"
pass "a clash during restore says the rest was applied, and the next warning is unaffected"

# dconf reset is destructive and must fail closed if the reset cannot be performed.
DCONF_RESET_ROOT="$TMP/dconf-reset-failure"
mkdir -p "$DCONF_RESET_ROOT"
printf '[demo]\nkey=\"saved\"\n' > "$DCONF_RESET_ROOT/state.dconf"
printf '[demo]\nkey=\"new\"\n' > "$DCONF_RESET_ROOT/load.dconf"
DCONF_RESET_OUT=$(HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 \
    DCONF_RESET_ROOT="$DCONF_RESET_ROOT" bash -c '
source "$1"
dconf() {
    case "$1" in
        dump) cat "$DCONF_RESET_ROOT/state.dconf"; return 0 ;;
        reset) return 17 ;;
        load) printf loaded > "$DCONF_RESET_ROOT/loaded"; return 0 ;;
        *) return 1 ;;
    esac
}
set_language en
set +e
dconf_load_clean /org/demo/ "$DCONF_RESET_ROOT/load.dconf"
printf "RC:%s\\n" "$?"
' _ "$SCRIPT" 2>&1)
printf '%s\n' "$DCONF_RESET_OUT" | grep -Fq 'RC:1' || fail "dconf_load_clean hid a reset failure"
[ ! -e "$DCONF_RESET_ROOT/loaded" ] || fail "dconf_load_clean loaded new data after a failed reset"
pass "dconf restore fails closed on reset failure"

# If dconf load fails after a destructive reset, rollback must be attempted and
# the restored state must be checked with a fresh dump rather than assumed.
DCONF_ROLLBACK_ROOT="$TMP/dconf-load-rollback"
mkdir -p "$DCONF_ROLLBACK_ROOT"
printf '[demo]\nkey="saved"\n' > "$DCONF_ROLLBACK_ROOT/state.dconf"
printf '[demo]\nkey="new"\n' > "$DCONF_ROLLBACK_ROOT/load.dconf"
DCONF_ROLLBACK_OUT=$(HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 \
    DCONF_ROLLBACK_ROOT="$DCONF_ROLLBACK_ROOT" bash -c '
source "$1"
dconf() {
    case "$1" in
        dump)
            n=0; [ -f "$DCONF_ROLLBACK_ROOT/dump-count" ] && n=$(cat "$DCONF_ROLLBACK_ROOT/dump-count")
            printf "%s\n" "$((n + 1))" > "$DCONF_ROLLBACK_ROOT/dump-count"
            cat "$DCONF_ROLLBACK_ROOT/state.dconf"
            return 0
            ;;
        reset) return 0 ;;
        load)
            n=0; [ -f "$DCONF_ROLLBACK_ROOT/load-count" ] && n=$(cat "$DCONF_ROLLBACK_ROOT/load-count")
            printf "%s\n" "$((n + 1))" > "$DCONF_ROLLBACK_ROOT/load-count"
            cat > "$DCONF_ROLLBACK_ROOT/last-load"
            [ "$n" -eq 0 ] && return 17
            return 0
            ;;
        *) return 1 ;;
    esac
}
set_language en
set +e
RESTORE_CONTEXT=1
RESTORE_MODULE_FAILED=0
dconf_load_clean /org/demo/ "$DCONF_ROLLBACK_ROOT/load.dconf"
rc=$?
printf "RC:%s FAILED:%s\n" "$rc" "$RESTORE_MODULE_FAILED"
' _ "$SCRIPT" 2>&1)
printf '%s\n' "$DCONF_ROLLBACK_OUT" | grep -Fq 'RC:1 FAILED:1' || fail "dconf load failure was not propagated"
[ "$(cat "$DCONF_ROLLBACK_ROOT/load-count")" -ge 2 ] || fail "dconf rollback load was not attempted"
[ "$(cat "$DCONF_ROLLBACK_ROOT/dump-count")" -ge 2 ] || fail "dconf rollback result was not verified"
grep -Fq 'saved' "$DCONF_ROLLBACK_ROOT/last-load" || fail "dconf rollback did not reload the saved snapshot"
pass "dconf load failures trigger verified rollback"

# The shared /org/cinnamon/ desktop restore must obey the same fail-closed contract.
DCONF_DESKTOP_ROOT="$TMP/dconf-desktop-reset-failure"
mkdir -p "$DCONF_DESKTOP_ROOT"
printf '[desktop/panel]\nkey=\"saved\"\n' > "$DCONF_DESKTOP_ROOT/state.dconf"
printf '[desktop/panel]\nkey=\"new\"\n' > "$DCONF_DESKTOP_ROOT/load.dconf"
DCONF_DESKTOP_OUT=$(HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 \
    DCONF_DESKTOP_ROOT="$DCONF_DESKTOP_ROOT" bash -c '
source "$1"
dconf() {
    case "$1" in
        dump) cat "$DCONF_DESKTOP_ROOT/state.dconf"; return 0 ;;
        reset) return 17 ;;
        load)
            cat > "$DCONF_DESKTOP_ROOT/last-load"
            return 0
            ;;
        *) return 1 ;;
    esac
}
set_language en
set +e
dconf_load_desktop_clean /org/cinnamon/ "$DCONF_DESKTOP_ROOT/load.dconf"
printf "RC:%s\\n" "$?"
' _ "$SCRIPT" 2>&1)
printf '%s\n' "$DCONF_DESKTOP_OUT" | grep -Fq 'RC:1' || fail "dconf_load_desktop_clean hid a reset failure"
if [ ! -f "$DCONF_DESKTOP_ROOT/last-load" ] || ! grep -Fq 'saved' "$DCONF_DESKTOP_ROOT/last-load"; then
    printf 'DEBUG last-load:\n' >&2
    cat "$DCONF_DESKTOP_ROOT/last-load" >&2 2>/dev/null || true
    fail "dconf_load_desktop_clean accepted new data after a failed reset"
fi
pass "desktop dconf restore fails closed on reset failure"

# Desktop rollback must reset all sections touched by the restore file, without
# reloading sections owned by other modules.
DCONF_DESKTOP_SCOPE_ROOT="$TMP/dconf-desktop-rollback-scope"
mkdir -p "$DCONF_DESKTOP_SCOPE_ROOT"
printf '[desktop/interface]\nkey="foreign-old"\n' > "$DCONF_DESKTOP_SCOPE_ROOT/state.dconf"
printf '[panel]\nkey="desktop-new"\n' > "$DCONF_DESKTOP_SCOPE_ROOT/load.dconf"
DCONF_DESKTOP_SCOPE_OUT=$(HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 \
    DCONF_DESKTOP_SCOPE_ROOT="$DCONF_DESKTOP_SCOPE_ROOT" bash -c '
source "$1"
dconf() {
    case "$1" in
        dump) n=0; [ -f "$DCONF_DESKTOP_SCOPE_ROOT/dump-count" ] && n=$(cat "$DCONF_DESKTOP_SCOPE_ROOT/dump-count"); printf "%s\n" "$((n + 1))" > "$DCONF_DESKTOP_SCOPE_ROOT/dump-count"; cat "$DCONF_DESKTOP_SCOPE_ROOT/state.dconf"; return 0 ;;
        reset) printf "%s\n" "$*" >> "$DCONF_DESKTOP_SCOPE_ROOT/resets"; return 0 ;;
        load) cat > "$DCONF_DESKTOP_SCOPE_ROOT/last-load"; return 17 ;;
        *) return 1 ;;
    esac
}
set_language en
set +e
RESTORE_CONTEXT=1
RESTORE_MODULE_FAILED=0
dconf_load_desktop_clean /org/cinnamon/ "$DCONF_DESKTOP_SCOPE_ROOT/load.dconf"
rc=$?
printf "RC:%s FAILED:%s\\n" "$rc" "$RESTORE_MODULE_FAILED"
' _ "$SCRIPT" 2>&1)
printf '%s\\n' "$DCONF_DESKTOP_SCOPE_OUT" | grep -Fq 'RC:1 FAILED:1' || fail "desktop dconf rollback scope did not fail closed"
[ -f "$DCONF_DESKTOP_SCOPE_ROOT/resets" ] || fail "desktop dconf rollback never reset the touched scope"
grep -Fq '/org/cinnamon/panel/' "$DCONF_DESKTOP_SCOPE_ROOT/resets" || fail "desktop dconf rollback did not reset a section absent from the old snapshot"
! grep -Fq '/org/cinnamon/desktop/interface/' "$DCONF_DESKTOP_SCOPE_ROOT/resets" || fail "desktop dconf rollback touched another module's section"
[ -f "$DCONF_DESKTOP_SCOPE_ROOT/last-load" ] || fail "desktop dconf rollback was never attempted"
! grep -Fq '[desktop/interface]' "$DCONF_DESKTOP_SCOPE_ROOT/last-load" || fail "desktop dconf rollback reloaded another module's section"
[ "$(cat "$DCONF_DESKTOP_SCOPE_ROOT/dump-count")" -ge 2 ] || fail "desktop dconf rollback result was not verified"
pass "desktop dconf rollback is limited to desktop-owned sections"

# A crafted Desktop dconf dump must not be able to smuggle an excluded section
# into the restore path. Reject it before any destructive reset or load.
DCONF_DESKTOP_UNSAFE_ROOT="$TMP/dconf-desktop-unsafe"
mkdir -p "$DCONF_DESKTOP_UNSAFE_ROOT"
printf '[desktop/interface]\ncolor-scheme="prefer-dark"\n[panel]\nkey="saved"\n' > "$DCONF_DESKTOP_UNSAFE_ROOT/load.dconf"
DCONF_DESKTOP_UNSAFE_OUT=$(HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 \
    DCONF_DESKTOP_UNSAFE_ROOT="$DCONF_DESKTOP_UNSAFE_ROOT" bash -c '
source "$1"
dconf() {
    case "$1" in
        dump) cat "$DCONF_DESKTOP_UNSAFE_ROOT/state.dconf" 2>/dev/null || true; return 0 ;;
        reset) printf "%s\n" "$*" >> "$DCONF_DESKTOP_UNSAFE_ROOT/resets"; return 0 ;;
        load) cat > "$DCONF_DESKTOP_UNSAFE_ROOT/last-load"; return 0 ;;
        *) return 1 ;;
    esac
}
printf "[desktop/panel]\nkey=\"old\"\n" > "$DCONF_DESKTOP_UNSAFE_ROOT/state.dconf"
set_language en
set +e
RESTORE_CONTEXT=1 RESTORE_MODULE_FAILED=0
dconf_load_desktop_clean /org/cinnamon/ "$DCONF_DESKTOP_UNSAFE_ROOT/load.dconf"
rc=$?
printf "RC:%s FAILED:%s\n" "$rc" "$RESTORE_MODULE_FAILED"
' _ "$SCRIPT" 2>&1)
printf '%s\n' "$DCONF_DESKTOP_UNSAFE_OUT" | grep -Fq 'RC:1 FAILED:1' || fail "desktop dconf accepted an excluded section from a crafted backup"
[ ! -e "$DCONF_DESKTOP_UNSAFE_ROOT/resets" ] || fail "unsafe desktop dconf was reset before being rejected"
[ ! -e "$DCONF_DESKTOP_UNSAFE_ROOT/last-load" ] || fail "unsafe desktop dconf was loaded before being rejected"
pass "desktop dconf rejects crafted excluded sections before reset"

# A failed Desktop archive must not alter existing launcher permissions or trust metadata.
NEMO_FAIL_ROOT="$TMP/nemo-desktop-failure"
NEMO_FAIL_BACKUP="$NEMO_FAIL_ROOT/nemo-backup"
NEMO_FAIL_BIN="$NEMO_FAIL_ROOT/bin"
mkdir -p "$NEMO_FAIL_ROOT/home/Desktop" "$NEMO_FAIL_BACKUP/nemo" "$NEMO_FAIL_BIN"
printf '[Desktop Entry]\nType=Application\nName=Existing\nExec=true\n' > "$NEMO_FAIL_ROOT/home/Desktop/existing.desktop"
chmod 644 "$NEMO_FAIL_ROOT/home/Desktop/existing.desktop"
printf '%s' 'not-a-valid-tarball' > "$NEMO_FAIL_BACKUP/nemo/desktop-files.tar.gz"
cat > "$NEMO_FAIL_BIN/gio" <<'GIOFAIL'
#!/bin/sh
printf '%s\n' "$*" >> "$NEMO_FAIL_ROOT/gio-calls"
exit 0
GIOFAIL
chmod +x "$NEMO_FAIL_BIN/gio"
# shellcheck disable=SC2097,SC2098  # values taken from this shell are deliberately re-exported to the child
PATH="$NEMO_FAIL_BIN:$MOCK:/usr/bin:/bin" HOME="$NEMO_FAIL_ROOT/home" XDG_CONFIG_HOME="$NEMO_FAIL_ROOT/config" \
    MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 NEMO_FAIL_ROOT="$NEMO_FAIL_ROOT" NEMO_FAIL_BACKUP="$NEMO_FAIL_BACKUP" \
    bash -c '
source "$1"
log_msg(){ :; }
restore_nemo "$NEMO_FAIL_BACKUP"
' _ "$SCRIPT" >/dev/null 2>&1 || true
[ "$(stat -c '%a' "$NEMO_FAIL_ROOT/home/Desktop/existing.desktop")" = 644 ] || fail "failed Nemo restore changed an existing launcher permission"
[ ! -e "$NEMO_FAIL_ROOT/gio-calls" ] || fail "failed Nemo restore changed trust metadata on an existing launcher"
pass "failed Nemo Desktop restore has no unrelated side effects"

# A successful Nemo restore in keep mode must trust only launchers that were
# actually added by this restore, never an existing launcher in the Desktop.
NEMO_KEEP_ROOT="$TMP/nemo-desktop-keep"
NEMO_KEEP_BACKUP="$NEMO_KEEP_ROOT/nemo-backup"
NEMO_KEEP_BIN="$NEMO_KEEP_ROOT/bin"
NEMO_KEEP_HOME="$NEMO_KEEP_ROOT/home"
mkdir -p "$NEMO_KEEP_HOME/Desktop" "$NEMO_KEEP_BACKUP/nemo" "$NEMO_KEEP_BIN"
printf '[Desktop Entry]\nType=Application\nName=Existing\nExec=true\n' > "$NEMO_KEEP_HOME/Desktop/existing.desktop"
chmod 644 "$NEMO_KEEP_HOME/Desktop/existing.desktop"
mkdir -p "$NEMO_KEEP_ROOT/archive/Desktop"
printf '[Desktop Entry]\nType=Application\nName=Existing replacement\nExec=false\n' > "$NEMO_KEEP_ROOT/archive/Desktop/existing.desktop"
printf '[Desktop Entry]\nType=Application\nName=New\nExec=true\n' > "$NEMO_KEEP_ROOT/archive/Desktop/new.desktop"
tar czf "$NEMO_KEEP_BACKUP/nemo/desktop-files.tar.gz" -C "$NEMO_KEEP_ROOT/archive" Desktop
cat > "$NEMO_KEEP_BIN/gio" <<'GIOKEEP'
#!/bin/sh
printf '%s\n' "$*" >> "$NEMO_KEEP_ROOT/gio-calls"
exit 0
GIOKEEP
chmod +x "$NEMO_KEEP_BIN/gio"
# shellcheck disable=SC2097,SC2098  # values taken from this shell are deliberately re-exported to the child
PATH="$NEMO_KEEP_BIN:$MOCK:/usr/bin:/bin" HOME="$NEMO_KEEP_HOME" XDG_CONFIG_HOME="$NEMO_KEEP_ROOT/config" \
    MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 NEMO_KEEP_ROOT="$NEMO_KEEP_ROOT" NEMO_KEEP_BACKUP="$NEMO_KEEP_BACKUP" \
    bash -c '
source "$1"
log_msg(){ :; }
restore_nemo "$NEMO_KEEP_BACKUP"
' _ "$SCRIPT" >/dev/null 2>&1 || fail "successful Nemo keep restore exited non-zero"
grep -Fq 'Exec=true' "$NEMO_KEEP_HOME/Desktop/existing.desktop" || fail "Nemo keep restore overwrote an existing launcher"
[ "$(stat -c '%a' "$NEMO_KEEP_HOME/Desktop/existing.desktop")" = 644 ] || fail "Nemo keep restore changed an existing launcher permission"
[ "$(stat -c '%a' "$NEMO_KEEP_HOME/Desktop/new.desktop")" = 744 ] || fail "Nemo keep restore did not make the new launcher executable"
grep -Fq "$NEMO_KEEP_HOME/Desktop/new.desktop" "$NEMO_KEEP_ROOT/gio-calls" || fail "Nemo keep restore did not trust the newly restored launcher"
! grep -Fq "$NEMO_KEEP_HOME/Desktop/existing.desktop" "$NEMO_KEEP_ROOT/gio-calls" || fail "Nemo keep restore touched an existing launcher trust attribute"
pass "Nemo keep restore trusts only newly restored launchers"

# Applying a restored wallpaper is part of the module result; a failed gsettings write must not be reported as success.
WALLPAPER_ROOT="$TMP/wallpaper-gsettings-failure"
mkdir -p "$WALLPAPER_ROOT/backup" "$WALLPAPER_ROOT/home/Pictures"
printf 'wallpaper-data\n' > "$WALLPAPER_ROOT/backup/wallpaper-wallpaper.png"
printf 'wallpaper.png\n' > "$WALLPAPER_ROOT/backup/wallpaper.filename"
# shellcheck disable=SC2097,SC2098  # values taken from this shell are deliberately re-exported to the child
WALLPAPER_OUT=$(HOME="$WALLPAPER_ROOT/home" XDG_CONFIG_HOME="$WALLPAPER_ROOT/config" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 \
    WALLPAPER_ROOT="$WALLPAPER_ROOT" bash -c '
source "$1"
xdg_dir() { printf "%s" "$HOME/Pictures"; }
gsettings() { return 19; }
set_language en
RESTORE_CONTEXT=1 RESTORE_MODULE_FAILED=0
set +e
restore_wallpaper_uri "$WALLPAPER_ROOT/backup" picture-uri ""
rc=$?
printf "RC:%s FAILED:%s\n" "$rc" "$RESTORE_MODULE_FAILED"
' _ "$SCRIPT" 2>&1)
printf '%s\n' "$WALLPAPER_OUT" | grep -Fq 'RC:1 FAILED:1' || fail "wallpaper gsettings failure was hidden"
[ -f "$WALLPAPER_ROOT/home/Pictures/MintSetupWallpapers/wallpaper.png" ] || fail "wallpaper atomic copy did not complete before gsettings failure"
pass "wallpaper restore propagates gsettings failures"

# A failed GNOME color-scheme write is part of the Appearance restore result.
APPEARANCE_ROOT="$TMP/appearance-gsettings-failure"
mkdir -p "$APPEARANCE_ROOT/backup/appearance" "$APPEARANCE_ROOT/home" "$APPEARANCE_ROOT/config"
printf 'dark\n' > "$APPEARANCE_ROOT/backup/appearance/gnome-color-scheme.value"
# shellcheck disable=SC2097,SC2098  # values taken from this shell are deliberately re-exported to the child
APPEARANCE_OUT=$(HOME="$APPEARANCE_ROOT/home" XDG_CONFIG_HOME="$APPEARANCE_ROOT/config" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 \
    APPEARANCE_ROOT="$APPEARANCE_ROOT" bash -c '
source "$1"
set_language en
log_msg(){ :; }
gsettings(){ return 21; }
mkdir(){ command mkdir "$@"; }
set +e
run_restore_module appearance "$APPEARANCE_ROOT/backup"
rc=$?
printf "RC:%s\n" "$rc"
' _ "$SCRIPT" 2>&1)
printf '%s\n' "$APPEARANCE_OUT" | grep -Fq 'RC:1' || fail "appearance gsettings failure was hidden"
pass "appearance restore propagates gsettings failures"

FAIL_HOME="$TMP/fail-save-home"; FAIL_CFG="$TMP/fail-save-config"; FAIL_BACKUPS="$TMP/fail-save-backups"
mkdir -p "$FAIL_HOME/.config" "$FAIL_CFG" "$FAIL_BACKUPS"
FAIL_OUT=$(HOME="$FAIL_HOME" XDG_CONFIG_HOME="$FAIL_CFG" MINT_SETUP_BACKUPS_DIR="$FAIL_BACKUPS" \
    PATH="$MOCK:/usr/bin:/bin" LC_ALL=C.UTF-8 MINT_SETUP_TEST=1 bash -c '
source "$1"
set_language es
zenity() {
    case "$*" in
        *--checklist*) printf "%s\n" terminal ;;
        *--entry*) printf "%s\n" "Failed save" ;;
        *--progress*) cat >/dev/null ;;
        *) : ;;
    esac
}
root_preauth() { return 0; }
msg_error() { printf "%s\n" "$1"; }
save_terminal() { mkdir -p "$1/terminal"; printf partial > "$1/terminal/partial"; return 7; }
do_save
' _ "$SCRIPT" 2>&1)
FAIL_RC=$?
[ "$FAIL_RC" -ne 0 ] || fail "failed save unexpectedly returned success"
find "$FAIL_BACKUPS" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print -quit | grep -q . && fail "failed save published a backup"
find "$FAIL_BACKUPS" -mindepth 1 -maxdepth 1 -type d -name '.*' -print -quit | grep -q . && fail "failed save left a staging directory"
printf '%s\n' "$FAIL_OUT" | grep -Fq "No se pudo completar la copia" || fail "failed save did not report the correct error"
pass "failed save is not published"

# 12.45: a save whose module failed ended with "No se pudo completar la copia" and nothing else: the
# warning that names the file (save_problem) goes to save.log, which is discarded with the staged copy,
# and SAVE_PROBLEMS_FILE (promised as the "final summary") was only ever set by the tests. The dialog
# now names the modules that failed and up to five files, read from a report kept outside the staged copy.
SF_ROOT="$TMP/save-fail"; mkdir -p "$SF_ROOT/bin"
printf '#!/bin/sh\necho "simulated dconf failure" >&2\nexit 1\n' > "$SF_ROOT/bin/dconf"; chmod +x "$SF_ROOT/bin/dconf"
sf_run() {   # sf_run LANG MODULES [SIGNAL]: the real do_save; SF_FAILING_DCONF=1 makes dconf fail, SF_DEFS is code run before it, SF_TMPDIR tunes TMPDIR; SIGNAL goes to the program once a module runs (SF_SEEN: entries in the temp folder then)
    local lang="$1" sig="${3:-}" job runner=(env)
    # a background job starts with INT ignored, and under nohup so does HUP: the program gets its own disposition back (coreutils 8.31+)
    [ -z "$sig" ] || ! env --default-signal="$sig" true 2>/dev/null || runner=(env --default-signal="$sig")
    rm -rf "${SF_ROOT:?}/home" "$SF_ROOT/config" "$SF_ROOT/backups" "$SF_ROOT/tmp" "$SF_ROOT/out" "$SF_ROOT/running"
    mkdir -p "$SF_ROOT/home" "$SF_ROOT/config" "$SF_ROOT/backups" "$SF_ROOT/tmp" "$SF_ROOT/out"
    SF_RC=0; SF_SEEN=0
    # shellcheck disable=SC2016  # the inner bash expands $1, $2 and the SF_* variables, not this shell
    "${runner[@]}" HOME="$SF_ROOT/home" XDG_CONFIG_HOME="$SF_ROOT/config" MINT_SETUP_BACKUPS_DIR="$SF_ROOT/backups" \
        PATH="${SF_FAILING_DCONF:+$SF_ROOT/bin:}$MOCK:/usr/bin:/bin" LC_ALL=C.UTF-8 MINT_SETUP_TEST=1 \
        TMPDIR="${SF_TMPDIR:-$SF_ROOT/tmp}" SF_ROOT="$SF_ROOT" SF_MODS="$2" SF_DEFS="${SF_DEFS:-}" bash -c '
source "$1"; set_language "$2"; out="$SF_ROOT/out"; echo $$ > "$out/pid"
zenity() { case "$*" in *--checklist*) printf "%s\n" "$SF_MODS" ;; *--entry*) printf "%s\n" "Fallos" ;; *--progress*) cat >/dev/null ;; esac; }
root_preauth() { return 0; }
msg_info() { printf "%s" "$1" > "$out/info"; }
msg_warn() { printf "%s" "$1" > "$out/warning"; }
msg_error() { printf "%s" "$1" > "$out/error"; }
eval "$SF_DEFS"
do_save; echo "$?" > "$out/rc"
printf "%s" "${SAVE_PROBLEMS_FILE-unset}" > "$out/spf"
printf "%s\n" "${_MS_TMP[@]+"${_MS_TMP[@]}"}" > "$out/tracked"
' _ "$SCRIPT" "$lang" >"$SF_ROOT/out/stdout" 2>"$SF_ROOT/out/stderr" &
    job=$!
    if [ -n "$sig" ]; then
        for _ in $(seq 1 100); do [ -e "$SF_ROOT/running" ] && break; sleep 0.05; done
        [ -e "$SF_ROOT/running" ] || { kill "$job" 2>/dev/null; fail "failed save ($sig): no module ever ran"; }
        SF_SEEN=$(find "$SF_ROOT/tmp" -mindepth 1 | wc -l)
        kill -"$sig" "$(cat "$SF_ROOT/out/pid")" 2>/dev/null
    fi
    wait "$job" || SF_RC=$?
    SF_ERR=$(cat "$SF_ROOT/out/error" 2>/dev/null)
}
sf_clean() {   # sf_clean TAG [SPF]: failed save: rc 1, nothing published or staged, no temp file left or registered, SAVE_PROBLEMS_FILE as before the call (unset, or SPF), nothing outside the dialog
    [ "$(cat "$SF_ROOT/out/rc" 2>/dev/null)" = 1 ] || fail "failed save ($1): rc is $(cat "$SF_ROOT/out/rc" 2>&1)"
    [ ! -e "$SF_ROOT/out/info" ] || fail "failed save ($1): a success dialog came up"
    [ -z "$(ls -A "$SF_ROOT/backups")" ] || fail "failed save ($1): the backups folder holds: $(ls -A "$SF_ROOT/backups")"
    [ -z "$(ls -A "$SF_ROOT/tmp")" ] || fail "failed save ($1): temporary files left: $(ls -A "$SF_ROOT/tmp")"
    [ -z "$(cat "$SF_ROOT/out/tracked")" ] || fail "failed save ($1): a path is still registered: $(cat "$SF_ROOT/out/tracked")"
    [ "$(cat "$SF_ROOT/out/spf" 2>/dev/null)" = "${2:-unset}" ] || fail "failed save ($1): SAVE_PROBLEMS_FILE is not as before the call: $(cat "$SF_ROOT/out/spf" 2>&1)"
    { [ ! -s "$SF_ROOT/out/stdout" ] && [ ! -s "$SF_ROOT/out/stderr" ]; } || fail "failed save ($1): output outside the dialog: $(cat "$SF_ROOT/out/stdout" "$SF_ROOT/out/stderr" 2>&1)"
}
# control: everything saves; no report file travels inside the published copy
SF_FAILING_DCONF='' sf_run es keyboard,terminal
[ "$SF_RC" = 0 ] && [ "$(cat "$SF_ROOT/out/rc")" = 0 ] || fail "failed save (control): do_save did not succeed"
[ -e "$SF_ROOT/out/info" ] && [ ! -e "$SF_ROOT/out/error" ] || fail "failed save (control): wrong dialog"
sf_control_copy=$(find "$SF_ROOT/backups" -mindepth 1 -maxdepth 1 -type d ! -name '.*')
[ -n "$sf_control_copy" ] || fail "failed save (control): no backup published"
[ -z "$(find "$sf_control_copy" \( -name modules -o -name files \) -print -quit)" ] || fail "failed save (control): the failure report was published inside the copy"
[ -z "$(ls -A "$SF_ROOT/tmp")" ] && [ -z "$(cat "$SF_ROOT/out/tracked")" ] || fail "failed save (control): temporary files left or registered"
[ "$(cat "$SF_ROOT/out/spf")" = unset ] || fail "failed save (control): SAVE_PROBLEMS_FILE leaked out of do_save: $(cat "$SF_ROOT/out/spf")"
for sf_lang in es en; do
    if [ "$sf_lang" = es ]; then
        sf_head='No se pudo completar la copia. Ninguna configuración incompleta se ha publicado en la carpeta de copias.'
        sf_mods='Módulos que fallaron'; sf_files='No se pudo guardar de forma íntegra:'; sf_more='… y 2 más'; sf_more1='… y 1 más'
        sf_k=Teclado; sf_m=Ratón
    else
        sf_head='The backup could not be completed. No incomplete configuration was published to the backup folder.'
        sf_mods='Modules that failed'; sf_files='Could not be saved intact:'; sf_more='… and 2 more'; sf_more1='… and 1 more'
        sf_k=Keyboard; sf_m=Mouse
    fi
    # real modules, dconf failing: the two modules are named, with the files that save_problem flagged (staging folder not shown)
    SF_FAILING_DCONF=1 SF_DEFS='' sf_run "$sf_lang" keyboard,mouse
    sf_want="$sf_head"$'\n\n'"$sf_mods: $sf_k, $sf_m"$'\n\n'"$sf_files"$'\n  • keyboard/input-sources.dconf\n  • keyboard/keyboard.dconf\n  • mouse/mouse.dconf'
    [ "$SF_ERR" = "$sf_want" ] || fail "failed save ($sf_lang): wrong dialog: $SF_ERR"
    sf_clean "dconf, $sf_lang"
    # a module that fails without flagging a file (the earlier failed-save case): named, no file list
    # shellcheck disable=SC2016  # the stub module is evaluated inside sf_run, so $1 and $HOME stay literal here
    SF_FAILING_DCONF='' SF_DEFS='save_terminal() { mkdir -p "$1/terminal"; return 7; }' sf_run "$sf_lang" keyboard,terminal
    [ "$SF_ERR" = "$sf_head"$'\n\n'"$sf_mods: Terminal" ] || fail "failed save ($sf_lang): a module without flagged files: wrong dialog: $SF_ERR"
    sf_clean "no files, $sf_lang"
    # seven flagged files: five listed, the rest counted; a source path is shown as it is, and "%s", "&" and "<" survive as data
    # shellcheck disable=SC2016  # as above
    SF_DEFS='save_terminal() { local i; mkdir -p "$1/terminal"; for i in 1 2 3 4 5; do save_problem "$1/terminal/f$i"; done; save_problem "$HOME/.cinnamon"; save_problem "$1/terminal/a&b<%s>"; }' \
        sf_run "$sf_lang" terminal
    sf_want="$sf_head"$'\n\n'"$sf_mods: Terminal"$'\n\n'"$sf_files"$'\n  • terminal/f1\n  • terminal/f2\n  • terminal/f3\n  • terminal/f4\n  • terminal/f5\n  '"$sf_more"
    [ "$SF_ERR" = "$sf_want" ] || fail "failed save ($sf_lang): seven flagged files: wrong dialog: $SF_ERR"
    sf_clean "seven files, $sf_lang"
    # two flagged files, the first a source path (shown as it is) and the second with "&", "<" and "%s" (kept as data)
    # shellcheck disable=SC2016  # as above
    SF_DEFS='save_terminal() { mkdir -p "$1/terminal"; save_problem "$HOME/.cinnamon"; save_problem "$1/terminal/a&b<%s>"; }' sf_run "$sf_lang" terminal
    sf_want="$sf_head"$'\n\n'"$sf_mods: Terminal"$'\n\n'"$sf_files"$'\n  • '"$SF_ROOT/home/.cinnamon"$'\n  • terminal/a&b<%s>'
    [ "$SF_ERR" = "$sf_want" ] || fail "failed save ($sf_lang): source path and awkward name: wrong dialog: $SF_ERR"
    sf_clean "paths, $sf_lang"
    # no folder for the report (TMPDIR cannot be written): the plain error, nothing published or left
    # shellcheck disable=SC2016  # as above
    SF_DEFS='save_terminal() { mkdir -p "$1/terminal"; save_problem "$1/terminal/x"; return 7; }' SF_TMPDIR="$SF_ROOT/missing" sf_run "$sf_lang" terminal
    [ "$SF_ERR" = "$sf_head" ] || fail "failed save ($sf_lang): no report folder: wrong dialog: $SF_ERR"
    [ "$(cat "$SF_ROOT/out/rc" 2>/dev/null)" = 1 ] && [ -z "$(ls -A "$SF_ROOT/backups")" ] || fail "failed save ($sf_lang): no report folder: rc or backups folder wrong"
    # an inherited SAVE_PROBLEMS_FILE is neither written to (here the flagged file has no report to go to) nor changed
    # shellcheck disable=SC2016  # as above
    SF_DEFS='export SAVE_PROBLEMS_FILE="$SF_ROOT/inherited"; save_terminal() { mkdir -p "$1/terminal"; save_problem "$1/terminal/x"; return 7; }' SF_TMPDIR="$SF_ROOT/missing" sf_run "$sf_lang" terminal
    [ "$SF_ERR" = "$sf_head" ] || fail "failed save ($sf_lang): inherited variable: wrong dialog: $SF_ERR"
    [ ! -e "$SF_ROOT/inherited" ] || fail "failed save ($sf_lang): an inherited SAVE_PROBLEMS_FILE was written to"
    sf_clean "inherited variable, $sf_lang" "$SF_ROOT/inherited"
    # exactly five flagged files are all listed, with no "and N more" line; six give five and "and 1 more"
    for sf_list in '1 2 3 4 5' '1 2 3 4 5 6'; do
        # shellcheck disable=SC2016  # as above
        SF_DEFS='save_terminal() { local i; mkdir -p "$1/terminal"; for i in '"$sf_list"'; do save_problem "$1/terminal/f$i"; done; }' sf_run "$sf_lang" terminal
        sf_want="$sf_head"$'\n\n'"$sf_mods: Terminal"$'\n\n'"$sf_files"$'\n  • terminal/f1\n  • terminal/f2\n  • terminal/f3\n  • terminal/f4\n  • terminal/f5'
        [ "$sf_list" = '1 2 3 4 5' ] || sf_want+=$'\n  '"$sf_more1"
        [ "$SF_ERR" = "$sf_want" ] || fail "failed save ($sf_lang): flagged files ($sf_list): wrong dialog: $SF_ERR"
        sf_clean "files $sf_list, $sf_lang"
    done
    # the progress window fails although every module saved: nothing to name, the copy is not published, nothing is printed
    # shellcheck disable=SC2016  # as above
    SF_DEFS='zenity() { case "$*" in *--checklist*) printf "%s\n" "$SF_MODS" ;; *--entry*) printf "%s\n" Fallos ;; *--progress*) cat >/dev/null; return 1 ;; esac; }' sf_run "$sf_lang" keyboard,terminal
    [ "$SF_ERR" = "$sf_head" ] || fail "failed save ($sf_lang): failing progress window: wrong dialog: $SF_ERR"
    sf_clean "progress window, $sf_lang"
done
pass "failed save names the modules and files that failed (up to five, then a count) in Spanish and English; keeps its report outside the copy, never leaks or writes SAVE_PROBLEMS_FILE and leaves nothing behind, also when only the progress window fails"

# A TERM, HUP or INT while a module runs (Ctrl+C in the terminal, closing the session): the report folder goes with
# the staged copy, the program ends with the signal's code and publishes nothing. The signal goes to the program's
# own process; bash runs the trap when the foreground pipeline returns, hence the one-second module.
for sf_sig in TERM:143 HUP:129 INT:130; do
    if [ "${sf_sig%%:*}" = INT ] && ! env --default-signal=INT true 2>/dev/null; then
        echo "SKIP: failed save INT during a module (needs env --default-signal)"; continue
    fi
    sf_tag="failed save ${sf_sig%%:*} during a module"
    # shellcheck disable=SC2016  # the stub module is evaluated inside sf_run
    SF_DEFS='save_terminal() { mkdir -p "$1/terminal"; : > "$SF_ROOT/running"; sleep 1; }' sf_run es terminal "${sf_sig%%:*}"
    [ "$SF_SEEN" -ge 1 ] || fail "$sf_tag (control): the report folder did not exist while the module ran"
    [ "$SF_RC" = "${sf_sig##*:}" ] || fail "$sf_tag: rc is $SF_RC, not ${sf_sig##*:}"
    [ -z "$(ls -A "$SF_ROOT/tmp")" ] || fail "$sf_tag: temporary files left: $(ls -A "$SF_ROOT/tmp")"
    [ -z "$(ls -A "$SF_ROOT/backups")" ] || fail "$sf_tag: the backups folder holds: $(ls -A "$SF_ROOT/backups")"
    { [ ! -e "$SF_ROOT/out/info" ] && [ ! -e "$SF_ROOT/out/error" ] && [ ! -e "$SF_ROOT/out/warning" ]; } || fail "$sf_tag: a dialog came up"
    { [ ! -s "$SF_ROOT/out/stdout" ] && [ ! -s "$SF_ROOT/out/stderr" ]; } || fail "$sf_tag: output: $(cat "$SF_ROOT/out/stdout" "$SF_ROOT/out/stderr" 2>&1)"
done
pass "failed save: a TERM, HUP or INT during a module leaves no report folder or staged copy and publishes nothing"

# The Save progress window names the module being saved. It showed the internal
# key ("# Guardando: software", "# Saving: keyboard") instead of the label used
# everywhere else ("Aplicaciones", "Keyboard").
SAVELBL_ROOT="$TMP/save-label"
for savelbl_lang in es en; do
    mkdir -p "$SAVELBL_ROOT/home" "$SAVELBL_ROOT/config" "$SAVELBL_ROOT/backups-$savelbl_lang"
    SAVELBL_OUT=$(HOME="$SAVELBL_ROOT/home" XDG_CONFIG_HOME="$SAVELBL_ROOT/config" MINT_SETUP_BACKUPS_DIR="$SAVELBL_ROOT/backups-$savelbl_lang" \
        PATH="$MOCK:/usr/bin:/bin" LC_ALL=C.UTF-8 MINT_SETUP_TEST=1 SAVELBL_CAP="$SAVELBL_ROOT/progress-$savelbl_lang" bash -c '
source "$1"
set_language "$2"
zenity() {
    case "$*" in
        *--checklist*) printf "%s\n" software,keyboard,startup ;;
        *--entry*) printf "%s\n" "Labels" ;;
        *--progress*) cat > "$SAVELBL_CAP" ;;
    esac
}
root_preauth() { return 0; }
msg_info() { :; }
msg_warn() { printf "WARN:%s\n" "$1"; }
msg_error() { printf "ERROR:%s\n" "$1"; }
save_software() { mkdir -p "$1/software"; printf x > "$1/software/f"; }
save_keyboard() { mkdir -p "$1/keyboard"; printf x > "$1/keyboard/f"; }
save_startup() { mkdir -p "$1/startup"; printf x > "$1/startup/f"; }
do_save
printf "RC:%s\n" "$?"
' _ "$SCRIPT" "$savelbl_lang" 2>&1)
    [ "$SAVELBL_OUT" = "RC:0" ] || fail "save ($savelbl_lang) did not finish cleanly: $SAVELBL_OUT"
    case "$savelbl_lang" in
        es) savelbl_want=$'# Guardando: Aplicaciones\n# Guardando: Teclado\n# Guardando: Aplicaciones de inicio' ;;
        *)  savelbl_want=$'# Saving: Applications\n# Saving: Keyboard\n# Saving: Startup Applications' ;;
    esac
    savelbl_got=$(grep '^#' "$SAVELBL_ROOT/progress-$savelbl_lang")
    [ "$savelbl_got" = "$savelbl_want" ] || fail "save progress ($savelbl_lang) did not name the modules by label: $(printf '%s' "$savelbl_got" | tr '\n' '|')"
done
pass "save progress names each module by its label, in Spanish and English"

# A save helper may continue after a failed atomic write, but the module must
# still propagate that failure to the transaction wrapper.
SAVE_INNER_BIN="$TMP/save-inner-failure-bin"; SAVE_INNER_STAGE="$TMP/save-inner-stage"
mkdir -p "$SAVE_INNER_BIN" "$SAVE_INNER_STAGE"
printf 'save-source\n' > "$HOME_DIR/.bashrc"
cat > "$SAVE_INNER_BIN/cp" <<'CPSAVEINNERFAIL'
#!/bin/bash
target="${@: -1}"
printf 'partial\n' > "$target"
exit 7
CPSAVEINNERFAIL
chmod +x "$SAVE_INNER_BIN/cp"
PATH="$SAVE_INNER_BIN:$MOCK:/usr/bin:/bin" HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
    bash -c '
source "$1"
log_msg() { :; }
set +e
run_save_module terminal "$2"
rc=$?
printf "RC:%s FAILED:%s\n" "$rc" "${SAVE_MODULE_FAILED:-0}"
exit "$rc"
' _ "$SCRIPT" "$SAVE_INNER_STAGE" >/dev/null 2>&1
SAVE_INNER_RC=$?
[ "$SAVE_INNER_RC" -ne 0 ] || fail "save helper failure was reported as success"
find "$SAVE_INNER_STAGE" -name '.*.mstmp.*' -print -quit | grep -q . && fail "failed inner save left an atomic temporary"
pass "inner save failures propagate to the module wrapper"

# Export stages the copy in the destination filesystem and preserves an
# existing destination until the replacement has been verified.
EXPORT_PARENT="$TMP/export-destination"
mkdir -p "$EXPORT_PARENT/User_flow_old"
printf 'old-destination\n' > "$EXPORT_PARENT/User_flow_old/old.txt"
if ! EXPORT_OUT=$(HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" \
    PATH="$MOCK:/usr/bin:/bin" LC_ALL=C.UTF-8 MINT_SETUP_TEST=1 \
    EXPORT_PARENT="$EXPORT_PARENT" EXPORT_SOURCE="$backup" bash -c '
source "$1"
pick_backup_dir() { printf "%s\n" "$EXPORT_SOURCE"; }
zenity() {
    case "$*" in
        *--file-selection*) printf "%s\n" "$EXPORT_PARENT" ;;
        *--question*) return 0 ;;
        *--progress*) cat >/dev/null ;;
        *) : ;;
    esac
}
msg_info() { :; }
msg_warn() { :; }
msg_error() { printf "%s\n" "$1" >&2; }
do_export_backup
' _ "$SCRIPT" 2>&1); then
    fail "successful export flow exited non-zero: $EXPORT_OUT"
fi
diff -qr -- "$backup" "$EXPORT_PARENT/$(basename "$backup")" >/dev/null || fail "exported backup content differs from source"
[ ! -e "$EXPORT_PARENT/$(basename "$backup")/old.txt" ] || fail "export did not replace the previous destination content"
find "$EXPORT_PARENT" -mindepth 1 -maxdepth 1 -type d -name '.*.mint-old.*' -print -quit | grep -q . && fail "successful export left a rollback directory"
pass "export replaces destination only after verification"

EXPORT_FAIL_PARENT="$TMP/export-failure"
mkdir -p "$EXPORT_FAIL_PARENT/$(basename "$backup")"
printf 'keep-this-backup\n' > "$EXPORT_FAIL_PARENT/$(basename "$backup")/keep.txt"
EXPORT_FAIL_OUT=$(HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" \
    PATH="$MOCK:/usr/bin:/bin" LC_ALL=C.UTF-8 MINT_SETUP_TEST=1 \
    EXPORT_PARENT="$EXPORT_FAIL_PARENT" EXPORT_SOURCE="$backup" bash -c '
source "$1"
pick_backup_dir() { printf "%s\n" "$EXPORT_SOURCE"; }
zenity() {
    case "$*" in
        *--file-selection*) printf "%s\n" "$EXPORT_PARENT" ;;
        *--question*) return 0 ;;
        *--progress*) cat >/dev/null ;;
        *) : ;;
    esac
}
confirm() { return 0; }
msg_info() { :; }
msg_warn() { :; }
msg_error() { :; }
cp() {
    local target="${@: -1}"
    mkdir -p -- "$target"
    printf partial > "$target/partial"
    return 7
}
set +e
do_export_backup
rc=$?
printf "%s\n" "$rc"
exit "$rc"
' _ "$SCRIPT" 2>&1)
EXPORT_FAIL_RC=$?
[ "$EXPORT_FAIL_RC" -ne 0 ] || fail "failed export unexpectedly returned success: $EXPORT_FAIL_OUT"
grep -qx 'keep-this-backup' "$EXPORT_FAIL_PARENT/$(basename "$backup")/keep.txt" || fail "failed export replaced the previous destination"
[ ! -e "$EXPORT_FAIL_PARENT/$(basename "$backup")/partial" ] || fail "failed export leaked partial destination content"
find "$EXPORT_FAIL_PARENT" -mindepth 1 -maxdepth 1 -type d -name '.*.mint-old.*' -print -quit | grep -q . && fail "failed export left a rollback directory"
find "$EXPORT_FAIL_PARENT" -mindepth 1 -maxdepth 1 -type d -name '.*.mstmp.*' -print -quit | grep -q . && fail "failed export left staging content"
pass "failed export preserves the previous destination"

# A progress window with no cancellation behind it must not offer Cancel:
# closing it leaves the work running and the flow ends with a success message.
# Save already passed --no-cancel; Export did not.
NOCANCEL_ROOT="$TMP/no-cancel"
mkdir -p "$NOCANCEL_ROOT/home" "$NOCANCEL_ROOT/config" "$NOCANCEL_ROOT/backups"
for nocancel_flow in do_export_backup do_save; do
    mkdir -p "$NOCANCEL_ROOT/dest-$nocancel_flow"
    NOCANCEL_OUT=$(HOME="$TMP/no-cancel/home" XDG_CONFIG_HOME="$TMP/no-cancel/config" MINT_SETUP_BACKUPS_DIR="$TMP/no-cancel/backups" \
        PATH="$MOCK:/usr/bin:/bin" LC_ALL=C.UTF-8 MINT_SETUP_TEST=1 NOCANCEL_ROOT="$TMP/no-cancel" NOCANCEL_SRC="$backup" \
        NOCANCEL_FLOW="$nocancel_flow" bash -c '
source "$1"
pick_backup_dir() { printf "%s\n" "$NOCANCEL_SRC"; }
zenity() {
    case "$*" in
        *--file-selection*) printf "%s\n" "$NOCANCEL_ROOT/dest-$NOCANCEL_FLOW" ;;
        *--checklist*) printf "%s\n" keyboard ;;
        *--entry*) printf "%s\n" "No cancel" ;;
        *--progress*) printf "%s\n" "$*" > "$NOCANCEL_ROOT/args-$NOCANCEL_FLOW"; cat > /dev/null ;;
    esac
}
root_preauth() { return 0; }
msg_info() { :; }
msg_warn() { :; }
msg_error() { printf "ERROR:%s\n" "$1"; }
save_keyboard() { mkdir -p "$1/keyboard"; printf x > "$1/keyboard/f"; }
"$NOCANCEL_FLOW"
printf "RC:%s\n" "$?"
' _ "$SCRIPT" 2>&1)
    [ "$NOCANCEL_OUT" = "RC:0" ] || fail "$nocancel_flow did not finish cleanly: $NOCANCEL_OUT"
    [ -s "$NOCANCEL_ROOT/args-$nocancel_flow" ] || fail "$nocancel_flow showed no progress window"
    grep -Fq -- '--no-cancel' "$NOCANCEL_ROOT/args-$nocancel_flow" || fail "$nocancel_flow progress window offers a Cancel that stops nothing"
done
pass "progress windows without a cancellation mechanism (export, save) have no Cancel button"

# Choosing the folder that already holds the backup as the export destination
# made the "existing destination" the source itself: after confirming, the
# original was replaced by a copy of itself and the flow reported a successful
# export. It must be refused before anything is asked or written, also when
# the destination is reached through a symbolic link.
SAME_ROOT="$TMP/export-same"
mkdir -p "$SAME_ROOT/home" "$SAME_ROOT/config" "$SAME_ROOT/backups/Copia_same/sub"
printf 'a\n' > "$SAME_ROOT/backups/Copia_same/a.txt"
printf 'b\n' > "$SAME_ROOT/backups/Copia_same/sub/b.txt"
printf 'NAME=%q\nDATE=%q\nMODULES=%q\n' 'Copia same' '2026-01-01' 'terminal' > "$SAME_ROOT/backups/Copia_same/manifest.conf"
ln -s "$SAME_ROOT/backups" "$SAME_ROOT/link"
SAME_INODE=$(stat -c %i "$SAME_ROOT/backups/Copia_same")
for same_lang in es en; do
    for same_parent in "$SAME_ROOT/backups" "$SAME_ROOT/link"; do
        rm -f "$SAME_ROOT/confirm" "$SAME_ROOT/progress"
        SAME_OUT=$(HOME="$TMP/export-same/home" XDG_CONFIG_HOME="$TMP/export-same/config" MINT_SETUP_BACKUPS_DIR="$TMP/export-same/backups" \
            PATH="$MOCK:/usr/bin:/bin" LC_ALL=C.UTF-8 MINT_SETUP_TEST=1 SAME_ROOT="$TMP/export-same" SAME_PARENT="$same_parent" bash -c '
source "$1"
set_language "$2"
pick_backup_dir() { printf "%s\n" "$SAME_ROOT/backups/Copia_same"; }
zenity() {
    case "$*" in
        *--file-selection*) printf "%s\n" "$SAME_PARENT" ;;
        *--progress*) echo progress >> "$SAME_ROOT/progress"; cat > /dev/null ;;
    esac
}
confirm() { echo asked >> "$SAME_ROOT/confirm"; return 0; }
msg_info() { printf "INFO:%s\n" "$1"; }
msg_error() { printf "ERROR:%s\n" "$1"; }
do_export_backup
printf "RC:%s\n" "$?"
' _ "$SCRIPT" "$same_lang" 2>&1)
        case "$same_lang" in
            es) same_want="ERROR:El origen y el destino son la misma carpeta:"$'\n'"$SAME_ROOT/backups/Copia_same"$'\n\n'"Elige otra carpeta de destino (por ejemplo, un USB o un disco externo)."$'\n'"RC:1" ;;
            *)  same_want="ERROR:The source and the destination are the same folder:"$'\n'"$SAME_ROOT/backups/Copia_same"$'\n\n'"Choose a different destination folder (for example, a USB drive or an external disk)."$'\n'"RC:1" ;;
        esac
        [ "$SAME_OUT" = "$same_want" ] || fail "export to the source folder ($same_lang, via ${same_parent##*/}) was not refused with the exact message: $SAME_OUT"
        [ ! -e "$SAME_ROOT/confirm" ] || fail "export to the source folder asked to overwrite it ($same_lang, via ${same_parent##*/})"
        [ ! -e "$SAME_ROOT/progress" ] || fail "export to the source folder started copying ($same_lang, via ${same_parent##*/})"
        [ "$(stat -c %i "$SAME_ROOT/backups/Copia_same")" = "$SAME_INODE" ] || fail "export to the source folder replaced the original backup ($same_lang, via ${same_parent##*/})"
        [ "$(cat "$SAME_ROOT/backups/Copia_same/sub/b.txt")" = b ] || fail "export to the source folder changed the original content"
        find "$SAME_ROOT/backups" -mindepth 1 -maxdepth 1 ! -name Copia_same -print -quit | grep -q . && fail "export to the source folder left a temporary or rollback directory"
    done
done
pass "export refuses a destination that is the source itself, directly or through a symlink"

# Whatever already sits at the destination name (a folder, a file, a working
# symlink or a dangling one) must be asked about before it is replaced. A
# dangling symlink (for example, to a disk that is not mounted) counted as
# "absent" because -e follows the link, so it was replaced without asking.
# Declining must leave everything as it was; accepting replaces the entry
# itself and never creates or writes through a symlink's target.
DANG_ROOT="$TMP/export-dangling"
mkdir -p "$DANG_ROOT/home" "$DANG_ROOT/config" "$DANG_ROOT/backups/Copia_dang/sub"
printf 'a\n' > "$DANG_ROOT/backups/Copia_dang/a.txt"
printf 'b\n' > "$DANG_ROOT/backups/Copia_dang/sub/b.txt"
printf 'NAME=%q\nDATE=%q\nMODULES=%q\n' 'Copia dang' '2026-01-01' 'terminal' > "$DANG_ROOT/backups/Copia_dang/manifest.conf"
dang_tree() { find "$1" -mindepth 1 -printf '%P|%y|%l|%s\n' 2>/dev/null | sort; }
for dang_lang in es en; do
    for dang_kind in dangling file folder livelink; do
        for dang_answer in no yes; do
            rm -rf "$DANG_ROOT/dest" "$DANG_ROOT/missing" "$DANG_ROOT/elsewhere" "$DANG_ROOT/confirm" "$DANG_ROOT/progress"
            mkdir -p "$DANG_ROOT/dest"
            case "$dang_kind" in
                dangling) ln -s "$DANG_ROOT/missing" "$DANG_ROOT/dest/Copia_dang" ;;
                file)     printf 'precious\n' > "$DANG_ROOT/dest/Copia_dang" ;;
                folder)   mkdir "$DANG_ROOT/dest/Copia_dang"; printf 'old\n' > "$DANG_ROOT/dest/Copia_dang/old.txt" ;;
                livelink) mkdir "$DANG_ROOT/elsewhere"; printf 'keep\n' > "$DANG_ROOT/elsewhere/k.txt"; ln -s "$DANG_ROOT/elsewhere" "$DANG_ROOT/dest/Copia_dang" ;;
            esac
            dang_dest_before=$(dang_tree "$DANG_ROOT/dest")
            dang_else_before=$(dang_tree "$DANG_ROOT/elsewhere")
            DANG_OUT=$(HOME="$TMP/export-dangling/home" XDG_CONFIG_HOME="$TMP/export-dangling/config" MINT_SETUP_BACKUPS_DIR="$TMP/export-dangling/backups" \
                PATH="$MOCK:/usr/bin:/bin" LC_ALL=C.UTF-8 MINT_SETUP_TEST=1 DANG_ROOT="$TMP/export-dangling" DANG_ANSWER="$dang_answer" bash -c '
source "$1"
set_language "$2"
pick_backup_dir() { printf "%s\n" "$DANG_ROOT/backups/Copia_dang"; }
zenity() {
    case "$*" in
        *--file-selection*) printf "%s\n" "$DANG_ROOT/dest" ;;
        *--progress*) echo progress >> "$DANG_ROOT/progress"; cat > /dev/null ;;
    esac
}
confirm() { printf "%s\n---\n" "$1" >> "$DANG_ROOT/confirm"; [ "$DANG_ANSWER" = yes ]; }
msg_info() { printf "INFO:%s\n" "$1"; }
msg_error() { printf "ERROR:%s\n" "$1"; }
do_export_backup
printf "RC:%s\n" "$?"
' _ "$SCRIPT" "$dang_lang" 2>&1)
            case "$dang_lang" in
                es) dang_want="Ya existe una carpeta con ese nombre en el destino:"$'\n'"$DANG_ROOT/dest/Copia_dang"$'\n\n'"¿Sobrescribirla?" ;;
                *)  dang_want="A folder with that name already exists at the destination:"$'\n'"$DANG_ROOT/dest/Copia_dang"$'\n\n'"Overwrite it?" ;;
            esac
            dang_tag="$dang_kind, $dang_lang, answer $dang_answer"
            [ "$(cat "$DANG_ROOT/confirm" 2>/dev/null)" = "$dang_want"$'\n---' ] || fail "export did not ask exactly once, with the exact text, before replacing the destination ($dang_tag): $(cat "$DANG_ROOT/confirm" 2>&1)"
            [ "$(dang_tree "$DANG_ROOT/elsewhere")" = "$dang_else_before" ] || fail "export wrote through the destination symlink ($dang_tag)"
            [ "$dang_kind" != dangling ] || { [ ! -e "$DANG_ROOT/missing" ] && [ ! -L "$DANG_ROOT/missing" ]; } || fail "export created the missing target of a dangling symlink ($dang_tag)"
            if [ "$dang_answer" = no ]; then
                [ "$DANG_OUT" = "RC:0" ] || fail "declining to replace the destination did not end quietly ($dang_tag): $DANG_OUT"
                [ ! -e "$DANG_ROOT/progress" ] || fail "declining to replace the destination still started copying ($dang_tag)"
                [ "$(dang_tree "$DANG_ROOT/dest")" = "$dang_dest_before" ] || fail "declining to replace the destination changed it ($dang_tag)"
            else
                case "$DANG_OUT" in
                    INFO:*$'\nRC:0') : ;;
                    *) fail "accepted export over an existing destination did not report success ($dang_tag): $DANG_OUT" ;;
                esac
                [ -d "$DANG_ROOT/dest/Copia_dang" ] && [ ! -L "$DANG_ROOT/dest/Copia_dang" ] || fail "accepted export did not leave a real folder at the destination ($dang_tag)"
                diff -qr -- "$DANG_ROOT/backups/Copia_dang" "$DANG_ROOT/dest/Copia_dang" >/dev/null || fail "accepted export differs from the source ($dang_tag)"
                find "$DANG_ROOT/dest" -mindepth 1 -maxdepth 1 ! -name Copia_dang -print -quit | grep -q . && fail "accepted export left a temporary or rollback directory ($dang_tag)"
            fi
        done
    done
done
pass "export asks before replacing whatever is at the destination (folder, file, symlink, dangling symlink); declining changes nothing"

# 12.41: the previous copy at the destination was deleted with a bare rm -rf. A
# copy with a folder without write permission (copied from read-only media,
# 0555) made rm print its error raw, the dialog still said "exported
# successfully" and a hidden .NAME.mint-old.XXXXXX folder stayed in the
# destination (only the exit trap of the program removed it, never if the USB
# was pulled first). ms_rm_tmp opens the folders first; what still cannot be
# deleted is named in the dialog and stays registered for the exit trap. The rm
# of this test refuses the rollback folder (works for root too).
OLDD_ROOT="$TMP/export-old"; mkdir -p "$OLDD_ROOT/bin"
cat > "$OLDD_ROOT/bin/rm" <<'RM'
#!/bin/bash
for a in "$@"; do
    case "$a" in *.mint-old.*) echo "rm: cannot remove '$a': Operation not permitted" >&2; exit 1 ;; esac
done
exec /bin/rm "$@"
RM
chmod +x "$OLDD_ROOT/bin/rm"
old_prepare() {   # old_prepare plain|ro|fresh: a source copy and a destination that already holds an old one ("ro": with 0555 folders; "fresh": an empty destination)
    chmod -R u+rwX "$OLDD_ROOT/dest" 2>/dev/null; rm -rf "$OLDD_ROOT/dest" "$OLDD_ROOT/backups"
    mkdir -p "$OLDD_ROOT/backups/Copia_old/sub" "$OLDD_ROOT/dest"
    printf 'a\n' > "$OLDD_ROOT/backups/Copia_old/a.txt"
    printf 'b\n' > "$OLDD_ROOT/backups/Copia_old/sub/b.txt"
    printf 'NAME=%q\nDATE=%q\nMODULES=%q\n' 'Copia old' '2026-01-01' 'terminal' > "$OLDD_ROOT/backups/Copia_old/manifest.conf"
    [ "$1" != fresh ] || return 0
    mkdir -p "$OLDD_ROOT/dest/Copia_old"; printf 'old\n' > "$OLDD_ROOT/dest/Copia_old/old.txt"
    if [ "$1" = ro ]; then
        mkdir -p "$OLDD_ROOT/dest/Copia_old/ro/sub"; printf x > "$OLDD_ROOT/dest/Copia_old/ro/sub/f"
        chmod 555 "$OLDD_ROOT/dest/Copia_old/ro/sub" "$OLDD_ROOT/dest/Copia_old/ro"
    fi
}
old_run() {   # old_run LANG REFUSE ATTR: do_export_backup over that destination; results in $OLDD_ROOT/out
    local lang="$1" refuse="$2" attr="$3" path_pre=""
    [ "$refuse" -eq 0 ] || path_pre="$OLDD_ROOT/bin:"
    rm -rf "$OLDD_ROOT/out"; mkdir -p "$OLDD_ROOT/out"
    HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$OLDD_ROOT/backups" \
        PATH="$path_pre$MOCK:/usr/bin:/bin" LC_ALL=C.UTF-8 MINT_SETUP_TEST=1 \
        bash -c '
source "$1"; root=$2; set_language "$3"; attr=$4; out="$root/out"
pick_backup_dir() { printf "%s\n" "$root/backups/Copia_old"; }
zenity() {
    case "$*" in
        *--file-selection*) printf "%s\n" "$root/dest" ;;
        *--progress*) cat >/dev/null ;;
    esac
}
confirm() { return 0; }
msg_info() { printf "%s" "$1" > "$out/info"; }
msg_warn() { printf "%s" "$1" > "$out/warning"; }
msg_error() { printf "%s" "$1" > "$out/error"; }
if [ "$attr" -eq 1 ]; then   # the content is copied, but cp reports that attributes were not preserved
    cp() { command cp "$@"; echo "cp: failed to preserve ownership" >&2; return 1; }
fi
do_export_backup; echo "$?" > "$out/rc"
printf "%s\n" "${_MS_TMP[@]+"${_MS_TMP[@]}"}" > "$out/tracked"
' _ "$SCRIPT" "$OLDD_ROOT" "$lang" "$attr" >"$OLDD_ROOT/out/stdout" 2>"$OLDD_ROOT/out/stderr"
}
old_names() { find "$OLDD_ROOT/dest" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' '; }
old_info() { cat "$OLDD_ROOT/out/info" 2>/dev/null; }
old_tracked() { cat "$OLDD_ROOT/out/tracked" 2>/dev/null; }
old_clean() {   # old_clean TAG: rc 0, no warning or error dialog, nothing on stdout/stderr, exported copy equal to the source
    [ "$(cat "$OLDD_ROOT/out/rc" 2>/dev/null)" = 0 ] || fail "export over an old copy ($1): rc is not 0: $(cat "$OLDD_ROOT/out/rc" 2>&1)"
    { [ ! -e "$OLDD_ROOT/out/warning" ] && [ ! -e "$OLDD_ROOT/out/error" ]; } || fail "export over an old copy ($1): unexpected warning or error dialog"
    { [ ! -s "$OLDD_ROOT/out/stderr" ] && [ ! -s "$OLDD_ROOT/out/stdout" ]; } || fail "export over an old copy ($1): output outside the dialogs: $(cat "$OLDD_ROOT/out/stderr" "$OLDD_ROOT/out/stdout" 2>&1)"
    diff -qr -- "$OLDD_ROOT/backups/Copia_old" "$OLDD_ROOT/dest/Copia_old" >/dev/null || fail "export over an old copy ($1): the exported copy differs from the source"
}
old_find_left() { find "$OLDD_ROOT/dest" -mindepth 1 -maxdepth 1 -name '.Copia_old.mint-old.*'; }
OLD_ATTR_DETAIL='cp: failed to preserve ownership'
for old_lang in es en; do
    if [ "$old_lang" = es ]; then
        old_ok() { printf 'Copia exportada correctamente a:\n%s%s' "$1" "$2"; }
        old_note_left() { printf '\n\n⚠️ No se pudo borrar la copia anterior del destino, que sigue ocupando espacio (carpeta oculta). Bórrala a mano:\n%s' "$1"; }
        old_note_attr() { printf '\n\n⚠️ El contenido se ha verificado y está completo, pero algunos atributos (permisos, propietario o fechas) no se pudieron preservar. Es habitual en FAT32/exFAT, que no soportan permisos Unix.\n\nDetalle: %s' "$1"; }
    else
        old_ok() { printf 'Backup exported successfully to:\n%s%s' "$1" "$2"; }
        old_note_left() { printf '\n\n⚠️ The previous copy in the destination could not be deleted and still takes up space (hidden folder). Delete it by hand:\n%s' "$1"; }
        old_note_attr() { printf '\n\n⚠️ The content was verified and is complete, but some attributes (permissions, owner or timestamps) could not be preserved. This is common on FAT32/exFAT, which do not support Unix permissions.\n\nDetail: %s' "$1"; }
    fi
    old_dest="$OLDD_ROOT/dest/Copia_old"
    # control: the old copy is deleted, plain success, nothing left or registered
    old_prepare plain; old_run "$old_lang" 0 0
    [ "$(old_info)" = "$(old_ok "$old_dest" '')" ] || fail "export over an old copy ($old_lang): control run is not a clean success: $(old_info)"
    old_clean "control, $old_lang"
    [ "$(old_names)" = 'Copia_old ' ] || fail "export over an old copy ($old_lang): control run left entries in the destination: $(old_names)"
    [ -z "$(old_tracked)" ] || fail "export over an old copy ($old_lang): control run left a path registered for the exit trap: $(old_tracked)"
    # destination without a previous copy (rm refuses, but there is nothing to delete): plain success, no note, nothing left or registered
    old_prepare fresh; old_run "$old_lang" 1 0
    [ "$(old_info)" = "$(old_ok "$old_dest" '')" ] || fail "export to a new destination ($old_lang): not a clean success: $(old_info)"
    old_clean "new destination, $old_lang"
    [ "$(old_names)" = 'Copia_old ' ] || fail "export to a new destination ($old_lang): wrong entries: $(old_names)"
    [ -z "$(old_tracked)" ] || fail "export to a new destination ($old_lang): a path was registered: $(old_tracked)"
    # rm refuses the rollback folder: named in the dialog, kept intact and registered, exported copy complete, nothing raw on stderr
    old_prepare plain; old_run "$old_lang" 1 0
    old_left=$(old_find_left)
    [ "$(printf '%s\n' "$old_left" | grep -c .)" -eq 1 ] || fail "export over an old copy ($old_lang): expected one hidden rollback folder, found: $old_left"
    [ "$(old_info)" = "$(old_ok "$old_dest" "$(old_note_left "$old_left")")" ] || fail "export over an old copy ($old_lang): wrong dialog when the old copy cannot be deleted: $(old_info)"
    old_clean "rm refused, $old_lang"
    [ "$(old_names)" = "${old_left##*/} Copia_old " ] || fail "export over an old copy ($old_lang): wrong entries after a refused delete: $(old_names)"
    [ "$(cat "$old_left/old.txt" 2>/dev/null)" = old ] || fail "export over an old copy ($old_lang): the undeleted old copy was altered"
    [ "$(old_tracked)" = "$old_left" ] || fail "export over an old copy ($old_lang): the undeleted folder is not registered for the exit trap: $(old_tracked)"
    # attribute note and undeleted old copy together: both are shown, the old copy first
    old_prepare plain; old_run "$old_lang" 1 1
    old_left=$(old_find_left)
    [ "$(old_info)" = "$(old_ok "$old_dest" "$(old_note_left "$old_left")$(old_note_attr "$OLD_ATTR_DETAIL")")" ] || fail "export over an old copy ($old_lang): wrong dialog with both notes: $(old_info)"
    old_clean "rm refused and attributes, $old_lang"
    # attribute note alone (the old copy is deleted)
    old_prepare plain; old_run "$old_lang" 0 1
    [ "$(old_info)" = "$(old_ok "$old_dest" "$(old_note_attr "$OLD_ATTR_DETAIL")")" ] || fail "export over an old copy ($old_lang): wrong dialog with the attribute note only: $(old_info)"
    old_clean "attributes, $old_lang"
    [ "$(old_names)" = 'Copia_old ' ] || fail "export over an old copy ($old_lang): attribute-note run left entries in the destination: $(old_names)"
    # Without root only: the real case. Folders without write permission (0555) in the old copy must not stop the delete.
    if [ "$(id -u)" -ne 0 ]; then
        old_prepare ro; old_run "$old_lang" 0 0
        [ "$(old_info)" = "$(old_ok "$old_dest" '')" ] || fail "export over an old copy ($old_lang): old copy with read-only folders is not a clean success: $(old_info)"
        old_clean "read-only folders, $old_lang"
        [ "$(old_names)" = 'Copia_old ' ] || fail "export over an old copy ($old_lang): old copy with read-only folders left entries in the destination: $(old_names)"
        [ -z "$(old_tracked)" ] || fail "export over an old copy ($old_lang): old copy with read-only folders left a path registered: $(old_tracked)"
    fi
done
chmod -R u+rwX "$OLDD_ROOT" 2>/dev/null
pass "export over an existing destination: the old copy is deleted even with read-only folders; one that cannot be deleted is named in the dialog and stays registered for the exit trap; a destination without a previous copy exports cleanly (es/en)"

# 12.42: do_export_backup created its stderr capture (errfile and errfile.rc) with a
# bare mktemp, outside the list of temporaries: a TERM, HUP or INT during the copy
# (Ctrl+C in the terminal, closing the session) left both in the temp folder, while
# the staged copy was cleaned. Now both are registered and discarded on every way out,
# including the error branches that follow the capture (staging, setting the old copy
# aside, publishing), which no test reached before.
# The signal goes to the program's own process while the (slow) copy runs; bash runs
# the trap when the foreground pipeline returns, hence the one-second cp. A signal that is
# ignored at start cannot be trapped: a background job starts with INT ignored, and under
# nohup (or any parent that ignores HUP) so does HUP. Each round therefore gives the program
# the default disposition of its signal back (env --default-signal, coreutils 8.31+).
EXE_ROOT="$TMP/export-tmp"; mkdir -p "$EXE_ROOT/bin"
cat > "$EXE_ROOT/bin/cp" <<'CP'
#!/bin/bash
# EXE_CP_FAIL=1: leaves a partial copy and fails; otherwise a slow, real copy
: > "$EXE_ROOT/cp-running"
if [ "${EXE_CP_FAIL:-0}" = 1 ]; then /bin/mkdir -p "${@: -1}"; printf partial > "${@: -1}/partial"; exit 7; fi
/bin/sleep 1
exec /bin/cp "$@"
CP
chmod +x "$EXE_ROOT/bin/cp"
exe_run() {   # exe_run LANG [SIGNAL]: fresh source, destination and temp folder; results in $EXE_ROOT/out; EXE_CP_FAIL and EXE_TMPDIR tune the run
    local lang="$1" sig="${2:-}" job runner=(env) n mark=cp-running
    [ -z "$sig" ] || ! env --default-signal="$sig" true 2>/dev/null || runner=(env --default-signal="$sig")
    [ -z "${EXE_HOLD:-}" ] || mark=holding   # EXE_HOLD=info: the signal arrives while the final dialog is open
    rm -rf "$EXE_ROOT/backups" "$EXE_ROOT/dest" "$EXE_ROOT/tmp" "$EXE_ROOT/out" "$EXE_ROOT/cwd" "$EXE_ROOT/cp-running" "$EXE_ROOT/holding"
    mkdir -p "$EXE_ROOT/backups/Copia_exe/sub" "$EXE_ROOT/dest" "$EXE_ROOT/tmp" "$EXE_ROOT/out" "$EXE_ROOT/cwd"
    printf 'a\n' > "$EXE_ROOT/backups/Copia_exe/a.txt"
    printf 'b\n' > "$EXE_ROOT/backups/Copia_exe/sub/b.txt"
    printf 'NAME=%q\nDATE=%q\nMODULES=%q\n' 'Copia exe' '2026-01-01' 'terminal' > "$EXE_ROOT/backups/Copia_exe/manifest.conf"
    [ "${EXE_OLD:-0}" != 1 ] || { mkdir -p "$EXE_ROOT/dest/Copia_exe"; printf 'old\n' > "$EXE_ROOT/dest/Copia_exe/OLD.txt"; }
    # shellcheck disable=SC2016  # the inner bash expands $1..$3, not this shell
    (   cd "$EXE_ROOT/cwd" && "${runner[@]}" HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$EXE_ROOT/backups" \
            PATH="$EXE_ROOT/bin:$MOCK:/usr/bin:/bin" LC_ALL=C.UTF-8 MINT_SETUP_TEST=1 TMPDIR="${EXE_TMPDIR:-$EXE_ROOT/tmp}" \
            EXE_ROOT="$EXE_ROOT" EXE_CP_FAIL="${EXE_CP_FAIL:-0}" EXE_FAIL="${EXE_FAIL:-}" EXE_HOLD="${EXE_HOLD:-}" \
            bash -c '
source "$1"; root=$2; set_language "$3"; out="$root/out"; echo $$ > "$out/pid"
pick_backup_dir() { printf "%s\n" "$root/backups/Copia_exe"; }
zenity() {
    case "$*" in
        *--file-selection*) printf "%s\n" "$root/dest" ;;
        *--progress*) : > "$out/progress"; cat >/dev/null ;;
    esac
}
confirm() { return 0; }
msg_info() { printf "%s" "$1" > "$out/info"; if [ "${EXE_HOLD:-}" = info ]; then : > "$root/holding"; sleep 1; fi; }
msg_warn() { printf "%s" "$1" > "$out/warning"; }
msg_error() { printf "%s" "$1" > "$out/error"; }
case "${EXE_FAIL:-}" in
    stage)           mktemp() { case "$*" in *.mstmp.*) return 1 ;; esac; command mktemp "$@"; } ;;
    rollback-mktemp) mktemp() { case "$*" in *.mint-old.*) return 1 ;; esac; command mktemp "$@"; } ;;
    rollback-mv)     mv() { case "$*" in *.mint-old.*) return 1 ;; esac; command mv "$@"; } ;;
    rollback-rmdir)  rmdir() { case "$*" in *.mint-old.*) return 1 ;; esac; command rmdir "$@"; } ;;
    commit)          ms_commit() { return 1; } ;;
    # 12.43: publishing fails and the old copy cannot be put back (the aside "mv" is the only one that works)
    commit-stuck)    ms_commit() { return 1; }; mv() { case "$*" in *.mint-old.*"$root/dest/Copia_exe") return 1 ;; esac; command mv "$@"; } ;;
    # a slow publish that fails, to have a signal arrive in the middle; -stuck: the old copy cannot be put back either
    commit-slow)     ms_commit() { : > "$root/holding"; sleep 1; return 1; } ;;
    # the new copy is already published when the signal arrives: the old one is then a plain temporary
    commit-published-slow) ms_commit() { command mv -T -- "$1" "$2" && { : > "$root/holding"; sleep 1; }; } ;;
    commit-slow-stuck) ms_commit() { : > "$root/holding"; sleep 1; return 1; }; mv() { case "$*" in *.mint-old.*"$root/dest/Copia_exe") return 1 ;; esac; command mv "$@"; } ;;
esac
do_export_backup; echo "$?" > "$out/rc"
find "$TMPDIR" -mindepth 1 2>/dev/null > "$out/left"
printf "%s\n" "${_MS_TMP[@]+"${_MS_TMP[@]}"}" > "$out/tracked"
' _ "$SCRIPT" "$EXE_ROOT" "$lang" >"$EXE_ROOT/out/stdout" 2>"$EXE_ROOT/out/stderr"
    ) &
    job=$!
    EXE_RC=0
    if [ -n "$sig" ]; then
        for _ in $(seq 1 100); do [ -e "$EXE_ROOT/$mark" ] && break; sleep 0.05; done
        [ -e "$EXE_ROOT/$mark" ] || { kill "$job" 2>/dev/null; fail "export $sig: the copy (or the final dialog) never started"; }
        EXE_SEEN=$(find "$EXE_ROOT/tmp" -mindepth 1 | wc -l)   # control: the capture files exist while cp runs
        for _ in $(seq 1 40); do [ -s "$EXE_ROOT/out/pid" ] && break; sleep 0.05; done
        kill -"$sig" "$(cat "$EXE_ROOT/out/pid")" 2>/dev/null
    fi
    wait "$job" || EXE_RC=$?
    [ -n "$sig" ] || EXE_RC=$(cat "$EXE_ROOT/out/rc" 2>/dev/null)
    n=$(find "$EXE_ROOT/tmp" -mindepth 1 2>/dev/null | head -3 | tr '\n' ' ')
    EXE_LEFT="$n$(head -3 "$EXE_ROOT/out/left" 2>/dev/null | tr '\n' ' ')"   # after exit, and as the function returned
}
exe_none() {   # exe_none TAG: no temp file, nothing registered, nothing published or staged at the destination
    [ -z "$EXE_LEFT" ] || fail "export ($1): temporary files left in the temp folder: $EXE_LEFT"
    [ -z "$(cat "$EXE_ROOT/out/tracked" 2>/dev/null)" ] || fail "export ($1): a path is still registered: $(cat "$EXE_ROOT/out/tracked")"
    [ -z "$(ls -A "$EXE_ROOT/cwd")" ] || fail "export ($1): files created in the working folder: $(ls -A "$EXE_ROOT/cwd")"
}
# control: a successful export leaves nothing
exe_run es
[ "$EXE_RC" = 0 ] || fail "export (control): rc is $EXE_RC"
[ -e "$EXE_ROOT/out/info" ] || fail "export (control): no success dialog"
diff -qr -- "$EXE_ROOT/backups/Copia_exe" "$EXE_ROOT/dest/Copia_exe" >/dev/null || fail "export (control): the exported copy differs from the source"
exe_none "control"
# a copy that fails (and leaves a partial one): error dialog, rc 1, nothing left
EXE_CP_FAIL=1 exe_run es
[ "$EXE_RC" = 1 ] || fail "export (failed copy): rc is $EXE_RC"
[ -e "$EXE_ROOT/out/error" ] || fail "export (failed copy): no error dialog"
[ -z "$(ls -A "$EXE_ROOT/dest")" ] || fail "export (failed copy): the destination is not empty: $(ls -A "$EXE_ROOT/dest")"
exe_none "failed copy"
# TERM, HUP and INT while the copy runs, and while the final dialog is open (the copy is already
# published and both capture files exist): the program ends with the signal's code and leaves nothing
for exe_where in copy dialog; do
    for exe_sig in TERM:143 HUP:129 INT:130; do
        if [ "${exe_sig%%:*}" = INT ] && ! env --default-signal=INT true 2>/dev/null; then
            echo "SKIP: export INT during the $exe_where (needs env --default-signal)"; continue
        fi
        exe_tag="export ${exe_sig%%:*} during the $exe_where"
        if [ "$exe_where" = dialog ]; then EXE_HOLD=info; exe_min=2; else EXE_HOLD=; exe_min=1; fi
        EXE_HOLD="$EXE_HOLD" exe_run es "${exe_sig%%:*}"
        [ "$EXE_SEEN" -ge "$exe_min" ] || fail "$exe_tag (control): $EXE_SEEN capture file(s) existed at that moment, expected $exe_min or more"
        [ "$EXE_RC" = "${exe_sig##*:}" ] || fail "$exe_tag: rc is $EXE_RC, not ${exe_sig##*:}"
        if [ "$exe_where" = dialog ]; then
            diff -qr -- "$EXE_ROOT/backups/Copia_exe" "$EXE_ROOT/dest/Copia_exe" >/dev/null 2>&1 || fail "$exe_tag: the published copy is missing or differs: $(find "$EXE_ROOT/dest" -mindepth 1 -maxdepth 2 | tr '\n' ' ')"
            [ "$(find "$EXE_ROOT/dest" -mindepth 1 -maxdepth 1 | wc -l)" = 1 ] || fail "$exe_tag: extra entries at the destination: $(find "$EXE_ROOT/dest" -mindepth 1 -maxdepth 1 | tr '\n' ' ')"
        else
            [ -z "$(ls -A "$EXE_ROOT/dest")" ] || fail "$exe_tag: something was published or staged: $(ls -A "$EXE_ROOT/dest")"
        fi
        exe_none "${exe_tag#export }"
    done
done
EXE_HOLD=
# the error branches after the capture exists, over an old copy (es/en): error dialog naming
# the folder, rc 1, the old copy untouched, nothing staged, no capture file left or registered
for exe_lang in es en; do
    for exe_fail in stage rollback-mktemp rollback-rmdir rollback-mv commit; do
        EXE_OLD=1 EXE_FAIL="$exe_fail" exe_run "$exe_lang"
        exe_tag="export ($exe_fail, $exe_lang)"
        case "$exe_fail" in stage) exe_want="$EXE_ROOT/dest" ;; *) exe_want="$EXE_ROOT/dest/Copia_exe" ;; esac
        [ "$EXE_RC" = 1 ] || fail "$exe_tag: rc is $EXE_RC"
        case "$(cat "$EXE_ROOT/out/error" 2>/dev/null)" in *"$exe_want"*) ;; *) fail "$exe_tag: wrong or missing error dialog: $(cat "$EXE_ROOT/out/error" 2>&1)" ;; esac
        # 12.44: the two branches that run before the old copy is touched give the same exact notice (rmdir used to exit silently)
        case "$exe_fail" in rollback-mktemp|rollback-rmdir)
            case "$exe_lang" in es) exe_head='No se pudo preparar la sustitución segura del destino' ;; *) exe_head='Could not prepare the destination replacement safely' ;; esac
            [ "$(cat "$EXE_ROOT/out/error" 2>/dev/null)" = "$(printf '%s:\n%s' "$exe_head" "$exe_want")" ] || fail "$exe_tag: wrong error text: $(cat "$EXE_ROOT/out/error" 2>&1)" ;;
        esac
        [ ! -e "$EXE_ROOT/out/info" ] || fail "$exe_tag: a success dialog came up"
        [ "$(ls -A "$EXE_ROOT/dest")" = Copia_exe ] || fail "$exe_tag: the destination holds: $(find "$EXE_ROOT/dest" -mindepth 1 -maxdepth 1 | tr '\n' ' ')"
        [ "$(cat "$EXE_ROOT/dest/Copia_exe/OLD.txt" 2>/dev/null)" = old ] || fail "$exe_tag: the old copy was not kept"
        [ ! -e "$EXE_ROOT/dest/Copia_exe/a.txt" ] || fail "$exe_tag: the new copy was published"
        [ -z "$EXE_LEFT" ] || fail "$exe_tag: temporary files left in the temp folder: $EXE_LEFT"
        [ -z "$(ls -A "$EXE_ROOT/cwd")" ] || fail "$exe_tag: files created in the working folder"
        [ -z "$(cat "$EXE_ROOT/out/tracked")" ] || fail "$exe_tag: a path is still registered: $(cat "$EXE_ROOT/out/tracked")"
    done
done
# 12.43: publishing fails and the old copy cannot be put back either. It is then the only copy the
# user has: it must survive the exit cleanup in its hidden folder, and the dialog (or stderr, when the
# exit was a signal) must say where it is. A signal in the middle of a publish that fails, with the old
# copy put back normally, leaves it in its place and says nothing; one that arrives after the new copy
# was published deletes the old one, as usual.
exe_stuck_check() {   # exe_stuck_check TAG: the old copy is alone in its hidden folder; sets EXE_HIDDEN
    EXE_HIDDEN=$(find "$EXE_ROOT/dest" -mindepth 1 -maxdepth 1 -name '.Copia_exe.mint-old.*')
    [ -n "$EXE_HIDDEN" ] && [ "$(printf '%s\n' "$EXE_HIDDEN" | wc -l)" = 1 ] || fail "export ($1): the old copy's hidden folder is missing or not unique: $(find "$EXE_ROOT/dest" -mindepth 1 -maxdepth 1 | tr '\n' ' ')"
    [ "$(cat "$EXE_HIDDEN/OLD.txt" 2>/dev/null)" = old ] || fail "export ($1): the old copy was deleted or changed"
    [ "$(find "$EXE_ROOT/dest" -mindepth 1 -maxdepth 1 | wc -l)" = 1 ] || fail "export ($1): the destination holds more than the hidden folder: $(find "$EXE_ROOT/dest" -mindepth 1 -maxdepth 1 | tr '\n' ' ')"
    [ -z "$EXE_LEFT" ] || fail "export ($1): temporary files left in the temp folder: $EXE_LEFT"
}
for exe_lang in es en; do
    EXE_OLD=1 EXE_FAIL=commit-stuck exe_run "$exe_lang"
    exe_tag="commit and put-back fail, $exe_lang"
    [ "$EXE_RC" = 1 ] || fail "export ($exe_tag): rc is $EXE_RC"
    exe_stuck_check "$exe_tag"
    case "$(cat "$EXE_ROOT/out/error" 2>/dev/null)" in *"$EXE_HIDDEN"*) ;; *) fail "export ($exe_tag): the dialog does not name the hidden folder: $(cat "$EXE_ROOT/out/error" 2>&1)" ;; esac
    { [ ! -s "$EXE_ROOT/out/stdout" ] && [ ! -s "$EXE_ROOT/out/stderr" ]; } || fail "export ($exe_tag): output outside the dialog: $(cat "$EXE_ROOT/out/stdout" "$EXE_ROOT/out/stderr" 2>&1)"
    [ -z "$(cat "$EXE_ROOT/out/tracked")" ] || fail "export ($exe_tag): a path is still registered: $(cat "$EXE_ROOT/out/tracked")"
    EXE_HOLD=commit EXE_OLD=1 EXE_FAIL=commit-slow-stuck exe_run "$exe_lang" TERM
    exe_tag="TERM during a failing publish, put-back fails, $exe_lang"
    [ "$EXE_RC" = 143 ] || fail "export ($exe_tag): rc is $EXE_RC"
    exe_stuck_check "$exe_tag"
    case "$(cat "$EXE_ROOT/out/stderr" 2>/dev/null)" in *"$EXE_HIDDEN"*) ;; *) fail "export ($exe_tag): stderr does not name the hidden folder: $(cat "$EXE_ROOT/out/stderr" 2>&1)" ;; esac
    EXE_HOLD=commit EXE_OLD=1 EXE_FAIL=commit-slow exe_run "$exe_lang" TERM
    exe_tag="TERM during a failing publish, put-back works, $exe_lang"
    [ "$EXE_RC" = 143 ] || fail "export ($exe_tag): rc is $EXE_RC"
    [ "$(find "$EXE_ROOT/dest" -mindepth 1 -maxdepth 1 | tr '\n' ' ')" = "$EXE_ROOT/dest/Copia_exe " ] || fail "export ($exe_tag): the destination holds: $(find "$EXE_ROOT/dest" -mindepth 1 -maxdepth 1 | tr '\n' ' ')"
    [ "$(cat "$EXE_ROOT/dest/Copia_exe/OLD.txt" 2>/dev/null)" = old ] || fail "export ($exe_tag): the old copy is not back in its place"
    [ ! -s "$EXE_ROOT/out/stderr" ] || fail "export ($exe_tag): stderr is not empty: $(cat "$EXE_ROOT/out/stderr" 2>&1)"
    [ -z "$EXE_LEFT" ] || fail "export ($exe_tag): temporary files left in the temp folder: $EXE_LEFT"
    EXE_HOLD=commit EXE_OLD=1 EXE_FAIL=commit-published-slow exe_run "$exe_lang" TERM
    exe_tag="TERM right after publishing, $exe_lang"
    [ "$EXE_RC" = 143 ] || fail "export ($exe_tag): rc is $EXE_RC"
    diff -qr -- "$EXE_ROOT/backups/Copia_exe" "$EXE_ROOT/dest/Copia_exe" >/dev/null 2>&1 || fail "export ($exe_tag): the published copy is missing or differs"
    [ "$(find "$EXE_ROOT/dest" -mindepth 1 -maxdepth 1 | wc -l)" = 1 ] || fail "export ($exe_tag): the destination holds more than the new copy: $(find "$EXE_ROOT/dest" -mindepth 1 -maxdepth 1 | tr '\n' ' ')"
    [ ! -s "$EXE_ROOT/out/stderr" ] || fail "export ($exe_tag): stderr is not empty: $(cat "$EXE_ROOT/out/stderr" 2>&1)"
    [ -z "$EXE_LEFT" ] || fail "export ($exe_tag): temporary files left in the temp folder: $EXE_LEFT"
done
EXE_HOLD=
# no writable temp folder: a clear error, no copy started, nothing created (es/en)
for exe_lang in es en; do
    EXE_TMPDIR="$EXE_ROOT/missing" exe_run "$exe_lang"
    [ "$EXE_RC" = 1 ] || fail "export (no temp folder, $exe_lang): rc is $EXE_RC"
    case "$exe_lang" in es) exe_want='No se pudo crear el archivo temporal.' ;; *) exe_want='Could not create the temporary file.' ;; esac
    [ "$(cat "$EXE_ROOT/out/error" 2>/dev/null)" = "$exe_want" ] || fail "export (no temp folder, $exe_lang): wrong error dialog: $(cat "$EXE_ROOT/out/error" 2>&1)"
    { [ ! -e "$EXE_ROOT/out/progress" ] && [ ! -e "$EXE_ROOT/cp-running" ]; } || fail "export (no temp folder, $exe_lang): the copy started"
    [ -z "$(ls -A "$EXE_ROOT/dest")" ] || fail "export (no temp folder, $exe_lang): the destination is not empty: $(ls -A "$EXE_ROOT/dest")"
    { [ ! -s "$EXE_ROOT/out/stdout" ] && [ ! -s "$EXE_ROOT/out/stderr" ]; } || fail "export (no temp folder, $exe_lang): output outside the dialog: $(cat "$EXE_ROOT/out/stdout" "$EXE_ROOT/out/stderr" 2>&1)"
    exe_none "no temp folder, $exe_lang"
done
pass "export: its stderr capture is a registered temporary: nothing is left after a success, a failed copy, a TERM, HUP or INT during the copy or with the final dialog open, or a failure while staging, setting the old copy aside or publishing (an old copy that cannot be put back is kept, and named); a temp folder that cannot be written gives a clear error and copies nothing (es/en)"

# NetworkManager restore publishes each new connection atomically and never
# overwrites an existing connection.
NET_BACKUP="$TMP/network-backup"; NET_SRC="$TMP/network-source/system-connections"; NET_TARGET="$TMP/network-target"
mkdir -p "$NET_BACKUP/network" "$NET_SRC" "$NET_TARGET"
printf 'old-network\n' > "$NET_TARGET/existing.nmconnection"
chmod 640 "$NET_TARGET/existing.nmconnection"
printf 'new-network\n' > "$NET_SRC/existing.nmconnection"
printf 'new-only\n' > "$NET_SRC/new.nmconnection"
tar czf "$NET_BACKUP/network/system-connections.tar.gz" -C "$TMP/network-source" system-connections
NET_HOME="$TMP/network-home" NET_CFG="$TMP/network-config" PATH="$MOCK:/usr/bin:/bin" \
    NET_BACKUP="$NET_BACKUP" NET_TARGET="$NET_TARGET" HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" \
    MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 bash -c '
source "$1"
prun() {
    [ "$1" = bash ] && [ "$2" = -c ] || return 1
    local cmd="$3"; shift 3
    cmd="${cmd//\/etc\/NetworkManager\/system-connections/$NET_TARGET}"
    bash -c "$cmd" "$@"
}
restore_network "$NET_BACKUP"
' _ "$SCRIPT" >/dev/null 2>&1 || fail "network restore success flow exited non-zero"
grep -qx 'old-network' "$NET_TARGET/existing.nmconnection" || fail "network restore overwrote an existing connection"
[ "$(stat -c '%a' "$NET_TARGET/existing.nmconnection")" = 640 ] || fail "network restore changed an existing connection mode"
grep -qx 'new-only' "$NET_TARGET/new.nmconnection" || fail "network restore did not create a new connection"
[ "$(stat -c '%a' "$NET_TARGET/new.nmconnection")" = 600 ] || fail "new network connection mode is not 600"
find "$NET_TARGET" -name '.*.mstmp.*' -print -quit | grep -q . && fail "network restore left an atomic temporary"
pass "network restore uses atomic per-file publication"

NET_FAIL_TARGET="$TMP/network-failure-target"; NET_FAIL_BIN="$TMP/network-failure-bin"
mkdir -p "$NET_FAIL_TARGET" "$NET_FAIL_BIN"
printf 'must-survive\n' > "$NET_FAIL_TARGET/existing.nmconnection"
cat > "$NET_FAIL_BIN/cp" <<'CPFAIL'
#!/bin/bash
target="${@: -1}"
printf 'partial\n' > "$target"
exit 7
CPFAIL
cat > "$NET_FAIL_BIN/systemctl" <<'SYSFAIL'
#!/bin/sh
exit 0
SYSFAIL
chmod +x "$NET_FAIL_BIN/cp" "$NET_FAIL_BIN/systemctl"
NET_HOME="$TMP/network-fail-home" NET_CFG="$TMP/network-fail-config" \
    PATH="$NET_FAIL_BIN:$MOCK:/usr/bin:/bin" NET_BACKUP="$NET_BACKUP" NET_TARGET="$NET_FAIL_TARGET" \
    HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
    bash -c '
source "$1"
prun() {
    [ "$1" = bash ] && [ "$2" = -c ] || return 1
    local cmd="$3"; shift 3
    cmd="${cmd//\/etc\/NetworkManager\/system-connections/$NET_TARGET}"
    bash -c "$cmd" "$@"
}
set +e
restore_network "$NET_BACKUP" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] || exit 1
' _ "$SCRIPT" >/dev/null 2>&1 || fail "network restore failure harness hid the module failure"
grep -qx 'must-survive' "$NET_FAIL_TARGET/existing.nmconnection" || fail "failed network restore altered the previous connection"
[ ! -e "$NET_FAIL_TARGET/new.nmconnection" ] || fail "failed network restore published partial content"
find "$NET_FAIL_TARGET" -name '.*.mstmp.*' -print -quit | grep -q . && fail "failed network restore left a temporary"
pass "failed network restore leaves no partial connection"

# A malicious network archive must be rejected before privileged extraction.
NET_UNSAFE_BACKUP="$TMP/network-unsafe-backup"; NET_UNSAFE_ROOT="$TMP/network-unsafe-root"
mkdir -p "$NET_UNSAFE_BACKUP/network" "$NET_UNSAFE_ROOT"
python3 - "$NET_UNSAFE_BACKUP/network/system-connections.tar.gz" <<'PYTAR'
import io
import tarfile
import sys
with tarfile.open(sys.argv[1], "w:gz") as tf:
    data = b"must-not-escape\n"
    info = tarfile.TarInfo("../outside.nmconnection")
    info.size = len(data)
    tf.addfile(info, io.BytesIO(data))
PYTAR
NET_UNSAFE_OUTSIDE="$NET_UNSAFE_ROOT/outside.nmconnection"
PATH="$MOCK:/usr/bin:/bin" NET_BACKUP="$NET_UNSAFE_BACKUP" NET_TARGET="$NET_UNSAFE_ROOT/target" NET_UNSAFE_OUTSIDE="$NET_UNSAFE_OUTSIDE" \
    HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
    bash -c '
source "$1"
prun() { return 0; }
set +e
restore_network "$NET_BACKUP" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$NET_UNSAFE_OUTSIDE" ]
' _ "$SCRIPT" || fail "network restore accepted an unsafe archive"
pass "network restore rejects unsafe archives before extraction"

# Save must not report success for privileged modules when PolicyKit is unavailable.
NO_PKEXEC_STAGE="$TMP/no-pkexec-stage"; mkdir -p "$NO_PKEXEC_STAGE"
PATH="$MOCK:/usr/bin:/bin" HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
    bash -c '
source "$1"
log_msg(){ :; }
command(){
    if [ "${1:-}" = "-v" ] && [ "${2:-}" = "pkexec" ]; then return 1; fi
    builtin command "$@"
}
set +e
run_save_module network "$2"
network_rc=$?
run_save_module bluetooth "$2"
bluetooth_rc=$?
printf "%s %s\n" "$network_rc" "$bluetooth_rc"
[ "$network_rc" -ne 0 ] && [ "$bluetooth_rc" -ne 0 ]
' _ "$SCRIPT" "$NO_PKEXEC_STAGE" >/dev/null 2>&1 || fail "privileged save without pkexec reported success"
pass "privileged saves fail when pkexec is unavailable"

# The common pre-authorization step must also report a missing PolicyKit helper;
# otherwise the UI would not warn before the privileged modules fail later.
PATH="$MOCK:/usr/bin:/bin" HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
    bash -c '
source "$1"
command(){
    if [ "${1:-}" = "-v" ] && [ "${2:-}" = "pkexec" ]; then return 1; fi
    builtin command "$@"
}
set +e
root_preauth "network bluetooth" network
rc=$?
[ "$rc" -ne 0 ]
' _ "$SCRIPT" >/dev/null 2>&1 || fail "root pre-authorization hid missing pkexec"
pass "root pre-authorization reports missing pkexec"

# Backup publication must fail closed when the backup root cannot be made private.
BACKUP_ROOT_PERM_OUT=$(HOME="$HOME_DIR" XDG_CONFIG_HOME="$TMP/backup-root-perm-cfg" MINT_SETUP_BACKUPS_DIR="$TMP/backup-root-perm" \
    MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 bash -c '
chmod(){ return 17; }
command(){ if [ "${1:-}" = "-v" ] && [ "${2:-}" = "zenity" ]; then return 1; fi; builtin command "$@"; }
source "$1"
' _ "$SCRIPT" 2>&1)
BACKUP_ROOT_PERM_RC=$?
[ "$BACKUP_ROOT_PERM_RC" -ne 0 ] || fail "backup root permission failure was reported as success"
printf '%s\n' "$BACKUP_ROOT_PERM_OUT" | grep -Fq 'private permissions (700)' || fail "backup root permission failure was not explained"
pass "backup root permission failures fail closed"

# A completed staging tree must not be published if its final privacy hardening fails.
BACKUP_TREE_PERM_ROOT="$TMP/backup-tree-perm"
mkdir -p "$BACKUP_TREE_PERM_ROOT/home" "$BACKUP_TREE_PERM_ROOT/config" "$BACKUP_TREE_PERM_ROOT/backups"
# shellcheck disable=SC2097,SC2098  # values taken from this shell are deliberately re-exported to the child
BACKUP_TREE_PERM_OUT=$(HOME="$BACKUP_TREE_PERM_ROOT/home" XDG_CONFIG_HOME="$BACKUP_TREE_PERM_ROOT/config" MINT_SETUP_BACKUPS_DIR="$BACKUP_TREE_PERM_ROOT/backups" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
    BACKUP_TREE_PERM_ROOT="$BACKUP_TREE_PERM_ROOT" bash -c '
source "$1"
set_language en
zenity(){
    case " $* " in
        *" --list "*) printf "terminal\n";;
        *" --entry "*) printf "PermCheck\n";;
        *" --progress "*) cat >/dev/null;;
        *" --error "*|*" --warning "*) :;;
    esac
}
save_terminal(){ local d="$1/terminal"; mkdir -p "$d"; printf "saved\n" > "$d/.bashrc"; }
# Keep source-time permission setup working; fail only on the staging-tree hardening step.
chmod(){
    case " $* " in
        *" -R go-rwx "*) return 23;;
        *) command chmod "$@";;
    esac
}
set +e
do_save
rc=$?
printf "RC:%s\n" "$rc"
' _ "$SCRIPT" 2>&1)
printf '%s\n' "$BACKUP_TREE_PERM_OUT" | grep -Fq 'RC:1' || fail "backup tree permission failure was reported as success"
find "$BACKUP_TREE_PERM_ROOT/backups" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print -quit | grep -q . && fail "backup tree permission failure published a backup"
pass "backup tree permission hardening fails closed"

# Software restore publishes new APT files atomically and keeps existing files. The three archives
# come from the real pack_dir, so a folder-name drift between save and restore (it once left
# trusted.gpg.d unrestored) cannot hide behind a hand-made fixture. Modes: apt reads keyrings as
# _apt and the sources as a normal user, so a saved 644 must stay 644 (it once came out as 600 and
# "apt-get update" failed with NO_PUBKEY); a saved 600 stays 600; a tampered mode is masked to 644.
SOFT_BACKUP="$TMP/software-backup"; SOFT_SRC="$TMP/software-source"; SOFT_TARGET="$TMP/software-target"
mkdir -p "$SOFT_BACKUP/software" "$SOFT_SRC/sources.list.d/sub" "$SOFT_SRC/keyrings" "$SOFT_SRC/trusted.gpg.d" "$SOFT_TARGET/sources.list.d" "$SOFT_TARGET/keyrings" "$SOFT_TARGET/trusted.gpg.d"
printf 'old-source\n' > "$SOFT_TARGET/sources.list.d/existing.list"
printf 'new-source\n' > "$SOFT_SRC/sources.list.d/existing.list"
printf 'only-source\n' > "$SOFT_SRC/sources.list.d/new.list"
printf 'secret-source\n' > "$SOFT_SRC/sources.list.d/secret.list"
printf 'odd-source\n' > "$SOFT_SRC/sources.list.d/odd.list"
printf 'nested-source\n' > "$SOFT_SRC/sources.list.d/sub/nested.list"
printf 'key-data\n' > "$SOFT_SRC/keyrings/example.gpg"
printf 'trusted-data\n' > "$SOFT_SRC/trusted.gpg.d/example.gpg"
chmod 644 "$SOFT_SRC/sources.list.d/new.list" "$SOFT_SRC/sources.list.d/existing.list" "$SOFT_SRC/sources.list.d/sub/nested.list" "$SOFT_SRC/keyrings/example.gpg" "$SOFT_SRC/trusted.gpg.d/example.gpg"
chmod 600 "$SOFT_SRC/sources.list.d/secret.list"
chmod 4777 "$SOFT_SRC/sources.list.d/odd.list"
# A non-root "tar x" masks modes with the umask unless -p is given (root keeps them either way),
# so the suite emulates that and the -p of restore_software is checked whoever runs the tests.
SOFT_TAR_BIN="$TMP/software-tar-bin"; mkdir -p "$SOFT_TAR_BIN"
cat > "$SOFT_TAR_BIN/tar" <<'NONROOTTAR'
#!/bin/bash
case "${1:-}" in
    *x*p*) ;;
    *x*) exec /usr/bin/tar --no-same-permissions "-$1" "${@:2}" ;;
esac
exec /usr/bin/tar "$@"
NONROOTTAR
chmod +x "$SOFT_TAR_BIN/tar"
HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 PATH="$MOCK:/usr/bin:/bin" bash -c '
source "$1"
pack_dir "$2/sources.list.d" "$3/sources-list-d.tar.gz" && pack_dir "$2/keyrings" "$3/keyrings.tar.gz" && pack_dir "$2/trusted.gpg.d" "$3/trusted-gpg-d.tar.gz"
' _ "$SCRIPT" "$SOFT_SRC" "$SOFT_BACKUP/software" || fail "software fixture: pack_dir failed"
PATH="$SOFT_TAR_BIN:$MOCK:/usr/bin:/bin" SOFT_BACKUP="$SOFT_BACKUP" SOFT_TARGET="$SOFT_TARGET" HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" \
    MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 bash -c '
source "$1"
prun() {
    [ "$1" = bash ] && [ "$2" = -c ] || return 1
    local cmd="$3"; shift 3
    cmd="${cmd//\/etc\/apt/$SOFT_TARGET}"
    bash -c "$cmd" "$@"
}
restore_software "$SOFT_BACKUP"
' _ "$SCRIPT" >/dev/null 2>&1 || fail "software restore success flow exited non-zero"
grep -qx 'old-source' "$SOFT_TARGET/sources.list.d/existing.list" || fail "software restore overwrote an existing source"
grep -qx 'only-source' "$SOFT_TARGET/sources.list.d/new.list" || fail "software restore did not create a new source"
grep -qx 'key-data' "$SOFT_TARGET/keyrings/example.gpg" || fail "software restore did not create a keyring"
grep -qx 'trusted-data' "$SOFT_TARGET/trusted.gpg.d/example.gpg" || fail "software restore did not create a trusted.gpg.d key"
grep -qx 'nested-source' "$SOFT_TARGET/sources.list.d/sub/nested.list" || fail "software restore did not create a file in a new subfolder"
[ "$(stat -c '%a' "$SOFT_TARGET/sources.list.d/new.list")" = 644 ] || fail "new software source lost its saved mode 644"
[ "$(stat -c '%a' "$SOFT_TARGET/keyrings/example.gpg")" = 644 ] || fail "restored keyring is not readable by apt (mode is not 644)"
[ "$(stat -c '%a' "$SOFT_TARGET/trusted.gpg.d/example.gpg")" = 644 ] || fail "restored trusted.gpg.d key is not readable by apt (mode is not 644)"
[ "$(stat -c '%a' "$SOFT_TARGET/sources.list.d/secret.list")" = 600 ] || fail "software restore widened a source saved as 600"
[ "$(stat -c '%a' "$SOFT_TARGET/sources.list.d/odd.list")" = 644 ] || fail "software restore kept special bits from a tampered mode"
[ "$(stat -c '%a' "$SOFT_TARGET/sources.list.d/sub")" = 755 ] || fail "software restore created a subfolder that apt cannot traverse"
find "$SOFT_TARGET" -name '.*.mstmp.*' -print -quit | grep -q . && fail "software restore left an atomic temporary"
pass "software restore uses atomic per-file publication and keeps apt-readable modes"

SOFT_FAIL_TARGET="$TMP/software-failure-target"; SOFT_FAIL_BIN="$TMP/software-failure-bin"
mkdir -p "$SOFT_FAIL_TARGET/sources.list.d" "$SOFT_FAIL_BIN"
printf 'must-survive\n' > "$SOFT_FAIL_TARGET/sources.list.d/existing.list"
cat > "$SOFT_FAIL_BIN/cp" <<'CPSOFTFAIL'
#!/bin/bash
target="${@: -1}"
printf 'partial\n' > "$target"
exit 7
CPSOFTFAIL
cat > "$SOFT_FAIL_BIN/apt-get" <<'APTSOFTFAIL'
#!/bin/sh
exit 0
APTSOFTFAIL
chmod +x "$SOFT_FAIL_BIN/cp" "$SOFT_FAIL_BIN/apt-get"
PATH="$SOFT_FAIL_BIN:$MOCK:/usr/bin:/bin" SOFT_BACKUP="$SOFT_BACKUP" SOFT_TARGET="$SOFT_FAIL_TARGET" HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" \
    MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 bash -c '
source "$1"
prun() {
    [ "$1" = bash ] && [ "$2" = -c ] || return 1
    local cmd="$3"; shift 3
    cmd="${cmd//\/etc\/apt/$SOFT_TARGET}"
    bash -c "$cmd" "$@"
}
restore_software "$SOFT_BACKUP"
' _ "$SCRIPT" >/dev/null 2>&1
SOFT_FAIL_RC=$?
[ "$SOFT_FAIL_RC" -ne 0 ] || fail "software restore failure was reported as success"
grep -qx 'must-survive' "$SOFT_FAIL_TARGET/sources.list.d/existing.list" || fail "failed software restore altered the previous source"
[ ! -e "$SOFT_FAIL_TARGET/sources.list.d/new.list" ] || fail "failed software restore published partial content"
find "$SOFT_FAIL_TARGET" -name '.*.mstmp.*' -print -quit | grep -q . && fail "failed software restore left a temporary"
pass "failed software restore leaves no partial APT file"

# APT cache discovery is required: a failed apt-cache query must not turn every
# package into an apparently unavailable package and produce a false success.
SOFT_APT_CACHE_FAIL_BACKUP="$TMP/software-apt-cache-failure"; SOFT_APT_CACHE_FAIL_BIN="$TMP/software-apt-cache-failure-bin"
mkdir -p "$SOFT_APT_CACHE_FAIL_BACKUP/software" "$SOFT_APT_CACHE_FAIL_BIN"
printf 'example-package\n' > "$SOFT_APT_CACHE_FAIL_BACKUP/software/apt-manual.list"
cat > "$SOFT_APT_CACHE_FAIL_BIN/apt-cache" <<'APT_CACHE_FAIL'
#!/bin/sh
exit 19
APT_CACHE_FAIL
chmod +x "$SOFT_APT_CACHE_FAIL_BIN/apt-cache"
PATH="$SOFT_APT_CACHE_FAIL_BIN:$MOCK:/usr/bin:/bin" SOFT_APT_CACHE_FAIL_BACKUP="$SOFT_APT_CACHE_FAIL_BACKUP" HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
    bash -c '
source "$1"
log_msg(){ :; }
prun(){ return 0; }
set +e
restore_software "$SOFT_APT_CACHE_FAIL_BACKUP" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ]
' _ "$SCRIPT" >/dev/null 2>&1 || fail "APT cache failure was reported as a successful Applications restore"
pass "APT cache failures propagate from Applications restore"

# Applications restore: once the repositories are copied, a failed "apt-get update"
# (typically a PPA that is gone: exit 100) is not a failure to restore them. The
# notice must say so, and the update must not be repeated (one more administrator
# prompt and one more wait for the same result). A copy that fails, or a denied
# pkexec, keeps the original "could not be restored" notice. The archive is the
# ones made by the real pack_dir above; only the repository module runs, with the
# /etc/apt paths redirected to a temporary folder. A copy failure is injected per
# folder (sources.list.d, keyrings, trusted.gpg.d: one "exit 1" each).
SOFTU_BACKUP="$TMP/software-update-backup"; SOFTU_TARGET="$TMP/software-update-target"
SOFTU_BIN="$TMP/software-update-bin"; SOFTU_CPFAIL_BIN="$TMP/software-update-cpfail-bin"
SOFTU_LOG="$TMP/software-update-apt.log"; SOFTU_PRUN="$TMP/software-update-prun.log"
mkdir -p "$SOFTU_BACKUP/software" "$SOFTU_BIN" "$SOFTU_CPFAIL_BIN"
cp "$SOFT_BACKUP/software/sources-list-d.tar.gz" "$SOFT_BACKUP/software/keyrings.tar.gz" "$SOFT_BACKUP/software/trusted-gpg-d.tar.gz" "$SOFTU_BACKUP/software/" || fail "software update fixture: archive missing"
printf 'pkg-a\npkg-b\n' > "$SOFTU_BACKUP/software/apt-manual.list"
cat > "$SOFTU_BIN/apt-get" <<'APTUPD'
#!/bin/sh
printf '%s\n' "$*" >> "$SOFTU_LOG"
[ "$1" = update ] && exit "${SOFTU_UPDATE_RC:-0}"
exit 0
APTUPD
cat > "$SOFTU_BIN/apt-cache" <<'APTCACHEUPD'
#!/bin/sh
[ "$1" = pkgnames ] && printf 'pkg-a\npkg-b\n'
exit 0
APTCACHEUPD
cat > "$SOFTU_CPFAIL_BIN/cp" <<'CPUPDFAIL'
#!/bin/sh
case "$*" in *"$SOFTU_CP_FAIL"*) exit 7 ;; esac
exec /usr/bin/cp "$@"
CPUPDFAIL
chmod +x "$SOFTU_BIN/apt-get" "$SOFTU_BIN/apt-cache" "$SOFTU_CPFAIL_BIN/cp"
softu_run() {   # softu_run LANG CASE (ok|upd100|denied|cp-sources.list.d|cp-keyrings|cp-trusted.gpg.d) -> softu_rc, softu_out; fresh target and logs
    local path="$SOFTU_BIN:$MOCK:/usr/bin:/bin" upd=0 deny=0 cpfail=""
    [ "$2" = upd100 ] && upd=100
    [ "$2" = denied ] && deny=1
    case "$2" in cp-*) cpfail="${2#cp-}"; path="$SOFTU_CPFAIL_BIN:$path" ;; esac
    rm -rf "$SOFTU_TARGET"; mkdir -p "$SOFTU_TARGET/sources.list.d" "$SOFTU_TARGET/keyrings" "$SOFTU_TARGET/trusted.gpg.d"
    : > "$SOFTU_LOG"; : > "$SOFTU_PRUN"
    softu_out=$(PATH="$path" SOFTU_TARGET="$SOFTU_TARGET" SOFTU_LOG="$SOFTU_LOG" SOFTU_PRUN="$SOFTU_PRUN" SOFTU_UPDATE_RC="$upd" SOFTU_DENY="$deny" SOFTU_CP_FAIL="$cpfail" \
        HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 bash -c '
source "$1"; APP_LANG="$2"
log_msg() { printf "%s\n" "$1"; }
prun() {
    printf "%s\n" "$1" >> "$SOFTU_PRUN"
    if [ "$1" = bash ] && [ "$2" = -c ]; then
        [ "$SOFTU_DENY" = 1 ] && return 126
        local cmd="$3"; shift 3
        cmd="${cmd//\/etc\/apt/$SOFTU_TARGET}"
        bash -c "$cmd" "$@"
    else
        "$@"
    fi
}
run_restore_module software "$3"
' _ "$SCRIPT" "$1" "$SOFTU_BACKUP" 2>&1)
    softu_rc=$?
}
for softu_lang in es en; do
    if [ "$softu_lang" = es ]; then
        softu_done='Aplicaciones restauradas.'
        softu_partial='Aviso: Aplicaciones se restauró parcialmente; revisa los avisos anteriores.'
        softu_upd='Aviso: los repositorios se restauraron, pero «apt-get update» terminó con errores (algún repositorio puede haber dejado de existir o no responder).'
        softu_norest='Aviso: no se pudieron restaurar los repositorios (permisos denegados o cancelado).'
        softu_cache='Aviso: no se pudo actualizar la caché APT antes de instalar los paquetes.'
    else
        softu_done='Applications restored.'
        softu_partial='Warning: Applications was only partially restored; review the previous warnings.'
        softu_upd='Warning: the repositories were restored, but “apt-get update” finished with errors (a repository may no longer exist or may not be responding).'
        softu_norest='Warning: the repositories could not be restored (permission denied or cancelled).'
        softu_cache='Warning: could not update the APT cache before installing the packages.'
    fi
    # Control: the update works, so one update and two administrator calls (repositories, install).
    softu_run "$softu_lang" ok
    [ "$softu_rc" -eq 0 ] || fail "software update ($softu_lang): the control restore failed (rc $softu_rc, out: $softu_out)"
    grep -Fqx -- "$softu_done" <<<"$softu_out" || fail "software update ($softu_lang): the control did not announce the restore (out: $softu_out)"
    for softu_bad in "$softu_upd" "$softu_norest" "$softu_cache" "$softu_partial"; do
        ! grep -Fqx -- "$softu_bad" <<<"$softu_out" || fail "software update ($softu_lang): the control showed a warning: $softu_bad"
    done
    [ "$(grep -c '^update ' "$SOFTU_LOG")" -eq 1 ] || fail "software update ($softu_lang): control did not update exactly once ($(cat "$SOFTU_LOG"))"
    [ "$(grep -c '' "$SOFTU_PRUN")" -eq 2 ] || fail "software update ($softu_lang): control did not use exactly two administrator calls"
    # Repositories copied, update ends with 100: accurate notice, a single update, the rest goes on.
    softu_run "$softu_lang" upd100
    [ "$softu_rc" -ne 0 ] || fail "software update ($softu_lang): a failed apt-get update was reported as success"
    grep -Fqx -- "$softu_upd" <<<"$softu_out" || fail "software update ($softu_lang): no notice that only the update failed (out: $softu_out)"
    grep -Fqx -- "$softu_partial" <<<"$softu_out" || fail "software update ($softu_lang): no partial notice after a failed update"
    ! grep -Fqx -- "$softu_norest" <<<"$softu_out" || fail "software update ($softu_lang): a restored repository set was reported as not restored"
    ! grep -Fqx -- "$softu_cache" <<<"$softu_out" || fail "software update ($softu_lang): the update was attempted a second time"
    ! grep -Fqx -- "$softu_done" <<<"$softu_out" || fail "software update ($softu_lang): announced a full restore after a failed update"
    [ "$(grep -c '^update ' "$SOFTU_LOG")" -eq 1 ] || fail "software update ($softu_lang): apt-get update ran $(grep -c '^update ' "$SOFTU_LOG") times"
    [ "$(grep -c '' "$SOFTU_PRUN")" -eq 2 ] || fail "software update ($softu_lang): $(grep -c '' "$SOFTU_PRUN") administrator calls, expected 2"
    if ! { grep -qx 'only-source' "$SOFTU_TARGET/sources.list.d/new.list" && grep -qx 'key-data' "$SOFTU_TARGET/keyrings/example.gpg" \
        && grep -qx 'trusted-data' "$SOFTU_TARGET/trusted.gpg.d/example.gpg"; }; then
        fail "software update ($softu_lang): the repository files were not published"
    fi
    grep -qx 'install -y pkg-a pkg-b' "$SOFTU_LOG" || fail "software update ($softu_lang): packages were not installed after the failed update"
    # A copy that fails (in any of the three folders) or a denied pkexec: the repositories really were not restored.
    for softu_case in cp-sources.list.d cp-keyrings cp-trusted.gpg.d denied; do
        softu_run "$softu_lang" "$softu_case"
        [ "$softu_rc" -ne 0 ] || fail "software update ($softu_lang, $softu_case): failure reported as success"
        grep -Fqx -- "$softu_norest" <<<"$softu_out" || fail "software update ($softu_lang, $softu_case): no 'could not be restored' notice (out: $softu_out)"
        ! grep -Fqx -- "$softu_upd" <<<"$softu_out" || fail "software update ($softu_lang, $softu_case): blamed the update for a repository failure"
        # The repository step stopped before its own update: the only one is the retry before installing.
        [ "$(grep -c '^update ' "$SOFTU_LOG")" -eq 1 ] || fail "software update ($softu_lang, $softu_case): apt-get update ran $(grep -c '^update ' "$SOFTU_LOG") times, expected 1"
        if [ "$softu_case" = cp-sources.list.d ] || [ "$softu_case" = denied ]; then
            [ ! -e "$SOFTU_TARGET/sources.list.d/new.list" ] || fail "software update ($softu_lang, $softu_case): published a repository file"
        fi
    done
done
pass "software restore: a failed apt-get update after copying the repositories is reported as such, once (es/en)"

# Bluetooth restore follows the same atomic per-file/no-clobber contract.
BT_BACKUP="$TMP/bluetooth-backup"; BT_SRC="$TMP/bluetooth-source/bluetooth"; BT_TARGET="$TMP/bluetooth-target"
mkdir -p "$BT_BACKUP/bluetooth/AA:BB:CC" "$BT_SRC/AA:BB:CC" "$BT_TARGET/AA:BB:CC"
printf 'old-device\n' > "$BT_TARGET/AA:BB:CC/info"
printf 'old-device-from-backup\n' > "$BT_SRC/AA:BB:CC/info"
printf 'new-device\n' > "$BT_SRC/AA:BB:CC/attributes"
tar czf "$BT_BACKUP/bluetooth/bluetooth.tar.gz" -C "$TMP/bluetooth-source" bluetooth
BT_FAIL_BIN="$TMP/bluetooth-bin"; mkdir -p "$BT_FAIL_BIN"
cat > "$BT_FAIL_BIN/systemctl" <<'SYSBT'
#!/bin/sh
exit 0
SYSBT
chmod +x "$BT_FAIL_BIN/systemctl"
PATH="$MOCK:/usr/bin:/bin" BT_BACKUP="$BT_BACKUP" BT_TARGET="$BT_TARGET" HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" \
    MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 bash -c '
source "$1"
prun() {
    [ "$1" = bash ] && [ "$2" = -c ] || return 1
    local cmd="$3"; shift 3
    cmd="${cmd//\/var\/lib\/bluetooth/$BT_TARGET}"
    bash -c "$cmd" "$@"
}
restore_bluetooth "$BT_BACKUP"
' _ "$SCRIPT" >/dev/null 2>&1 || fail "bluetooth restore success flow exited non-zero"
grep -qx 'old-device' "$BT_TARGET/AA:BB:CC/info" || fail "bluetooth restore overwrote an existing device file"
grep -qx 'new-device' "$BT_TARGET/AA:BB:CC/attributes" || fail "bluetooth restore did not create a new file"
[ "$(stat -c '%a' "$BT_TARGET/AA:BB:CC/attributes")" = 600 ] || fail "bluetooth restore widened permissions on a new file"
find "$BT_TARGET" -name '.*.mstmp.*' -print -quit | grep -q . && fail "bluetooth restore left an atomic temporary"
pass "bluetooth restore uses atomic per-file publication"

rm -f "$BT_TARGET/AA:BB:CC/attributes"
BT_FAIL_BIN="$TMP/bluetooth-failure-bin"; mkdir -p "$BT_FAIL_BIN"
cat > "$BT_FAIL_BIN/cp" <<'CPBTFAIL'
#!/bin/bash
target="${@: -1}"
printf 'partial
' > "$target"
exit 7
CPBTFAIL
cat > "$BT_FAIL_BIN/systemctl" <<'SYSBTFAIL'
#!/bin/sh
exit 0
SYSBTFAIL
chmod +x "$BT_FAIL_BIN/cp" "$BT_FAIL_BIN/systemctl"
PATH="$BT_FAIL_BIN:$MOCK:/usr/bin:/bin" BT_BACKUP="$BT_BACKUP" BT_TARGET="$BT_TARGET" HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" \
    MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 bash -c '
source "$1"
prun() {
    [ "$1" = bash ] && [ "$2" = -c ] || return 1
    local cmd="$3"; shift 3
    cmd="${cmd//\/var\/lib\/bluetooth/$BT_TARGET}"
    bash -c "$cmd" "$@"
}
set +e
restore_bluetooth "$BT_BACKUP"
rc=$?
printf "RC:%s\n" "$rc"
[ "$rc" -ne 0 ]
' _ "$SCRIPT" >/dev/null 2>&1 || fail "bluetooth restore hid a publication failure"
[ ! -e "$BT_TARGET/AA:BB:CC/attributes" ] || fail "failed bluetooth restore published partial content"
find "$BT_TARGET" -name '.*.mstmp.*' -print -quit | grep -q . && fail "failed bluetooth restore left a temporary"
pass "failed bluetooth restore propagates module failure"

# The privileged copy loops read the file list with `read -d ''`. In a UTF-8 locale bash 5.2
# swallows the NUL after a name whose last byte is an incomplete multibyte sequence (Latin-1
# "é" or "ó" at the end) and drops the NEXT file: the module answered "restored" with files
# missing. Each module gets 5 plain names and 2 of those; the tree that arrives must be the
# tree that was saved (names compared byte by byte).
L1_NAMES=(alfa beta gamma delta epsilon "$(LC_ALL=C printf 'Jos\xe9')" "$(LC_ALL=C printf 'Canci\xf3')")
l1_tree() {   # l1_tree DIR: one file per name, holding its own name
    local d="$1" n
    mkdir -p -- "$d"
    for n in "${L1_NAMES[@]}"; do printf 'content-of-%s\n' "$n" > "$d/$n"; done
}
l1_hashes() { ( cd "$1" && LC_ALL=C find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha1sum ); }
l1_restore() {   # l1_restore MODULE BACKUP: runs restore_MODULE with the root commands redirected
    L1_NET="$TMP/l1-target/net" L1_BT="$TMP/l1-target/bt" L1_APT="$TMP/l1-target/apt" \
    PATH="$MOCK:/usr/bin:/bin" HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" \
        MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 bash -c '
source "$1"
prun() {
    [ "$1" = bash ] && [ "$2" = -c ] || return 1
    local cmd="$3"; shift 3
    cmd="${cmd//\/etc\/NetworkManager\/system-connections/$L1_NET}"
    cmd="${cmd//\/var\/lib\/bluetooth/$L1_BT}"
    cmd="${cmd//\/etc\/apt/$L1_APT}"
    bash -c "$cmd" "$@"
}
"restore_$2" "$3"' _ "$SCRIPT" "$1" "$2" >/dev/null 2>&1
}
L1_ROOT="$TMP/l1"
mkdir -p "$L1_ROOT/net/network" "$L1_ROOT/bt/bluetooth" "$L1_ROOT/apt/software" "$L1_ROOT/ref" "$TMP/l1-target/net" "$TMP/l1-target/bt" "$TMP/l1-target/apt"
l1_tree "$L1_ROOT/ref/tree"
[ "$(l1_hashes "$L1_ROOT/ref/tree" | wc -l)" -eq 7 ] || fail "Latin-1 fixture: expected 7 files"
l1_tree "$L1_ROOT/net/src/system-connections"
tar czf "$L1_ROOT/net/network/system-connections.tar.gz" -C "$L1_ROOT/net/src" system-connections
l1_tree "$L1_ROOT/bt/src/bluetooth"
tar czf "$L1_ROOT/bt/bluetooth/bluetooth.tar.gz" -C "$L1_ROOT/bt/src" bluetooth
l1_tree "$L1_ROOT/apt/src/sources.list.d"; l1_tree "$L1_ROOT/apt/src/keyrings"
tar czf "$L1_ROOT/apt/software/sources-list-d.tar.gz" -C "$L1_ROOT/apt/src" sources.list.d
tar czf "$L1_ROOT/apt/software/keyrings.tar.gz" -C "$L1_ROOT/apt/src" keyrings

l1_restore network "$L1_ROOT/net" || fail "network restore with Latin-1 names exited non-zero"
[ "$(l1_hashes "$TMP/l1-target/net")" = "$(l1_hashes "$L1_ROOT/ref/tree")" ] \
    || fail "network restore lost files with Latin-1 names ($(l1_hashes "$TMP/l1-target/net" | wc -l) of 7 arrived)"
pass "network restore keeps every connection, names that are not valid UTF-8 included"

l1_restore bluetooth "$L1_ROOT/bt" || fail "bluetooth restore with Latin-1 names exited non-zero"
[ "$(l1_hashes "$TMP/l1-target/bt")" = "$(l1_hashes "$L1_ROOT/ref/tree")" ] \
    || fail "bluetooth restore lost files with Latin-1 names ($(l1_hashes "$TMP/l1-target/bt" | wc -l) of 7 arrived)"
pass "bluetooth restore keeps every file, names that are not valid UTF-8 included"

l1_restore software "$L1_ROOT/apt" || fail "software restore with Latin-1 names exited non-zero"
for l1_d in sources.list.d keyrings; do
    [ "$(l1_hashes "$TMP/l1-target/apt/$l1_d")" = "$(l1_hashes "$L1_ROOT/ref/tree")" ] \
        || fail "software restore lost files in $l1_d with Latin-1 names ($(l1_hashes "$TMP/l1-target/apt/$l1_d" | wc -l) of 7 arrived)"
done
pass "software restore keeps every repository and key, names that are not valid UTF-8 included"

# A malicious Bluetooth archive must be rejected before privileged extraction.
BT_UNSAFE_BACKUP="$TMP/bluetooth-unsafe-backup"; BT_UNSAFE_ROOT="$TMP/bluetooth-unsafe-root"
mkdir -p "$BT_UNSAFE_BACKUP/bluetooth" "$BT_UNSAFE_ROOT"
python3 - "$BT_UNSAFE_BACKUP/bluetooth/bluetooth.tar.gz" <<'PYTARBT'
import io
import tarfile
import sys
with tarfile.open(sys.argv[1], "w:gz") as tf:
    data = b"must-not-escape\n"
    info = tarfile.TarInfo("../outside-device.conf")
    info.size = len(data)
    tf.addfile(info, io.BytesIO(data))
PYTARBT
BT_UNSAFE_OUTSIDE="$BT_UNSAFE_ROOT/outside-device.conf"
PATH="$MOCK:/usr/bin:/bin" BT_BACKUP="$BT_UNSAFE_BACKUP" BT_TARGET="$BT_UNSAFE_ROOT/target" BT_UNSAFE_OUTSIDE="$BT_UNSAFE_OUTSIDE" \
    HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
    bash -c '
source "$1"
prun() { return 0; }
set +e
restore_bluetooth "$BT_BACKUP" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$BT_UNSAFE_OUTSIDE" ]
' _ "$SCRIPT" || fail "bluetooth restore accepted an unsafe archive"
pass "bluetooth restore rejects unsafe archives before extraction"

# Docker daemon restore replaces daemon.json only after the temporary file is complete.
DOCKER_BACKUP="$TMP/docker-backup"; DOCKER_TARGET="$TMP/docker-target"
mkdir -p "$DOCKER_BACKUP/docker" "$DOCKER_TARGET"
printf '{"old":true}\n' > "$DOCKER_TARGET/daemon.json"
chmod 640 "$DOCKER_TARGET/daemon.json"
printf '{"new":true}\n' > "$DOCKER_BACKUP/docker/daemon.json"
chmod 644 "$DOCKER_BACKUP/docker/daemon.json"
PATH="$MOCK:/usr/bin:/bin" DOCKER_BACKUP="$DOCKER_BACKUP" DOCKER_TARGET="$DOCKER_TARGET" \
    HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
    bash -c '
source "$1"
prun() {
    [ "$1" = bash ] && [ "$2" = -c ] || return 1
    local cmd="$3"; shift 3
    cmd="${cmd//\/etc\/docker/$DOCKER_TARGET}"
    bash -c "$cmd" "$@"
}
restore_docker "$DOCKER_BACKUP"
' _ "$SCRIPT" >/dev/null 2>&1 || fail "docker daemon restore success flow exited non-zero"
grep -qx '{"new":true}' "$DOCKER_TARGET/daemon.json" || fail "docker daemon restore did not publish the complete file"
[ "$(stat -c '%a' "$DOCKER_TARGET/daemon.json")" = 640 ] || fail "docker daemon restore did not preserve existing destination permissions"
find "$DOCKER_TARGET" -name '.*.mstmp.*' -print -quit | grep -q . && fail "docker daemon restore left an atomic temporary"
pass "docker daemon restore uses atomic publication"

rm -f "$DOCKER_TARGET/daemon.json"
PATH="$MOCK:/usr/bin:/bin" DOCKER_BACKUP="$DOCKER_BACKUP" DOCKER_TARGET="$DOCKER_TARGET" \
    HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
    bash -c '
source "$1"
prun() {
    [ "$1" = bash ] && [ "$2" = -c ] || return 1
    local cmd="$3"; shift 3
    cmd="${cmd//\/etc\/docker/$DOCKER_TARGET}"
    bash -c "$cmd" "$@"
}
restore_docker "$DOCKER_BACKUP"
' _ "$SCRIPT" >/dev/null 2>&1 || fail "docker daemon fresh-destination restore exited non-zero"
[ "$(stat -c '%a' "$DOCKER_TARGET/daemon.json")" = 600 ] || fail "docker daemon fresh restore widened permissions from a private temporary"
pass "docker daemon fresh restore defaults to 0600"

DOCKER_FAIL_BIN="$TMP/docker-failure-bin"; mkdir -p "$DOCKER_FAIL_BIN"
cat > "$DOCKER_FAIL_BIN/cp" <<'CPDOCKERFAIL'
#!/bin/bash
target="${@: -1}"
printf '{"partial":true}\n' > "$target"
exit 7
CPDOCKERFAIL
cat > "$DOCKER_FAIL_BIN/systemctl" <<'SYSDOCKERFAIL'
#!/bin/sh
exit 0
SYSDOCKERFAIL
chmod +x "$DOCKER_FAIL_BIN/cp" "$DOCKER_FAIL_BIN/systemctl"
printf '{"keep":true}\n' > "$DOCKER_TARGET/daemon.json"
PATH="$DOCKER_FAIL_BIN:$MOCK:/usr/bin:/bin" DOCKER_BACKUP="$DOCKER_BACKUP" DOCKER_TARGET="$DOCKER_TARGET" \
    HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
    bash -c '
source "$1"
prun() {
    [ "$1" = bash ] && [ "$2" = -c ] || return 1
    local cmd="$3"; shift 3
    cmd="${cmd//\/etc\/docker/$DOCKER_TARGET}"
    bash -c "$cmd" "$@"
}
restore_docker "$DOCKER_BACKUP"
' _ "$SCRIPT" >/dev/null 2>&1
DOCKER_FAIL_RC=$?
[ "$DOCKER_FAIL_RC" -ne 0 ] || fail "docker daemon restore failure was reported as success"
grep -qx '{"keep":true}' "$DOCKER_TARGET/daemon.json" || fail "failed docker daemon restore replaced the previous file"
grep -R -q 'partial' "$DOCKER_TARGET" && fail "failed docker daemon restore leaked partial content"
find "$DOCKER_TARGET" -name '.*.mstmp.*' -print -quit | grep -q . && fail "failed docker daemon restore left a temporary"
pass "failed docker daemon restore leaves no partial JSON"

# Failure to add the user to the docker group must also be reported; the daemon
# and user configuration may be restored, but the requested group membership is not complete.
DOCKER_GROUP_BACKUP="$TMP/docker-group-backup"
mkdir -p "$DOCKER_GROUP_BACKUP/docker"
printf 'true\n' > "$DOCKER_GROUP_BACKUP/docker/user-in-docker-group"
PATH="$MOCK:/usr/bin:/bin" DOCKER_GROUP_BACKUP="$DOCKER_GROUP_BACKUP" HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
    bash -c '
source "$1"
getent(){ [ "${1:-}" = group ] && [ "${2:-}" = docker ]; }
id(){ case "${1:-}" in -un) printf "testuser\n";; -nG) printf "users\n";; *) return 1;; esac; }
prun(){ [ "${1:-}" = usermod ] && return 17; return 1; }
set +e
restore_docker "$DOCKER_GROUP_BACKUP" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ]
' _ "$SCRIPT" >/dev/null 2>&1 || fail "docker group restore failure was reported as success"
pass "docker group restore failures propagate"

# A saved docker-group membership cannot be considered restored while the
# target group itself is absent.
DOCKER_NO_GROUP_BACKUP="$TMP/docker-no-group-backup"
mkdir -p "$DOCKER_NO_GROUP_BACKUP/docker"
printf 'true\n' > "$DOCKER_NO_GROUP_BACKUP/docker/user-in-docker-group"
PATH="$MOCK:/usr/bin:/bin" DOCKER_NO_GROUP_BACKUP="$DOCKER_NO_GROUP_BACKUP" HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
    bash -c '
source "$1"
getent(){ return 2; }
set +e
restore_docker "$DOCKER_NO_GROUP_BACKUP" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ]
' _ "$SCRIPT" >/dev/null 2>&1 || fail "missing docker group was reported as a successful restore"
pass "missing docker group propagates restore failure"

# Docker daemon: if daemon.json is published but Docker does not restart with
# it, the module is partial. Through run_restore_module (what do_restore uses)
# that is a failure with its own warning, never "Docker restored" with rc 0.
# systemctl status 5 means there is no docker.service (nothing to restart): not
# a failure. /etc/docker is redirected and the privileged script runs unprivileged.
DKR_BACKUP="$TMP/docker-restart-backup"; DKR_BIN="$TMP/docker-restart-bin"
DKR_TARGET="$TMP/docker-restart-target"; DKR_HOME="$TMP/docker-restart-home"
DKR_LOG="$TMP/docker-restart-systemctl.log"
mkdir -p "$DKR_BACKUP/docker" "$DKR_BIN"
printf '{"new":true}\n' > "$DKR_BACKUP/docker/daemon.json"
printf '#!/bin/sh\nexit 0\n' > "$DKR_BIN/docker"
cat > "$DKR_BIN/systemctl" <<'SYSRESTART'
#!/bin/sh
printf '%s\n' "$*" >> "$DKR_LOG"
[ "${DKR_SYSCTL_RC:-0}" -eq 0 ] || echo "systemctl: simulated restart failure" >&2
exit "${DKR_SYSCTL_RC:-0}"
SYSRESTART
chmod +x "$DKR_BIN/docker" "$DKR_BIN/systemctl"
dkr_run() {   # dkr_run LANG SYSTEMCTL_RC ok|deny [PATH_PREFIX] [BACKUP] [fresh] -> dkr_rc, dkr_out (log lines + stderr); target with the old file (absent if "fresh"), empty systemctl log
    rm -rf "$DKR_HOME" "$DKR_TARGET"; mkdir -p "$DKR_HOME/.config" "$DKR_TARGET"
    printf '{"old":true}\n' > "$DKR_TARGET/daemon.json"; : > "$DKR_LOG"
    [ "${6:-}" = fresh ] && rm -rf "$DKR_TARGET"
    dkr_out=$(HOME="$DKR_HOME" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
        PATH="${4:+$4:}$DKR_BIN:$MOCK:/usr/bin:/bin" DKR_LOG="$DKR_LOG" DKR_TARGET="$DKR_TARGET" \
        DKR_SYSCTL_RC="$2" DKR_PKEXEC="$3" bash -c '
source "$1"; APP_LANG="$2"
log_msg() { printf "%s\n" "$1"; }
prun() {
    [ "$DKR_PKEXEC" = deny ] && return 126
    [ "$1" = bash ] && [ "$2" = -c ] || return 1
    local cmd="$3"; shift 3
    cmd="${cmd//\/etc\/docker/$DKR_TARGET}"
    bash -c "$cmd" "$@"
}
run_restore_module docker "$3"
' _ "$SCRIPT" "$1" "${5:-$DKR_BACKUP}" 2>&1)
    dkr_rc=$?
}
for dkr_lang in es en; do
    if [ "$dkr_lang" = es ]; then
        dkr_partial='Aviso: Docker se restauró parcialmente; revisa los avisos anteriores.'
        dkr_done='Docker restaurado.'
        dkr_norestart='Aviso: /etc/docker/daemon.json se restauró, pero Docker no se pudo reiniciar; revisa «systemctl status docker».'
        dkr_denied='Aviso: no se pudo restaurar /etc/docker/daemon.json (permisos denegados o cancelado).'
    else
        dkr_partial='Warning: Docker was only partially restored; review the previous warnings.'
        dkr_done='Docker restored.'
        dkr_norestart='Warning: /etc/docker/daemon.json was restored, but Docker could not be restarted; check “systemctl status docker”.'
        dkr_denied='Warning: /etc/docker/daemon.json could not be restored (permission denied or cancelled).'
    fi
    # The restart fails (1; 127: no systemctl): partial, own warning, file published, cause kept.
    for dkr_sys in 1 127; do
        dkr_run "$dkr_lang" "$dkr_sys" ok
        [ "$dkr_rc" -ne 0 ] || fail "docker restore ($dkr_lang, systemctl $dkr_sys): a Docker that does not restart was reported as success (rc 0)"
        grep -Fqx -- "$dkr_norestart" <<<"$dkr_out" || fail "docker restore ($dkr_lang, systemctl $dkr_sys): no restart warning (out: $dkr_out)"
        grep -Fqx -- "$dkr_partial" <<<"$dkr_out" || fail "docker restore ($dkr_lang, systemctl $dkr_sys): no partial notice (out: $dkr_out)"
        ! grep -Fqx -- "$dkr_done" <<<"$dkr_out" || fail "docker restore ($dkr_lang, systemctl $dkr_sys): announced \"restored\" after a failed restart"
        ! grep -Fqx -- "$dkr_denied" <<<"$dkr_out" || fail "docker restore ($dkr_lang, systemctl $dkr_sys): blamed permissions for a failed restart"
        grep -qx '{"new":true}' "$DKR_TARGET/daemon.json" || fail "docker restore ($dkr_lang, systemctl $dkr_sys): daemon.json was not published"
        grep -Fqx 'systemctl: simulated restart failure' <<<"$dkr_out" || fail "docker restore ($dkr_lang, systemctl $dkr_sys): the cause (systemctl's message) was lost"
        [ "$(cat "$DKR_LOG")" = 'restart docker' ] || fail "docker restore ($dkr_lang, systemctl $dkr_sys): systemctl was not called once with 'restart docker' (log: $(cat "$DKR_LOG"))"
    done
    # Control (restart works) and status 5 (no docker.service): not a failure, no noise.
    for dkr_sys in 0 5; do
        dkr_run "$dkr_lang" "$dkr_sys" ok
        [ "$dkr_rc" -eq 0 ] || fail "docker restore ($dkr_lang, systemctl $dkr_sys): a correct restore failed (rc $dkr_rc, out: $dkr_out)"
        grep -Fqx -- "$dkr_done" <<<"$dkr_out" || fail "docker restore ($dkr_lang, systemctl $dkr_sys): the correct restore did not announce it (out: $dkr_out)"
        ! grep -Fqx -- "$dkr_partial" <<<"$dkr_out" || fail "docker restore ($dkr_lang, systemctl $dkr_sys): the correct restore showed the partial notice"
        ! grep -Fqx -- "$dkr_norestart" <<<"$dkr_out" || fail "docker restore ($dkr_lang, systemctl $dkr_sys): warned about a restart that did not fail"
        ! grep -Fq 'simulated restart failure' <<<"$dkr_out" || fail "docker restore ($dkr_lang, systemctl $dkr_sys): printed systemctl's message though nothing failed"
        grep -qx '{"new":true}' "$DKR_TARGET/daemon.json" || fail "docker restore ($dkr_lang, systemctl $dkr_sys): daemon.json was not published"
        [ "$(cat "$DKR_LOG")" = 'restart docker' ] || fail "docker restore ($dkr_lang, systemctl $dkr_sys): systemctl was not called once with 'restart docker' (log: $(cat "$DKR_LOG"))"
    done
    # pkexec denied or cancelled, or the copy fails: the previous warning, nothing replaced, no restart.
    for dkr_case in deny copy; do
        if [ "$dkr_case" = deny ]; then dkr_run "$dkr_lang" 0 deny; else dkr_run "$dkr_lang" 0 ok "$DOCKER_FAIL_BIN"; fi
        [ "$dkr_rc" -ne 0 ] || fail "docker restore ($dkr_lang, $dkr_case): a failed restore was reported as success (rc 0)"
        grep -Fqx -- "$dkr_denied" <<<"$dkr_out" || fail "docker restore ($dkr_lang, $dkr_case): the permissions warning is gone (out: $dkr_out)"
        grep -Fqx -- "$dkr_partial" <<<"$dkr_out" || fail "docker restore ($dkr_lang, $dkr_case): no partial notice (out: $dkr_out)"
        ! grep -Fqx -- "$dkr_norestart" <<<"$dkr_out" || fail "docker restore ($dkr_lang, $dkr_case): blamed the restart for a failure to publish the file"
        grep -qx '{"old":true}' "$DKR_TARGET/daemon.json" || fail "docker restore ($dkr_lang, $dkr_case): the previous daemon.json was replaced"
        [ ! -s "$DKR_LOG" ] || fail "docker restore ($dkr_lang, $dkr_case): systemctl ran although nothing was published"
    done
done
pass "docker restore: a Docker that does not restart with daemon.json is a partial restore (es/en)"

# Docker group: names are compared whole. With "grep -w" a user in
# "docker-users" (a hyphen splits words) counted as a member of "docker": the
# restore skipped usermod ("already a member") and the save stored a membership
# that does not exist, which a later restore would turn into real (root-
# equivalent) docker group membership.
DGR_BACKUP="$TMP/docker-group-exact-backup"; DGR_SAVE="$TMP/docker-group-exact-save"
DGR_BIN="$TMP/docker-group-exact-bin"; DGR_HOME="$TMP/docker-group-exact-home"
DGR_CALLS="$TMP/docker-group-exact-prun.log"
mkdir -p "$DGR_BACKUP/docker" "$DGR_BIN"
printf 'true\n' > "$DGR_BACKUP/docker/user-in-docker-group"
printf '#!/bin/sh\nexit 0\n' > "$DGR_BIN/docker"; chmod +x "$DGR_BIN/docker"
dgr_run() {   # dgr_run restore|save LANG "GROUPS" -> dgr_rc, dgr_out (log lines + stderr), dgr_calls (prun calls), dgr_marker (1: the save wrote the membership marker)
    local dgr_dir="$DGR_SAVE"; [ "$1" = restore ] && dgr_dir="$DGR_BACKUP"
    rm -rf "$DGR_HOME" "$DGR_SAVE"; mkdir -p "$DGR_HOME/.config" "$DGR_SAVE"; : > "$DGR_CALLS"
    dgr_out=$(HOME="$DGR_HOME" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
        PATH="$DGR_BIN:$MOCK:/usr/bin:/bin" DGR_GROUPS="$3" DGR_CALLS="$DGR_CALLS" bash -c '
source "$1"; APP_LANG="$3"
log_msg() { printf "%s\n" "$1"; }
getent() { [ "${1:-}" = group ] && [ "${2:-}" = docker ]; }
id() {
    case "${1:-}" in
        -un) printf "testuser\n" ;;
        -nG) [ "${2:-}" = testuser ] && printf "%s\n" "$DGR_GROUPS" ;;
        *) command id "$@" ;;
    esac
}
prun() { printf "%s\n" "$*" >> "$DGR_CALLS"; return 0; }
if [ "$2" = restore ]; then run_restore_module docker "$4"; else save_docker "$4"; fi
' _ "$SCRIPT" "$1" "$2" "$dgr_dir" 2>&1)
    dgr_rc=$?
    dgr_calls=$(cat "$DGR_CALLS")
    dgr_marker=0; [ -f "$DGR_SAVE/docker/user-in-docker-group" ] && dgr_marker=1
}
dgr_members=("users docker" "docker" "staff docker sudo")
dgr_others=("users" "docker-users" "my-docker" "docker.admin")
for dgr_lang in es en; do
    if [ "$dgr_lang" = es ]; then
        dgr_already='Tu usuario ya pertenece al grupo docker.'
        dgr_adding='Añadiendo tu usuario al grupo docker (se pedirá contraseña de administrador)...'
        dgr_done='Docker restaurado.'
    else
        dgr_already='Your user is already a member of the docker group.'
        dgr_adding='Adding your user to the docker group (you will be prompted for the administrator password)...'
        dgr_done='Docker restored.'
    fi
    for dgr_g in "${dgr_members[@]}"; do   # members: nothing to add, no administrator call
        dgr_run restore "$dgr_lang" "$dgr_g"
        [ "$dgr_rc" -eq 0 ] || fail "docker group restore ($dgr_lang, \"$dgr_g\"): a member failed (rc $dgr_rc, out: $dgr_out)"
        grep -Fqx -- "$dgr_already" <<<"$dgr_out" || fail "docker group restore ($dgr_lang, \"$dgr_g\"): no 'already a member' notice (out: $dgr_out)"
        ! grep -Fqx -- "$dgr_adding" <<<"$dgr_out" || fail "docker group restore ($dgr_lang, \"$dgr_g\"): tried to add a member"
        [ -z "$dgr_calls" ] || fail "docker group restore ($dgr_lang, \"$dgr_g\"): a member triggered an administrator call ($dgr_calls)"
    done
    for dgr_g in "${dgr_others[@]}"; do   # not members (docker-users is not docker): added once
        dgr_run restore "$dgr_lang" "$dgr_g"
        [ "$dgr_rc" -eq 0 ] || fail "docker group restore ($dgr_lang, \"$dgr_g\"): failed (rc $dgr_rc, out: $dgr_out)"
        ! grep -Fqx -- "$dgr_already" <<<"$dgr_out" || fail "docker group restore ($dgr_lang, \"$dgr_g\"): a non-member counted as a member"
        grep -Fqx -- "$dgr_adding" <<<"$dgr_out" || fail "docker group restore ($dgr_lang, \"$dgr_g\"): the user was not added (out: $dgr_out)"
        [ "$dgr_calls" = 'usermod -aG docker testuser' ] || fail "docker group restore ($dgr_lang, \"$dgr_g\"): usermod was not called once as expected (calls: $dgr_calls)"
        grep -Fqx -- "$dgr_done" <<<"$dgr_out" || fail "docker group restore ($dgr_lang, \"$dgr_g\"): not announced as restored (out: $dgr_out)"
    done
done
for dgr_g in "${dgr_members[@]}"; do   # save: only a real membership is stored
    dgr_run save es "$dgr_g"
    [ "$dgr_rc" -eq 0 ] || fail "docker group save (\"$dgr_g\"): failed (rc $dgr_rc, out: $dgr_out)"
    [ "$dgr_marker" -eq 1 ] || fail "docker group save (\"$dgr_g\"): the membership was not saved"
done
for dgr_g in "${dgr_others[@]}"; do
    dgr_run save es "$dgr_g"
    [ "$dgr_rc" -eq 0 ] || fail "docker group save (\"$dgr_g\"): failed (rc $dgr_rc, out: $dgr_out)"
    [ "$dgr_marker" -eq 0 ] || fail "docker group save (\"$dgr_g\"): stored a membership that does not exist"
done
pass "docker group: membership is an exact name match (docker-users is not docker), on save and restore (es/en)"

# Docker daemon: the privileged script must not follow a symbolic link in the
# copy. A copy from someone else could point "daemon.json" at a file only root
# can read (/etc/shadow, a Wi-Fi connection...) and root would publish its
# content in /etc/docker with the permissions of the existing daemon.json.
DSY_BACKUP="$TMP/docker-symlink-backup"; DSY_SECRET="$TMP/docker-symlink-secret.json"
mkdir -p "$DSY_BACKUP/docker"
printf '{"secret":true}\n' > "$DSY_SECRET"
ln -s "$DSY_SECRET" "$DSY_BACKUP/docker/daemon.json"
for dsy_lang in es en; do
    if [ "$dsy_lang" = es ]; then
        dsy_unsafe='Aviso: «daemon.json» de la copia no es un archivo normal (por ejemplo, un enlace simbólico); no se restaura.'
        dsy_denied='Aviso: no se pudo restaurar /etc/docker/daemon.json (permisos denegados o cancelado).'
        dsy_partial='Aviso: Docker se restauró parcialmente; revisa los avisos anteriores.'
        dsy_done='Docker restaurado.'
    else
        dsy_unsafe='Warning: “daemon.json” in the backup is not a regular file (for example, a symbolic link); it is not restored.'
        dsy_denied='Warning: /etc/docker/daemon.json could not be restored (permission denied or cancelled).'
        dsy_partial='Warning: Docker was only partially restored; review the previous warnings.'
        dsy_done='Docker restored.'
    fi
    for dsy_dest in existing fresh; do   # refused before touching anything, also when /etc/docker does not exist yet
        dkr_run "$dsy_lang" 0 ok "" "$DSY_BACKUP" "$dsy_dest"
        [ "$dkr_rc" -ne 0 ] || fail "docker symlink ($dsy_lang, $dsy_dest): a link as daemon.json was restored with rc 0"
        grep -Fqx -- "$dsy_unsafe" <<<"$dkr_out" || fail "docker symlink ($dsy_lang, $dsy_dest): no unsafe-file warning (out: $dkr_out)"
        grep -Fqx -- "$dsy_partial" <<<"$dkr_out" || fail "docker symlink ($dsy_lang, $dsy_dest): no partial notice (out: $dkr_out)"
        ! grep -Fqx -- "$dsy_denied" <<<"$dkr_out" || fail "docker symlink ($dsy_lang, $dsy_dest): blamed permissions for an unsafe file"
        ! grep -Fqx -- "$dsy_done" <<<"$dkr_out" || fail "docker symlink ($dsy_lang, $dsy_dest): announced \"restored\""
        [ ! -s "$DKR_LOG" ] || fail "docker symlink ($dsy_lang, $dsy_dest): systemctl ran although nothing was published"
        ! grep -rqF 'secret' "$DKR_TARGET" 2>/dev/null || fail "docker symlink ($dsy_lang, $dsy_dest): the content behind the link reached the destination"
        if [ "$dsy_dest" = fresh ]; then
            [ ! -e "$DKR_TARGET" ] || fail "docker symlink ($dsy_lang): the refused restore created the destination folder"
        else
            grep -qx '{"old":true}' "$DKR_TARGET/daemon.json" || fail "docker symlink ($dsy_lang): the previous daemon.json was replaced"
            find "$DKR_TARGET" -name '.*.mstmp.*' -print -quit | grep -q . && fail "docker symlink ($dsy_lang): left an atomic temporary"
        fi
    done
    # Control: a regular file in the same place is restored.
    dkr_run "$dsy_lang" 0 ok
    [ "$dkr_rc" -eq 0 ] || fail "docker symlink ($dsy_lang): a regular daemon.json failed (rc $dkr_rc, out: $dkr_out)"
    grep -Fqx -- "$dsy_done" <<<"$dkr_out" || fail "docker symlink ($dsy_lang): a regular daemon.json was not announced as restored (out: $dkr_out)"
    ! grep -Fqx -- "$dsy_unsafe" <<<"$dkr_out" || fail "docker symlink ($dsy_lang): a regular daemon.json was refused as unsafe"
    grep -qx '{"new":true}' "$DKR_TARGET/daemon.json" || fail "docker symlink ($dsy_lang): a regular daemon.json was not published"
done
pass "docker restore: a symbolic link as daemon.json in the copy is refused, not followed (es/en)"

# VS Code: extensions that fail to install, or no 'code' to install them with,
# leave the module partial. Through run_restore_module (what do_restore uses)
# that must be a failure with the partial notice, never "VS Code restored" with
# rc 0. The rest of the module (settings.json) is still applied. The stub 'code'
# comes first in PATH; the "absent" PATH hides code and code-insiders, so a host
# with VS Code installed cannot install real extensions.
VSC_BACKUP="$TMP/vscode-backup"; VSC_EMPTY_BACKUP="$TMP/vscode-empty-backup"; VSC_NOLIST_BACKUP="$TMP/vscode-nolist-backup"
mkdir -p "$VSC_BACKUP/vscode/User" "$VSC_EMPTY_BACKUP/vscode/User" "$VSC_NOLIST_BACKUP/vscode/User"
for d in "$VSC_BACKUP" "$VSC_EMPTY_BACKUP" "$VSC_NOLIST_BACKUP"; do
    printf 'code\n' > "$d/vscode/variant"; printf '{"saved":true}\n' > "$d/vscode/User/settings.json"
done
printf 'ms-python.python\nrust-lang.rust-analyzer\n' > "$VSC_BACKUP/vscode/extensions.list"
: > "$VSC_EMPTY_BACKUP/vscode/extensions.list"
VSC_FAIL_BIN="$TMP/vscode-fail-bin"; VSC_OK_BIN="$TMP/vscode-ok-bin"; VSC_NONE_BIN="$TMP/vscode-none-bin"
mkdir -p "$VSC_FAIL_BIN" "$VSC_OK_BIN" "$VSC_NONE_BIN"
cat > "$VSC_FAIL_BIN/code" <<'CODEFAIL'
#!/bin/sh
printf '%s\n' "$*" >> "$VSC_LOG"
echo "code: simulated failure" >&2
exit 7
CODEFAIL
cat > "$VSC_OK_BIN/code" <<'CODEOK'
#!/bin/sh
printf '%s\n' "$*" >> "$VSC_LOG"
exit 0
CODEOK
chmod +x "$VSC_FAIL_BIN/code" "$VSC_OK_BIN/code"
find "$MOCK" /usr/bin /bin -mindepth 1 -maxdepth 1 ! -type d ! -name code ! -name code-insiders \
    -exec ln -s -t "$VSC_NONE_BIN" -- {} + 2>/dev/null || true
[ ! -e "$VSC_NONE_BIN/code" ] && [ ! -e "$VSC_NONE_BIN/code-insiders" ] || fail "vscode fixture: the 'absent' PATH still has code"
VSC_LOG="$TMP/vscode-code.log"; VSC_HOME="$TMP/vscode-home"
vsc_run() {   # vsc_run LANG PATH BACKUP -> vsc_rc, vsc_out (log lines + stderr); fresh HOME, empty code log
    # VSC_BLOCK=NAME puts a folder where User/NAME would go (a copy onto it fails, even as root).
    # VSC_DIRECT=1 calls restore_vscode itself, outside run_restore_module (no failure signal).
    rm -rf "$VSC_HOME"; mkdir -p "$VSC_HOME/.config"; : > "$VSC_LOG"
    [ -z "${VSC_BLOCK:-}" ] || mkdir -p "$VSC_HOME/.config/Code/User/$VSC_BLOCK"
    vsc_out=$(HOME="$VSC_HOME" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
        PATH="$2" VSC_LOG="$VSC_LOG" VSC_DIRECT="${VSC_DIRECT:-}" bash -c '
source "$1"; APP_LANG="$2"
log_msg() { printf "%s\n" "$1"; }
if [ -n "$VSC_DIRECT" ]; then restore_vscode "$3"; else run_restore_module vscode "$3"; fi
' _ "$SCRIPT" "$1" "$3" 2>&1)
    vsc_rc=$?
}
VSC_EXT_CALL='--install-extension ms-python.python --install-extension rust-lang.rust-analyzer --force'
for vsc_lang in es en; do
    if [ "$vsc_lang" = es ]; then
        vsc_partial='Aviso: VS Code se restauró parcialmente; revisa los avisos anteriores.'
        vsc_done='VS Code restaurado. Si estaba abierto, reinícialo para que cargue los cambios.'
        vsc_cause_fail='Aviso: alguna extensión no se pudo instalar (revisa el detalle anterior); puede haberse retirado del marketplace o cambiado de identificador.'
        vsc_cause_none="Aviso: VS Code no está instalado (o 'code' no está en el PATH); instala VS Code y vuelve a restaurar este módulo para recuperar las extensiones."
    else
        vsc_partial='Warning: VS Code was only partially restored; review the previous warnings.'
        vsc_done='VS Code restored. If it was open, restart it to load the changes.'
        vsc_cause_fail='Warning: an extension could not be installed (see the previous details); it may have been removed from the marketplace or its identifier may have changed.'
        vsc_cause_none="Warning: VS Code is not installed (or 'code' is not in PATH); install VS Code and restore this module again to recover the extensions."
    fi
    # Partial: code fails / code absent, with extensions saved.
    for vsc_case in fail none; do
        if [ "$vsc_case" = fail ]; then vsc_path="$VSC_FAIL_BIN:$MOCK:/usr/bin:/bin"; vsc_cause=$vsc_cause_fail
        else vsc_path="$VSC_NONE_BIN"; vsc_cause=$vsc_cause_none; fi
        vsc_run "$vsc_lang" "$vsc_path" "$VSC_BACKUP"
        [ "$vsc_rc" -ne 0 ] || fail "vscode restore ($vsc_lang, $vsc_case): partial restore was reported as success (rc 0)"
        grep -Fqx -- "$vsc_partial" <<<"$vsc_out" || fail "vscode restore ($vsc_lang, $vsc_case): no partial notice (out: $vsc_out)"
        grep -Fqx -- "$vsc_cause" <<<"$vsc_out" || fail "vscode restore ($vsc_lang, $vsc_case): the cause warning is gone (out: $vsc_out)"
        ! grep -Fqx -- "$vsc_done" <<<"$vsc_out" || fail "vscode restore ($vsc_lang, $vsc_case): announced \"restored\" after a partial restore"
        grep -qx '{"saved":true}' "$VSC_HOME/.config/Code/User/settings.json" 2>/dev/null || fail "vscode restore ($vsc_lang, $vsc_case): settings.json was not applied"
        if [ "$vsc_case" = fail ]; then
            [ "$(cat "$VSC_LOG")" = "$VSC_EXT_CALL" ] || fail "vscode restore ($vsc_lang): code was not called once with both extensions (log: $(cat "$VSC_LOG"))"
        else
            [ ! -s "$VSC_LOG" ] || fail "vscode restore ($vsc_lang): a code stub ran in the 'absent' case"
        fi
    done
    # Control: code works.
    vsc_run "$vsc_lang" "$VSC_OK_BIN:$MOCK:/usr/bin:/bin" "$VSC_BACKUP"
    [ "$vsc_rc" -eq 0 ] || fail "vscode restore ($vsc_lang): a correct restore failed (rc $vsc_rc, out: $vsc_out)"
    grep -Fqx -- "$vsc_done" <<<"$vsc_out" || fail "vscode restore ($vsc_lang): the correct restore did not announce it (out: $vsc_out)"
    ! grep -Fqx -- "$vsc_partial" <<<"$vsc_out" || fail "vscode restore ($vsc_lang): the correct restore showed the partial notice"
    [ "$(cat "$VSC_LOG")" = "$VSC_EXT_CALL" ] || fail "vscode restore ($vsc_lang): control did not install both extensions (log: $(cat "$VSC_LOG"))"
    # Nothing to install (empty list, no list): neither a missing nor a failing code matters.
    for vsc_bk in "$VSC_EMPTY_BACKUP" "$VSC_NOLIST_BACKUP"; do
        for vsc_path in "$VSC_NONE_BIN" "$VSC_FAIL_BIN:$MOCK:/usr/bin:/bin"; do
            vsc_run "$vsc_lang" "$vsc_path" "$vsc_bk"
            [ "$vsc_rc" -eq 0 ] || fail "vscode restore ($vsc_lang): no extensions saved but rc $vsc_rc (out: $vsc_out)"
            grep -Fqx -- "$vsc_done" <<<"$vsc_out" || fail "vscode restore ($vsc_lang): no extensions saved, but not announced as restored (out: $vsc_out)"
            ! grep -Fqx -- "$vsc_partial" <<<"$vsc_out" || fail "vscode restore ($vsc_lang): no extensions saved, but the partial notice appeared"
            [ ! -s "$VSC_LOG" ] || fail "vscode restore ($vsc_lang): code ran with no extensions to install"
        done
    done
done
pass "vscode restore: failed extension install or missing 'code' is a partial restore (es/en)"

# VS Code, second source of a partial restore: settings.json, keybindings.json, snippets and
# profiles go through helpers that flag their own failure (RESTORE_MODULE_FAILED) without
# touching the module's flag, so a failed one closed with "VS Code restored" under its warning
# while run_restore_module reported rc 1. A folder where a destination file goes fails the copy
# even as root; a damaged .tar.gz fails unpack_dir. The rest of the module is still applied,
# the module's own partial notice appears exactly once and the generic one of
# restore_clean_end never does.
VSH_BASE="$TMP/vscode-helper-backup"
mkdir -p "$VSH_BASE/vscode/User" "$TMP/vsh-src/snippets" "$TMP/vsh-src/profiles/work"
cp "$VSC_BACKUP/vscode/variant" "$VSC_BACKUP/vscode/extensions.list" "$VSH_BASE/vscode/"
printf '{"saved":true}\n' > "$VSH_BASE/vscode/User/settings.json"
printf '{"keys":true}\n' > "$VSH_BASE/vscode/User/keybindings.json"
printf '{}\n' > "$TMP/vsh-src/snippets/a.code-snippets"
printf '{"profile":true}\n' > "$TMP/vsh-src/profiles/work/settings.json"
tar -czf "$VSH_BASE/vscode/snippets.tar.gz" -C "$TMP/vsh-src" snippets || fail "vscode helper fixture: tar snippets"
tar -czf "$VSH_BASE/vscode/profiles.tar.gz" -C "$TMP/vsh-src" profiles || fail "vscode helper fixture: tar profiles"
VSH_USER="$VSC_HOME/.config/Code/User"
vsh_lq=$(printf '\342\200\234'); vsh_rq=$(printf '\342\200\235')   # the curly quotes of the EN catalog, byte by byte
vsh_applied() {   # vsh_applied PART: PART of the module is in place (checked right after vsc_run)
    case "$1" in
        settings)    grep -qx '{"saved":true}' "$VSH_USER/settings.json" 2>/dev/null ;;
        keybindings) grep -qx '{"keys":true}' "$VSH_USER/keybindings.json" 2>/dev/null ;;
        snippets)    [ -f "$VSH_USER/snippets/a.code-snippets" ] ;;
        profiles)    grep -qx '{"profile":true}' "$VSH_USER/profiles/work/settings.json" 2>/dev/null ;;
    esac
}
for vsh_lang in es en; do
    if [ "$vsh_lang" = es ]; then
        vsh_partial='Aviso: VS Code se restauró parcialmente; revisa los avisos anteriores.'
        vsh_done='VS Code restaurado. Si estaba abierto, reinícialo para que cargue los cambios.'
        vsh_generic='Aviso: este módulo se restauró solo en parte; revisa los avisos anteriores.'
    else
        vsh_partial='Warning: VS Code was only partially restored; review the previous warnings.'
        vsh_done='VS Code restored. If it was open, restart it to load the changes.'
        vsh_generic='Warning: this module was only partly restored; see the warnings above.'
    fi
    # Control: nothing fails.
    VSC_BLOCK=""
    vsc_run "$vsh_lang" "$VSC_OK_BIN:$MOCK:/usr/bin:/bin" "$VSH_BASE"
    [ "$vsc_rc" -eq 0 ] || fail "vscode helpers ($vsh_lang): a correct restore failed (rc $vsc_rc, out: $vsc_out)"
    [ "$(grep -Fxc -- "$vsh_done" <<<"$vsc_out")" -eq 1 ] || fail "vscode helpers ($vsh_lang): the correct restore was not announced once (out: $vsc_out)"
    ! grep -Fqx -e "$vsh_partial" -e "$vsh_generic" <<<"$vsc_out" || fail "vscode helpers ($vsh_lang): the correct restore showed a partial notice (out: $vsc_out)"
    for vsh_part in settings keybindings snippets profiles; do
        vsh_applied "$vsh_part" || fail "vscode helpers ($vsh_lang): the control did not apply $vsh_part"
    done
    # One part fails: partial, announced once, the other three still applied.
    for vsh_case in settings keybindings snippets profiles; do
        vsh_bk="$TMP/vscode-helper-$vsh_case"; rm -rf "$vsh_bk"; cp -a "$VSH_BASE" "$vsh_bk"
        VSC_BLOCK=""
        case "$vsh_case" in
            settings|keybindings) VSC_BLOCK="$vsh_case.json" ;;
            snippets|profiles)    printf 'not a tar archive\n' > "$vsh_bk/vscode/$vsh_case.tar.gz" ;;
        esac
        vsc_run "$vsh_lang" "$VSC_OK_BIN:$MOCK:/usr/bin:/bin" "$vsh_bk"
        [ "$vsc_rc" -ne 0 ] || fail "vscode helpers ($vsh_lang, $vsh_case): a failed part was reported as success (rc 0)"
        [ "$(grep -Fxc -- "$vsh_partial" <<<"$vsc_out")" -eq 1 ] || fail "vscode helpers ($vsh_lang, $vsh_case): the partial notice is not there exactly once (out: $vsc_out)"
        ! grep -Fqx -- "$vsh_done" <<<"$vsc_out" || fail "vscode helpers ($vsh_lang, $vsh_case): announced \"restored\" after a failed part (out: $vsc_out)"
        ! grep -Fqx -- "$vsh_generic" <<<"$vsc_out" || fail "vscode helpers ($vsh_lang, $vsh_case): the generic partial notice appeared next to VS Code's own (out: $vsc_out)"
        for vsh_part in settings keybindings snippets profiles; do
            if [ "$vsh_part" = "$vsh_case" ]; then
                ! vsh_applied "$vsh_part" || fail "vscode helpers ($vsh_lang, $vsh_case): the blocked part was applied"
            else
                vsh_applied "$vsh_part" || fail "vscode helpers ($vsh_lang, $vsh_case): $vsh_part was not applied after $vsh_case failed"
            fi
        done
        case "$vsh_case" in snippets|profiles)
            if [ "$vsh_lang" = es ]; then
                vsh_damaged="Aviso: el archivo «$vsh_bk/vscode/$vsh_case.tar.gz» está dañado, incompleto o no es seguro; se omite sin tocar tu configuración actual."
            else
                vsh_damaged="Warning: the file ${vsh_lq}$vsh_bk/vscode/$vsh_case.tar.gz${vsh_rq} is damaged, incomplete or unsafe; skipped without touching your current configuration."
            fi
            grep -Fqx -- "$vsh_damaged" <<<"$vsc_out" || fail "vscode helpers ($vsh_lang, $vsh_case): the warning that names the damaged archive is gone (out: $vsc_out)" ;;
        esac
        [ "$(cat "$VSC_LOG")" = "$VSC_EXT_CALL" ] || fail "vscode helpers ($vsh_lang, $vsh_case): code was not called once with both extensions (log: $(cat "$VSC_LOG"))"
        ! find "$VSH_USER" -name '*mstmp*' | grep -q . || fail "vscode helpers ($vsh_lang, $vsh_case): a temporary file was left behind"
    done
    # Outside a restore there is no failure signal, so nothing changes there (control).
    VSC_BLOCK="settings.json"; VSC_DIRECT=1
    vsc_run "$vsh_lang" "$VSC_OK_BIN:$MOCK:/usr/bin:/bin" "$VSH_BASE"
    VSC_DIRECT=""
    [ "$vsc_rc" -eq 0 ] || fail "vscode helpers ($vsh_lang, outside a restore): rc $vsc_rc (out: $vsc_out)"
    [ "$(grep -Fxc -- "$vsh_done" <<<"$vsc_out")" -eq 1 ] || fail "vscode helpers ($vsh_lang, outside a restore): not announced once (out: $vsc_out)"
    ! grep -Fqx -e "$vsh_partial" -e "$vsh_generic" <<<"$vsc_out" || fail "vscode helpers ($vsh_lang, outside a restore): a partial notice appeared (out: $vsc_out)"
    # Failed extensions and a failed part together: still one notice.
    VSC_BLOCK="settings.json"
    vsc_run "$vsh_lang" "$VSC_FAIL_BIN:$MOCK:/usr/bin:/bin" "$VSH_BASE"
    [ "$vsc_rc" -ne 0 ] || fail "vscode helpers ($vsh_lang, both): rc 0"
    [ "$(grep -Fxc -- "$vsh_partial" <<<"$vsc_out")" -eq 1 ] || fail "vscode helpers ($vsh_lang, both): the partial notice is not there exactly once (out: $vsc_out)"
    ! grep -Fqx -e "$vsh_done" -e "$vsh_generic" <<<"$vsc_out" || fail "vscode helpers ($vsh_lang, both): announced \"restored\" or the generic notice (out: $vsc_out)"
done
VSC_BLOCK=""; VSC_DIRECT=""
pass "vscode restore: a failed settings, keybindings, snippets or profiles step is a partial restore, announced once (es/en)"

# Browser, mail and office restores skip their module while the application is
# open. A skipped module is a failed one: rc 1 and listed in "failed" by
# do_restore, never rc 0 (it was counted as restored and the final dialog said
# "Configuration restored."). The existing profile must stay untouched.
# pgrep is a stub that only knows "-x NAME" (0 if NAME is in OPN_RUNNING, any
# other call is error 2), or it is absent from PATH (assumed open).
OPN_MODS=(firefox librewolf thunderbird libreoffice onlyoffice)
declare -A OPN_PROCS=([firefox]="firefox firefox-esr" [librewolf]=librewolf [thunderbird]=thunderbird [libreoffice]=soffice.bin [onlyoffice]=DesktopEditors)
declare -A OPN_FILES=([firefox]=.mozilla/firefox/p1/bookmarks [librewolf]=.librewolf/p1/bookmarks [thunderbird]=.thunderbird/p1/accounts \
    [libreoffice]=.config/libreoffice/config [onlyoffice]=".config/onlyoffice/config .local/share/onlyoffice/plugin")
OPN_ALL_PROCS="firefox firefox-esr librewolf thunderbird soffice.bin DesktopEditors"
OPN_SEED="$TMP/opn-seed"; OPN_EXIST="$TMP/opn-existing"; OPN_HOME="$TMP/opn-home"; OPN_BACKUP="$TMP/opn-backup"
OPN_PGLOG="$TMP/opn-pgrep.log"; OPN_STUB_BIN="$TMP/opn-stub-bin"; OPN_NONE_BIN="$TMP/opn-none-bin"
mkdir -p "$OPN_STUB_BIN" "$OPN_NONE_BIN" "$OPN_BACKUP"
for opn_mod in "${OPN_MODS[@]}"; do
    for opn_f in ${OPN_FILES[$opn_mod]}; do
        mkdir -p "$OPN_SEED/${opn_f%/*}" "$OPN_EXIST/${opn_f%/*}"
        printf 'saved-%s\n' "$opn_f" > "$OPN_SEED/$opn_f"
        printf 'local-%s\n' "$opn_f" > "$OPN_EXIST/$opn_f"
        printf 'extra\n' > "$OPN_EXIST/${opn_f%/*}/extra-local"   # only in the existing profile
    done
done
HOME="$OPN_SEED" XDG_CONFIG_HOME="$TMP/opn-cfg-seed" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 PATH="$MOCK:/usr/bin:/bin" \
    bash -c 'source "$1"; set_language en; for m in "${@:3}"; do "save_$m" "$2" || exit 1; done' \
    _ "$SCRIPT" "$OPN_BACKUP" "${OPN_MODS[@]}" >/dev/null 2>&1 || fail "open-app restore: could not build the fixture backup"
cat > "$OPN_STUB_BIN/pgrep" <<'PGREP'
#!/bin/sh
printf '%s\n' "$*" >> "$OPN_PGLOG"
[ "${1:-}" = "-x" ] && [ $# -eq 2 ] || exit 2
for n in $OPN_RUNNING; do [ "$n" = "$2" ] && exit 0; done
exit 1
PGREP
chmod +x "$OPN_STUB_BIN/pgrep"
find "$MOCK" /usr/bin /bin -mindepth 1 -maxdepth 1 ! -type d ! -name pgrep -exec ln -s -t "$OPN_NONE_BIN" -- {} + 2>/dev/null || true
[ ! -e "$OPN_NONE_BIN/pgrep" ] || fail "open-app fixture: the 'no pgrep' PATH still has pgrep"
opn_list() { (cd "$1" && find . -mindepth 1 -printf '%y %P\n' | LC_ALL=C sort); }
opn_tree() { opn_list "$1"; (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum); }
opn_run() {   # opn_run LANG MODULE "RUNNING NAMES" [nopgrep] -> opn_rc, opn_out (log lines + stderr), tree before/after
    local path="$OPN_STUB_BIN:$MOCK:/usr/bin:/bin"
    [ "${4:-}" != nopgrep ] || path="$OPN_NONE_BIN"
    rm -rf "$OPN_HOME"; cp -a "$OPN_EXIST" "$OPN_HOME"; : > "$OPN_PGLOG"
    opn_before=$(opn_tree "$OPN_HOME"); opn_before_list=$(opn_list "$OPN_HOME")
    opn_out=$(HOME="$OPN_HOME" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
        PATH="$path" OPN_RUNNING="$3" OPN_PGLOG="$OPN_PGLOG" bash -c '
source "$1"; APP_LANG="$2"
log_msg() { printf "%s\n" "$1"; }
run_restore_module "$3" "$4"
' _ "$SCRIPT" "$1" "$2" "$OPN_BACKUP" 2>&1)
    opn_rc=$?
    opn_after=$(opn_tree "$OPN_HOME"); opn_after_list=$(opn_list "$OPN_HOME")
}
declare -A OPN_WARN OPN_DONE
OPN_WARN[es:firefox]='Aviso: Firefox está abierto; ciérralo y vuelve a restaurar para evitar corromper el perfil. Este módulo se ha omitido.'
OPN_WARN[es:librewolf]='Aviso: LibreWolf está abierto; ciérralo y vuelve a restaurar para evitar corromper el perfil. Este módulo se ha omitido.'
OPN_WARN[es:thunderbird]='Aviso: Thunderbird está abierto; ciérralo y vuelve a restaurar para evitar corromper el perfil. Este módulo se ha omitido.'
OPN_WARN[es:libreoffice]='Aviso: LibreOffice está abierto (o el inicio rápido activo); ciérralo del todo y vuelve a restaurar. Este módulo se ha omitido.'
OPN_WARN[es:onlyoffice]='Aviso: ONLYOFFICE Desktop Editors está abierto; ciérralo y vuelve a restaurar. Este módulo se ha omitido.'
OPN_WARN[en:firefox]='Warning: Firefox is open; close it and restore again to avoid corrupting the profile. This module was skipped.'
OPN_WARN[en:librewolf]='Warning: LibreWolf is open; close it and restore again to avoid corrupting the profile. This module was skipped.'
OPN_WARN[en:thunderbird]='Warning: Thunderbird is open; close it and restore again to avoid corrupting the profile. This module was skipped.'
OPN_WARN[en:libreoffice]='Warning: LibreOffice is open (or quickstarter is active); close it completely and restore again. This module was skipped.'
OPN_WARN[en:onlyoffice]='Warning: ONLYOFFICE Desktop Editors is open; close it and restore again. This module was skipped.'
OPN_DONE[es:firefox]='Firefox restaurado. Ábrelo para comprobar que carga el perfil correctamente.'
OPN_DONE[es:librewolf]='LibreWolf restaurado. Ábrelo para comprobar que carga el perfil correctamente.'
OPN_DONE[es:thunderbird]='Thunderbird restaurado. Ábrelo para comprobar que carga el perfil correctamente.'
OPN_DONE[es:libreoffice]='LibreOffice restaurado.'
OPN_DONE[es:onlyoffice]='ONLYOFFICE restaurado.'
OPN_DONE[en:firefox]='Firefox restored. Open it to check that the profile loads correctly.'
OPN_DONE[en:librewolf]='LibreWolf restored. Open it to check that the profile loads correctly.'
OPN_DONE[en:thunderbird]='Thunderbird restored. Open it to check that the profile loads correctly.'
OPN_DONE[en:libreoffice]='LibreOffice restored.'
OPN_DONE[en:onlyoffice]='ONLYOFFICE restored.'
opn_blocked() {   # opn_blocked LABEL WARNING: the module failed, said so, and touched nothing
    [ "$opn_rc" -eq 1 ] || fail "open-app restore ($1): rc $opn_rc, expected 1 (out: $opn_out)"
    [ "$opn_out" = "$2" ] || fail "open-app restore ($1): output is not exactly the warning (out: $opn_out)"
    [ "$opn_after" = "$opn_before" ] || fail "open-app restore ($1): the profile tree changed"
}
for opn_lang in es en; do
    for opn_mod in "${OPN_MODS[@]}"; do
        opn_warn=${OPN_WARN[$opn_lang:$opn_mod]}; opn_done=${OPN_DONE[$opn_lang:$opn_mod]}
        # Every process name that blocks the module, then no pgrep at all.
        for opn_name in ${OPN_PROCS[$opn_mod]}; do
            opn_run "$opn_lang" "$opn_mod" "$opn_name"
            opn_blocked "$opn_lang, $opn_mod, $opn_name open" "$opn_warn"
            grep -Fqx -- "-x $opn_name" "$OPN_PGLOG" || fail "open-app restore ($opn_lang, $opn_mod): pgrep was not asked about -x $opn_name"
            ! grep -qv '^-x [^ ]*$' "$OPN_PGLOG" || fail "open-app restore ($opn_lang, $opn_mod): pgrep was called other than as -x NAME ($(tr '\n' '|' < "$OPN_PGLOG"))"
        done
        opn_run "$opn_lang" "$opn_mod" "" nopgrep
        opn_blocked "$opn_lang, $opn_mod, no pgrep" "$opn_warn"
        # Control: every other application is open, this one is not.
        opn_others=""
        for opn_name in $OPN_ALL_PROCS; do
            case " ${OPN_PROCS[$opn_mod]} " in *" $opn_name "*) ;; *) opn_others+="$opn_name " ;; esac
        done
        opn_run "$opn_lang" "$opn_mod" "$opn_others"
        [ "$opn_rc" -eq 0 ] || fail "open-app restore ($opn_lang, $opn_mod): a closed application failed the restore (rc $opn_rc, out: $opn_out)"
        grep -Fqx -- "$opn_done" <<<"$opn_out" || fail "open-app restore ($opn_lang, $opn_mod): the restore was not announced (out: $opn_out)"
        ! grep -Fqx -- "$opn_warn" <<<"$opn_out" || fail "open-app restore ($opn_lang, $opn_mod): a closed application got the open warning"
        [ "$opn_after_list" = "$opn_before_list" ] || fail "open-app restore ($opn_lang, $opn_mod): files appeared or disappeared"
        for opn_f in ${OPN_FILES[$opn_mod]}; do
            cmp -s "$OPN_HOME/$opn_f" "$OPN_SEED/$opn_f" || fail "open-app restore ($opn_lang, $opn_mod): $opn_f is not the saved one"
            [ "$(cat "$OPN_HOME/${opn_f%/*}/extra-local")" = extra ] || fail "open-app restore ($opn_lang, $opn_mod): the extra file in ${opn_f%/*} was lost"
        done
        for opn_other in "${OPN_MODS[@]}"; do
            [ "$opn_other" != "$opn_mod" ] || continue
            for opn_f in ${OPN_FILES[$opn_other]}; do
                [ "$(cat "$OPN_HOME/$opn_f")" = "local-$opn_f" ] || fail "open-app restore ($opn_lang, $opn_mod): it touched $opn_f of $opn_other"
            done
        done
    done
done
# End to end, real script with a stub zenity: Firefox open ends in the warning
# that lists it under "failed" (not "Configuration restored."); closed ends in
# the success notice and the profile is restored.
OPN_E2E="$TMP/opn-e2e-backups"; mkdir -p "$OPN_E2E/copy"
cp -a "$OPN_BACKUP/firefox" "$OPN_E2E/copy/firefox"
printf 'NAME=%q\nDATE=%q\nMODULES=%q\n' "Open app" '2026-10-19 10:00:00' firefox > "$OPN_E2E/copy/manifest.conf"
for opn_lang in es en; do
    mkdir -p "$TMP/opn-e2e-cfg-$opn_lang/mint-setup"; printf '%s\n' "$opn_lang" > "$TMP/opn-e2e-cfg-$opn_lang/mint-setup/language"
    if [ "$opn_lang" = es ]; then
        opn_failed='La restauración ha terminado con errores.'; opn_failed_list='fallaron: Firefox.'; opn_ok='Configuración restaurada.'
    else
        opn_failed='The restore finished with errors.'; opn_failed_list='these failed: Firefox.'; opn_ok='Configuration restored.'
    fi
    for opn_state in open closed; do
        if [ "$opn_state" = open ]; then opn_running=firefox; else opn_running=""; fi
        rm -rf "$OPN_HOME"; cp -a "$OPN_EXIST" "$OPN_HOME"; opn_before=$(opn_tree "$OPN_HOME")
        opn_cap="$TMP/opn-e2e-$opn_lang-$opn_state"; : > "$OPN_PGLOG"
        SEQ=$(printf '2\n%s\nfirefox\n5\n' "$OPN_E2E/copy")
        HOME="$OPN_HOME" XDG_CONFIG_HOME="$TMP/opn-e2e-cfg-$opn_lang" MINT_SETUP_BACKUPS_DIR="$OPN_E2E" \
            PATH="$OPN_STUB_BIN:$MOCK:/usr/bin:/bin" OPN_RUNNING="$opn_running" OPN_PGLOG="$OPN_PGLOG" \
            ZENITY_CAPTURE="$opn_cap" ZENITY_LIST_CHOICES="$SEQ" ZENITY_QUESTION_RC=0 LC_ALL=C.UTF-8 \
            timeout 90 bash "$SCRIPT" >/dev/null 2>"$opn_cap.err" || fail "open-app flow exited non-zero ($opn_lang, $opn_state)"
        [ ! -s "$opn_cap.err" ] || fail "open-app flow printed to stderr ($opn_lang, $opn_state): $(head -c 300 "$opn_cap.err")"
        if [ "$opn_state" = open ]; then
            grep -q '^--warning ' "$opn_cap/calls" || fail "open-app flow ($opn_lang): no --warning dialog (calls: $(tr '\n' '|' < "$opn_cap/calls"))"
            grep -Fq "$opn_failed" "$opn_cap/calls" || fail "open-app flow ($opn_lang): the warning is not the 'finished with errors' one"
            grep -Fq "$opn_failed_list" "$opn_cap/calls" || fail "open-app flow ($opn_lang): Firefox is not listed as failed"
            ! grep -Fq "$opn_ok" "$opn_cap/calls" || fail "open-app flow ($opn_lang): announced \"$opn_ok\" with Firefox open"
            ! grep -q '^--info ' "$opn_cap/calls" || fail "open-app flow ($opn_lang): an info dialog was shown with Firefox open"
            [ "$(opn_tree "$OPN_HOME")" = "$opn_before" ] || fail "open-app flow ($opn_lang): the profile changed with Firefox open"
        else
            grep -q '^--info ' "$opn_cap/calls" || fail "open-app flow ($opn_lang): no success dialog with Firefox closed"
            grep -Fq "$opn_ok" "$opn_cap/calls" || fail "open-app flow ($opn_lang): the success notice is not \"$opn_ok\""
            ! grep -q '^--warning ' "$opn_cap/calls" || fail "open-app flow ($opn_lang): a warning was shown with Firefox closed"
            cmp -s "$OPN_HOME/.mozilla/firefox/p1/bookmarks" "$OPN_SEED/.mozilla/firefox/p1/bookmarks" || fail "open-app flow ($opn_lang): the profile was not restored"
        fi
        grep -Fqx -- '-x firefox' "$OPN_PGLOG" || fail "open-app flow ($opn_lang, $opn_state): pgrep was not asked about -x firefox"
    done
done
pass "restore with the application open (browsers, mail, office): the module fails, the profile stays intact and the restore reports it (es/en)"

# Mozilla profiles (Firefox, LibreWolf, Thunderbird): only the caches and lock
# files at the TOP of each profile are left out. The same names deeper down are
# user data (a Thunderbird mail folder called "crashes" or "lock" is an mbox file
# with that name) and must be saved and come back on restore. Each module is saved
# and restored for real, with the profile root as a folder and as a symbolic link
# (stow, another partition); the extracted archive is compared whole against an
# independent filter (awk) of the seeded tree.
MZX_SKIP="cache2 startupCache shader-cache thumbnails crashes minidumps saved-telemetry-pings lock .parentlock"
MZX_MAIL="cache2 startupCache shader-cache thumbnails crashes minidumps saved-telemetry-pings lock Inbox"
declare -A MZX_ROOT=([firefox]=.mozilla/firefox [librewolf]=.librewolf [thunderbird]=.thunderbird)
MZX_BIN="$TMP/mzx-bin"; mkdir -p "$MZX_BIN"
printf '#!/bin/sh\nexit 1\n' > "$MZX_BIN/pgrep"; chmod +x "$MZX_BIN/pgrep"   # no application is open
mzx_list() { (cd "$1" && find . -mindepth 1 -printf '%y %P\n' | LC_ALL=C sort); }
mzx_seed() {   # mzx_seed ROOT NAME: profile p1 = what is skipped at its top + user data with the same names deeper
    local r="$1" n   # NAME is the root as tar sees it: a deeper folder called like it must not move the match point
    mkdir -p "$r/p1/Mail/Local Folders/crashes.sbd" "$r/p1/storage/crashes" "$r/p1/storage/idb" "$r/p1/storage/$2/x/crashes"
    for n in cache2 startupCache shader-cache thumbnails crashes minidumps saved-telemetry-pings; do
        mkdir -p "$r/p1/$n"; printf 'cache\n' > "$r/p1/$n/entry"
    done
    ln -s 127.0.0.1:+1 "$r/p1/lock"; printf 'lock\n' > "$r/p1/.parentlock"
    printf 'wal\n' > "$r/p1/places.sqlite-wal"; printf 'shm\n' > "$r/p1/places.sqlite-shm"
    printf 'wal\n' > "$r/p1/storage/idb/db.sqlite-wal"; printf 'shm\n' > "$r/p1/storage/idb/db.sqlite-shm"
    printf 'prefs\n' > "$r/p1/prefs.js"; printf 'db\n' > "$r/p1/places.sqlite"
    for n in $MZX_MAIL; do printf 'mail:%s\n' "$n" > "$r/p1/Mail/Local Folders/$n"; done
    printf 'child\n' > "$r/p1/Mail/Local Folders/crashes.sbd/child"; printf 'deep\n' > "$r/p1/storage/crashes/deep"
    printf 'nested\n' > "$r/p1/storage/$2/x/crashes/keep"
}
mzx_expect() {   # mzx_expect LISTING: all of it but the top-of-profile skips and every *.sqlite-wal/-shm
    awk -v names="$MZX_SKIP" '
        BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) skip[a[i]] = 1 }
        { p = substr($0, 3); c = split(p, f, "/") }
        p ~ /\.sqlite-(wal|shm)$/ { next }
        c >= 2 && (f[2] in skip) { next }
        { print }' <<<"$1"
}
for mzx_mod in firefox librewolf thunderbird; do
    mzx_rel="${MZX_ROOT[$mzx_mod]}"; mzx_name="${mzx_rel##*/}"
    for mzx_form in dir link; do
        mzx_tag="$mzx_mod, root as $mzx_form"
        mzx_home="$TMP/mzx-home-$mzx_mod-$mzx_form"; mkdir -p "$(dirname "$mzx_home/$mzx_rel")"
        mzx_src="$mzx_home/$mzx_rel"; [ "$mzx_form" != link ] || mzx_src="$TMP/mzx-target-$mzx_mod"
        mzx_seed "$mzx_src" "$mzx_name"
        [ "$mzx_form" != link ] || ln -s "$mzx_src" "$mzx_home/$mzx_rel"
        mzx_want=$(mzx_expect "$(mzx_list "$mzx_src")")
        # The filter must tell the two kinds apart: user data kept, top-level skips gone.
        for mzx_n in $MZX_MAIL; do
            grep -Fqx -- "f p1/Mail/Local Folders/$mzx_n" <<<"$mzx_want" || fail "mozilla ($mzx_tag): fixture, the mail folder '$mzx_n' is not expected"
        done
        for mzx_n in 'f p1/Mail/Local Folders/crashes.sbd/child' 'f p1/storage/crashes/deep' "f p1/storage/$mzx_name/x/crashes/keep" 'f p1/prefs.js' 'f p1/places.sqlite'; do
            grep -Fqx -- "$mzx_n" <<<"$mzx_want" || fail "mozilla ($mzx_tag): fixture, '$mzx_n' is not expected"
        done
        for mzx_n in $MZX_SKIP; do
            ! grep -Fq -- " p1/$mzx_n" <<<"$mzx_want" || fail "mozilla ($mzx_tag): fixture, the top-level '$mzx_n' is expected"
        done
        ! grep -Fq -e sqlite-wal -e sqlite-shm <<<"$mzx_want" || fail "mozilla ($mzx_tag): fixture, a WAL/SHM file is expected"

        mzx_bk="$TMP/mzx-bk-$mzx_mod-$mzx_form"; mkdir -p "$mzx_bk"
        mzx_out=$(HOME="$mzx_home" XDG_CONFIG_HOME="$CFG" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 PATH="$MZX_BIN:$MOCK:/usr/bin:/bin" \
            bash -c 'source "$1"; APP_LANG=en; run_save_module "$2" "$3"' _ "$SCRIPT" "$mzx_mod" "$mzx_bk" 2>&1) \
            || fail "mozilla ($mzx_tag): the save failed (out: $mzx_out)"
        mzx_arc="$mzx_bk/$mzx_mod/$mzx_mod-profiles.tar.gz"
        [ -f "$mzx_arc" ] || fail "mozilla ($mzx_tag): no archive was written"
        mzx_x="$TMP/mzx-x-$mzx_mod-$mzx_form"; mkdir -p "$mzx_x"
        tar xzf "$mzx_arc" -C "$mzx_x" || fail "mozilla ($mzx_tag): the archive does not extract"
        mzx_got=$(mzx_list "$mzx_x/$mzx_name")
        [ "$mzx_got" = "$mzx_want" ] || fail "mozilla ($mzx_tag): the archive differs from what must be saved (- expected, + saved): $(diff <(printf '%s\n' "$mzx_want") <(printf '%s\n' "$mzx_got") | grep '^[<>]' | head -6 | tr '\n' '|')"

        mzx_rest="$TMP/mzx-rest-$mzx_mod-$mzx_form"; mkdir -p "$mzx_rest"
        mzx_out=$(HOME="$mzx_rest" XDG_CONFIG_HOME="$CFG" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 PATH="$MZX_BIN:$MOCK:/usr/bin:/bin" \
            bash -c 'source "$1"; APP_LANG=en; run_restore_module "$2" "$3"' _ "$SCRIPT" "$mzx_mod" "$mzx_bk" 2>&1) \
            || fail "mozilla ($mzx_tag): the restore failed (out: $mzx_out)"
        [ "$(mzx_list "$mzx_rest/$mzx_rel")" = "$mzx_want" ] || fail "mozilla ($mzx_tag): the restored profile differs from what was saved"
        for mzx_n in $MZX_MAIL; do
            [ "$(cat "$mzx_rest/$mzx_rel/p1/Mail/Local Folders/$mzx_n")" = "mail:$mzx_n" ] || fail "mozilla ($mzx_tag): the mail folder '$mzx_n' did not come back intact"
        done
    done
done
pass "mozilla profiles (Firefox, LibreWolf, Thunderbird): only the top-level caches and locks are left out; same-named user data (mail folders, deeper folders) is saved and restored, with the root as a folder or a symlink"

# A Mozilla profile that cannot be saved is reported by the folder that really
# exists. save_firefox named "$HOME/firefox" (the profile is in
# ~/.mozilla/firefox) while LibreWolf and Thunderbird named their own folder.
# Each module runs for real with a tar that cannot create the archive: the
# notice, the problem list of the final Save summary and the module result must
# name the same existing folder, in both languages, and nothing is published.
MZW_BIN="$TMP/mzw-bin"; mkdir -p "$MZW_BIN"
printf '#!/bin/sh\nexit 1\n' > "$MZW_BIN/pgrep"   # no application is open
# shellcheck disable=SC2016  # the stub's own shell expands $1 and $@, not this one
printf '#!/bin/sh\ncase "$1" in czf) exit 2 ;; esac\nexec /usr/bin/tar "$@"\n' > "$MZW_BIN/tar"
chmod +x "$MZW_BIN/pgrep" "$MZW_BIN/tar"
for mzw_mod in firefox librewolf thunderbird; do
    mzw_rel="${MZX_ROOT[$mzw_mod]}"
    for mzw_lang in es en; do
        mzw_tag="$mzw_mod, $mzw_lang"
        mzw_home="$TMP/mzw-home-$mzw_mod-$mzw_lang"; mkdir -p "$mzw_home/$mzw_rel/p1"
        printf 'prefs\n' > "$mzw_home/$mzw_rel/p1/prefs.js"
        mzw_bk="$TMP/mzw-bk-$mzw_mod-$mzw_lang"; mkdir -p "$mzw_bk"
        mzw_probs="$TMP/mzw-problems-$mzw_mod-$mzw_lang"; : > "$mzw_probs"
        mzw_out=$(HOME="$mzw_home" XDG_CONFIG_HOME="$CFG" SAVE_PROBLEMS_FILE="$mzw_probs" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
            PATH="$MZW_BIN:$MOCK:/usr/bin:/bin" \
            bash -c 'source "$1"; APP_LANG=$2; run_save_module "$3" "$4"; echo "RC:$?"' _ "$SCRIPT" "$mzw_lang" "$mzw_mod" "$mzw_bk" 2>&1)
        if [ "$mzw_lang" = es ]; then
            mzw_want=$(printf 'Aviso: no se pudo guardar «%s» de forma íntegra (¿disco lleno o permisos?); se omite.' "$mzw_home/$mzw_rel")
        else
            mzw_want=$(printf 'Warning: “%s” could not be saved intact (disk full or permissions?); skipped.' "$mzw_home/$mzw_rel")
        fi
        grep -Fqx -- "$mzw_want" <<<"$mzw_out" || fail "mozilla save failure ($mzw_tag): the notice does not name the profile folder '$mzw_home/$mzw_rel' (out: $mzw_out)"
        grep -Fqx 'RC:1' <<<"$mzw_out" || fail "mozilla save failure ($mzw_tag): the module did not fail (out: $mzw_out)"
        [ "$(cat "$mzw_probs")" = "$mzw_home/$mzw_rel" ] || fail "mozilla save failure ($mzw_tag): the problem list is not the profile folder (got: $(cat "$mzw_probs"))"
        [ -d "$(cat "$mzw_probs")" ] || fail "mozilla save failure ($mzw_tag): the folder named in the problem list does not exist"
        [ -z "$(find "$mzw_bk/$mzw_mod" -type f -print -quit)" ] || fail "mozilla save failure ($mzw_tag): a file was left in the copy"
    done
done
pass "mozilla save failure: the notice and the problem list name the profile folder that exists (Firefox, LibreWolf, Thunderbird; es/en)"

# Where save_firefox looks for the profiles (firefox_profiles_root). Firefox 147+
# keeps them in ~/.config/mozilla/firefox on a machine without ~/.mozilla and keeps
# using ~/.mozilla/firefox where that exists; an absolute $XDG_CONFIG_HOME replaces
# ~/.config (empty or relative: ignored). Each case runs save_firefox for real: the
# extracted archive must hold the profile of the expected root (its prefs.js is the
# marker; the root that must lose holds a decoy). Restore always writes to
# ~/.mozilla/firefox, and a failed save names the folder that was really read.
MZP_BIN="$TMP/mzp-bin"; MZP_FAIL="$TMP/mzp-fail"; mkdir -p "$MZP_BIN" "$MZP_FAIL"
printf '#!/bin/sh\nexit 1\n' > "$MZP_BIN/pgrep"   # Firefox is not open
cp "$MZP_BIN/pgrep" "$MZP_FAIL/pgrep"
# shellcheck disable=SC2016  # the stub's own shell expands $1 and $@, not this one
printf '#!/bin/sh\ncase "$1" in czf) exit 2 ;; esac\nexec /usr/bin/tar "$@"\n' > "$MZP_FAIL/tar"
chmod +x "$MZP_BIN/pgrep" "$MZP_FAIL/pgrep" "$MZP_FAIL/tar"
mzp_list() { (cd "$1" && find . -mindepth 1 -printf '%y %P\n' | LC_ALL=C sort); }
mzp_seed() {   # mzp_seed ROOT MARK: a profile root with profile p1, whose prefs.js holds MARK
    mkdir -p "$1/p1"; printf '%s\n' "$2" > "$1/p1/prefs.js"; printf '[Profile0]\nPath=p1\n' > "$1/profiles.ini"
}
mzp_run() {   # mzp_run save|restore HOME BACKUP XDG [BIN]; XDG: a path, "" (set but empty) or UNSET
    local -a mzp_env=(env)
    if [ "$4" = UNSET ]; then mzp_env+=(-u XDG_CONFIG_HOME); else mzp_env+=("XDG_CONFIG_HOME=$4"); fi
    # shellcheck disable=SC2016  # the inner bash expands $1..$4, not this shell
    "${mzp_env[@]}" HOME="$2" SAVE_PROBLEMS_FILE="${MZP_PROBS:-/dev/null}" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
        PATH="${5:-$MZP_BIN}:$MOCK:/usr/bin:/bin" \
        bash -c 'source "$1"; APP_LANG=$4; "run_$2_module" firefox "$3"; echo "RC:$?"' _ "$SCRIPT" "$1" "$3" "${MZP_LANG:-en}" 2>&1
}
mzp_case() {   # mzp_case TAG HOME XDG MARK [CWD]: the saved archive must hold the profile marked MARK
    local tag="$1" bk out arc xd
    bk="$TMP/mzp-bk-$tag"; mkdir -p "$bk"
    out=$(cd "${5:-$TMP}" && mzp_run save "$2" "$bk" "$3")
    grep -Fqx 'RC:0' <<<"$out" || fail "firefox root ($tag): the save did not succeed (out: $out)"
    arc="$bk/firefox/firefox-profiles.tar.gz"
    [ -f "$arc" ] || fail "firefox root ($tag): no archive was written (out: $out)"
    xd="$TMP/mzp-x-$tag"; mkdir -p "$xd"
    tar xzf "$arc" -C "$xd" || fail "firefox root ($tag): the archive does not extract"
    [ "$(mzp_list "$xd")" = $'d firefox\nd firefox/p1\nf firefox/p1/prefs.js\nf firefox/profiles.ini' ] \
        || fail "firefox root ($tag): the archive holds something else: $(mzp_list "$xd" | tr '\n' '|')"
    [ "$(cat "$xd/firefox/p1/prefs.js")" = "$4" ] \
        || fail "firefox root ($tag): the archive holds the profile '$(cat "$xd/firefox/p1/prefs.js")', not '$4'"
}
mzp_home="$TMP/mzp-home-default"; mzp_seed "$mzp_home/.config/mozilla/firefox" xdg-default
mzp_case default "$mzp_home" UNSET xdg-default
mzp_home="$TMP/mzp-home-env"; mzp_seed "$mzp_home/.config/mozilla/firefox" decoy; mzp_seed "$TMP/mzp-xdg-env/mozilla/firefox" xdg-env
mzp_case env "$mzp_home" "$TMP/mzp-xdg-env" xdg-env
mzp_home="$TMP/mzp-home-empty"; mzp_seed "$mzp_home/.config/mozilla/firefox" xdg-empty
mzp_case empty "$mzp_home" "" xdg-empty
mzp_home="$TMP/mzp-home-rel"; mzp_seed "$mzp_home/.config/mozilla/firefox" xdg-rel; mzp_seed "$TMP/mzp-cwd/rel/mozilla/firefox" decoy
mzp_case rel "$mzp_home" rel xdg-rel "$TMP/mzp-cwd"   # run from the folder where the relative path would point
mzp_home="$TMP/mzp-home-legacy"; mzp_seed "$mzp_home/.mozilla/firefox" legacy; mzp_seed "$mzp_home/.config/mozilla/firefox" decoy
mzp_case legacy "$mzp_home" UNSET legacy
mzp_home="$TMP/mzp-home-mozdir"; mkdir -p "$mzp_home/.mozilla/native-messaging-hosts"; mzp_seed "$mzp_home/.config/mozilla/firefox" xdg-mozdir
mzp_case mozdir "$mzp_home" UNSET xdg-mozdir   # a ~/.mozilla without a firefox folder does not hide the XDG profile
mzp_home="$TMP/mzp-home-link"; mkdir -p "$mzp_home/.config/mozilla"; mzp_seed "$TMP/mzp-link-target" xdg-link
ln -s "$TMP/mzp-link-target" "$mzp_home/.config/mozilla/firefox"
mzp_case link "$mzp_home" UNSET xdg-link

# Neither root exists (an empty ~/.mozilla and a ~/.config/mozilla without firefox): not installed.
mzp_home="$TMP/mzp-home-none"; mkdir -p "$mzp_home/.mozilla" "$mzp_home/.config/mozilla"; mkdir -p "$TMP/mzp-bk-none"
mzp_out=$(mzp_run save "$mzp_home" "$TMP/mzp-bk-none" UNSET)
[ "$mzp_out" = $'Firefox is not installed or has no profiles on this computer.\nRC:0' ] || fail "firefox root (none): wrong result (out: $mzp_out)"
[ -z "$(find "$TMP/mzp-bk-none" -type f -print -quit)" ] || fail "firefox root (none): a file was written"

# What was saved from the XDG root is restored to ~/.mozilla/firefox, and nothing goes to ~/.config.
mzp_home="$TMP/mzp-home-restore"; mkdir -p "$mzp_home"
mzp_out=$(mzp_run restore "$mzp_home" "$TMP/mzp-bk-default" UNSET)
grep -Fqx 'RC:0' <<<"$mzp_out" || fail "firefox root (restore): the restore did not succeed (out: $mzp_out)"
[ "$(cat "$mzp_home/.mozilla/firefox/p1/prefs.js")" = xdg-default ] || fail "firefox root (restore): the profile is not in ~/.mozilla/firefox"
[ "$(mzp_list "$mzp_home/.mozilla")" = $'d firefox\nd firefox/p1\nf firefox/p1/prefs.js\nf firefox/profiles.ini' ] || fail "firefox root (restore): unexpected files in ~/.mozilla: $(mzp_list "$mzp_home/.mozilla" | tr '\n' '|')"
[ ! -e "$mzp_home/.config" ] || fail "firefox root (restore): something was written to ~/.config"

# A save that fails names the folder that was read (the XDG one), in both languages.
for mzp_lang in es en; do
    mzp_home="$TMP/mzp-home-fail-$mzp_lang"; mzp_seed "$mzp_home/.config/mozilla/firefox" xdg-fail
    mkdir -p "$TMP/mzp-bk-fail-$mzp_lang"; MZP_PROBS="$TMP/mzp-problems-$mzp_lang"; : > "$MZP_PROBS"
    mzp_out=$(MZP_LANG=$mzp_lang MZP_PROBS=$MZP_PROBS mzp_run save "$mzp_home" "$TMP/mzp-bk-fail-$mzp_lang" UNSET "$MZP_FAIL")
    if [ "$mzp_lang" = es ]; then
        mzp_want=$(printf 'Aviso: no se pudo guardar «%s» de forma íntegra (¿disco lleno o permisos?); se omite.' "$mzp_home/.config/mozilla/firefox")
    else
        mzp_want=$(printf 'Warning: “%s” could not be saved intact (disk full or permissions?); skipped.' "$mzp_home/.config/mozilla/firefox")
    fi
    grep -Fqx -- "$mzp_want" <<<"$mzp_out" || fail "firefox root (failed save, $mzp_lang): the notice does not name the XDG folder (out: $mzp_out)"
    grep -Fqx 'RC:1' <<<"$mzp_out" || fail "firefox root (failed save, $mzp_lang): the module did not fail (out: $mzp_out)"
    [ "$(cat "$MZP_PROBS")" = "$mzp_home/.config/mozilla/firefox" ] || fail "firefox root (failed save, $mzp_lang): the problem list is not the XDG folder (got: $(cat "$MZP_PROBS"))"
    [ -z "$(find "$TMP/mzp-bk-fail-$mzp_lang/firefox" -type f -print -quit)" ] || fail "firefox root (failed save, $mzp_lang): a file was left in the copy"
done
unset MZP_PROBS
pass "firefox profile root: ~/.mozilla/firefox first, else ~/.config/mozilla/firefox (absolute \$XDG_CONFIG_HOME only; link, none, restore target, failure notice)"

# LUKS restore: keep a recovery header and roll it back on write failure or verification mismatch.
# $MOCK is on the PATH so that "command -v pkexec" succeeds (the stand-in there) whether or
# not the machine has polkit; the privileged calls themselves go through the prun double.
LUKS_TMP="$TMP/luks-restore"; mkdir -p "$LUKS_TMP/headers"
printf 'NEW-HEADER\n' > "$LUKS_TMP/selected.img"
printf 'device fixture\n' > "$LUKS_TMP/device.img"
for mode in fail mismatch; do
    printf 'OLD\n' > "$LUKS_TMP/state"
    PATH="$MOCK:/usr/bin:/bin" LUKS_MODE="$mode" LUKS_TMP="$LUKS_TMP" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
        bash -c '
source "$1"
APP_LANG=en
LUKS_HEADERS_DIR="$LUKS_TMP/headers"
zenity(){ case " $* " in *--file-selection*) printf "%s\n" "$LUKS_TMP/selected.img";; *--entry*) printf "RESTORE\n";; esac; }
luks_pick_device(){ printf "%s" "$LUKS_TMP/device.img"; }
msg_info(){ printf "INFO:%s\n" "$1"; }
msg_error(){ printf "ERROR:%s\n" "$1"; }
log_msg(){ printf "LOG:%s\n" "$1"; }
prun(){ "$@"; }
cryptsetup(){
    local prev="" a file=""
    case "${1:-}" in
        luksDump)
            case "${2:-}" in
                "$LUKS_TMP/selected.img") printf "UUID: NEW-UUID\n";;
                "$LUKS_TMP/device.img")
                    case "$(cat "$LUKS_TMP/state")" in OLD) printf "UUID: OLD-UUID\n";; NEW) printf "UUID: NEW-UUID\n";; *) printf "UUID: CORRUPT\n";; esac;;
                *) printf "UUID: OLD-UUID\n";;
            esac;;
        -q)
            for a in "$@"; do [ "$prev" = --header-backup-file ] && file="$a"; prev="$a"; done
            case " $* " in
                *luksHeaderBackup*)
                    case "$(cat "$LUKS_TMP/state")" in
                        OLD) printf "OLD-HEADER\n" > "$file";;
                        NEW) printf "NEW-HEADER\n" > "$file";;
                        *) printf "CORRUPT-HEADER\n" > "$file";;
                    esac;;
                *luksHeaderRestore*)
                    if [ "$file" = "$LUKS_TMP/selected.img" ]; then
                        if [ "$LUKS_MODE" = fail ]; then printf "CORRUPT\n" > "$LUKS_TMP/state"; return 7; fi
                        if [ "$LUKS_MODE" = mismatch ]; then printf "OLD\n" > "$LUKS_TMP/state"; else printf "NEW\n" > "$LUKS_TMP/state"; fi
                    else
                        printf "OLD\n" > "$LUKS_TMP/state"
                    fi;;
            esac;;
        *) return 1;;
    esac
}
export -f cryptsetup   # the privileged helper runs in a child "bash -c"
do_luks_header_restore
rc=$?
printf "%s\n" "RC:$rc"
exit 0
' _ "$SCRIPT" >"$LUKS_TMP/$mode.out" 2>&1 || fail "LUKS $mode harness exited non-zero"
grep -Fqx 'RC:1' "$LUKS_TMP/$mode.out" || fail "LUKS $mode returned success after the selected restore failed"
grep -qx OLD "$LUKS_TMP/state" || fail "LUKS $mode did not leave the previous UUID after rollback"
grep -Fq 'The previous header was recovered successfully' "$LUKS_TMP/$mode.out" || fail "LUKS $mode did not report the recovered header (the recovery copy was not made or verified)"
find "$LUKS_TMP/headers" -name 'luks-header-recovery_*.img' -print -quit | grep -q . && fail "LUKS $mode leaked its recovery copy"
done
pass "LUKS restore rolls back on failure and verification mismatch"

# LUKS header storage contains recovery material and must fail closed if its
# directory cannot be kept private. Check both backup and restore paths.
LUKS_PERM_TMP="$TMP/luks-permissions"; mkdir -p "$LUKS_PERM_TMP/headers"
printf 'SELECTED-HEADER\n' > "$LUKS_PERM_TMP/selected.img"
printf 'device fixture\n' > "$LUKS_PERM_TMP/device.img"
PATH="$MOCK:/usr/bin:/bin" LUKS_PERM_TMP="$LUKS_PERM_TMP" HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
    bash -c '
source "$1"
APP_LANG=en
LUKS_HEADERS_DIR="$LUKS_PERM_TMP/headers"
luks_pick_device(){ printf "%s" "$LUKS_PERM_TMP/device.img"; }
confirm(){ return 0; }
zenity(){ case " $* " in *--file-selection*) printf "%s\n" "$LUKS_PERM_TMP/selected.img";; *--entry*) printf "RESTORE\n";; esac; }
cryptsetup(){
    case "${1:-}" in
        luksDump) printf "UUID: OLD-UUID\n";;
        *) return 0;;
    esac
}
prun(){ return 0; }
chmod(){ return 17; }
set +e
do_luks_header_backup >/dev/null 2>&1
backup_rc=$?
do_luks_header_restore >/dev/null 2>&1
restore_rc=$?
[ "$backup_rc" -ne 0 ] && [ "$restore_rc" -ne 0 ]
' _ "$SCRIPT" >/dev/null 2>&1 || fail "LUKS header storage permission failures were not fail-closed"
pass "LUKS header storage fails closed without private permissions"

# LUKS header backup must propagate a cryptsetup write failure instead of
# returning the status of the final cleanup command. No partial header may be published.
LUKS_BACKUP_FAIL_ROOT="$TMP/luks-backup-failure"
LUKS_BACKUP_FAIL_BIN="$LUKS_BACKUP_FAIL_ROOT/bin"
mkdir -p "$LUKS_BACKUP_FAIL_ROOT/headers" "$LUKS_BACKUP_FAIL_BIN"
printf 'device fixture\n' > "$LUKS_BACKUP_FAIL_ROOT/device.img"
cat > "$LUKS_BACKUP_FAIL_BIN/cryptsetup" <<'CRYPTFAIL'
#!/bin/sh
case "${1:-}" in
    -q)
        exit 7
        ;;
    luksDump)
        printf 'UUID: TEST-UUID\n'
        ;;
    *)
        exit 1
        ;;
esac
CRYPTFAIL
chmod +x "$LUKS_BACKUP_FAIL_BIN/cryptsetup"
LUKS_BACKUP_FAIL_OUT=$(PATH="$LUKS_BACKUP_FAIL_BIN:$MOCK:/usr/bin:/bin" HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
    LUKS_BACKUP_FAIL_ROOT="$LUKS_BACKUP_FAIL_ROOT" bash -c '
source "$1"
APP_LANG=en
LUKS_HEADERS_DIR="$LUKS_BACKUP_FAIL_ROOT/headers"
zenity(){ case " $* " in *--entry*) printf "LuksFail\n";; esac; }
luks_pick_device(){ printf "%s" "$LUKS_BACKUP_FAIL_ROOT/device.img"; }
confirm(){ return 0; }
prun(){ "$@"; }
set +e
do_luks_header_backup >/dev/null 2>&1
rc=$?
printf "RC:%s\n" "$rc"
' _ "$SCRIPT" 2>&1)
printf '%s\n' "$LUKS_BACKUP_FAIL_OUT" | grep -Fq 'RC:1' || fail "LUKS header backup hid a cryptsetup failure"
find "$LUKS_BACKUP_FAIL_ROOT/headers" -name 'luks-header_*.img' -print -quit | grep -q . && fail "failed LUKS header backup published a partial image"
pass "LUKS header backup propagates cryptsetup failures"

# LUKS backup names must never collide inside the same second: a new backup
# receives a suffix instead of overwriting the previous binary or metadata note.
LUKS_COLLIDE_ROOT="$TMP/luks-name-collision"
LUKS_COLLIDE_BIN="$LUKS_COLLIDE_ROOT/bin"
mkdir -p "$LUKS_COLLIDE_ROOT/headers" "$LUKS_COLLIDE_BIN"
printf 'device fixture\n' > "$LUKS_COLLIDE_ROOT/device.img"
cat > "$LUKS_COLLIDE_BIN/cryptsetup" <<'CRYPTCOLLIDE'
#!/bin/sh
case "${1:-}" in
    luksDump)
        printf 'UUID: TEST-UUID\n'
        ;;
    -q)
        prev=""
        file=""
        for a in "$@"; do
            [ "$prev" = --header-backup-file ] && file="$a"
            prev="$a"
        done
        case " $* " in
            *luksHeaderBackup*) printf 'TEST-HEADER\n' > "$file" ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 1 ;;
esac
CRYPTCOLLIDE
cat > "$LUKS_COLLIDE_BIN/lsblk" <<'LSBLKCOLLIDE'
#!/bin/sh
printf 'TEST-UUID\n'
LSBLKCOLLIDE
chmod +x "$LUKS_COLLIDE_BIN/cryptsetup" "$LUKS_COLLIDE_BIN/lsblk"
PATH="$LUKS_COLLIDE_BIN:$MOCK:/usr/bin:/bin" HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
    LUKS_COLLIDE_ROOT="$LUKS_COLLIDE_ROOT" bash -c '
source "$1"
APP_LANG=en
LUKS_HEADERS_DIR="$LUKS_COLLIDE_ROOT/headers"
luks_pick_device(){ printf "%s" "$LUKS_COLLIDE_ROOT/device.img"; }
confirm(){ return 0; }
msg_info(){ :; }
msg_error(){ printf "ERR:%s\n" "$1" >&2; }
prun(){ "$@"; }   # runs the stand-in cryptsetup of $LUKS_COLLIDE_BIN, as prun would
date(){ printf "20261008-022600\n"; }
do_luks_header_backup || exit 1
do_luks_header_backup || exit 1
' _ "$SCRIPT" >/dev/null 2>"$LUKS_COLLIDE_ROOT/err" || fail "LUKS backup name-collision scenario failed: $(head -c 300 "$LUKS_COLLIDE_ROOT/err")"
[ "$(find "$LUKS_COLLIDE_ROOT/headers" -maxdepth 1 -type f -name 'luks-header_*.img' | wc -l)" -eq 2 ] || fail "second LUKS backup overwrote the first binary"
[ "$(find "$LUKS_COLLIDE_ROOT/headers" -maxdepth 1 -type f -name 'luks-header_*.txt' | wc -l)" -eq 2 ] || fail "second LUKS backup overwrote the first metadata note"
[ "$(grep -lFx TEST-HEADER "$LUKS_COLLIDE_ROOT"/headers/luks-header_*.img | wc -l)" -eq 2 ] || fail "LUKS backup images do not hold the header (the stand-in cryptsetup did not run)"
find "$LUKS_COLLIDE_ROOT/headers" -maxdepth 1 -type f -name '*_copy2.img' -print -quit | grep -q . || fail "second LUKS backup of the same second is not named copy 2"
pass "LUKS backup names avoid same-second collisions"

# The name chosen for a new copy may already be taken (only a "_copy2" is left
# in the folder, so the next one is also "_copy2"): it gets a suffix, nothing is overwritten.
rm -f "$LUKS_COLLIDE_ROOT"/headers/*
printf 'KEEP-ME\n' > "$LUKS_COLLIDE_ROOT/headers/luks-header_device_img-TEST-UUID_20261008-022600_copy2.img"
PATH="$LUKS_COLLIDE_BIN:$MOCK:/usr/bin:/bin" HOME="$HOME_DIR" XDG_CONFIG_HOME="$CFG" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 \
    LUKS_COLLIDE_ROOT="$LUKS_COLLIDE_ROOT" bash -c '
source "$1"
APP_LANG=en
LUKS_HEADERS_DIR="$LUKS_COLLIDE_ROOT/headers"
luks_pick_device(){ printf "%s" "$LUKS_COLLIDE_ROOT/device.img"; }
confirm(){ return 0; }
msg_info(){ :; }
msg_error(){ printf "ERR:%s\n" "$1" >&2; }
prun(){ "$@"; }
date(){ printf "20261008-022600\n"; }
do_luks_header_backup || exit 1
' _ "$SCRIPT" >/dev/null 2>"$LUKS_COLLIDE_ROOT/err" || fail "LUKS backup with a taken name failed: $(head -c 300 "$LUKS_COLLIDE_ROOT/err")"
grep -Fxq KEEP-ME "$LUKS_COLLIDE_ROOT/headers/luks-header_device_img-TEST-UUID_20261008-022600_copy2.img" || fail "LUKS backup overwrote a copy that already had its name"
find "$LUKS_COLLIDE_ROOT/headers" -maxdepth 1 -type f -name '*_copy2_1.img' -print -quit | grep -q . || fail "LUKS backup with a taken name did not get a numeric suffix"
pass "LUKS backup never overwrites a copy that already has its name"

# Cinnamon root files are fed to tar with NUL delimiters so filenames containing
# spaces (or other whitespace) are preserved exactly.
CIN_ROOT="$TMP/cinnamon-root-file-space"
CIN_BACKUP="$CIN_ROOT/backup"
mkdir -p "$CIN_ROOT/home/.cinnamon" "$CIN_BACKUP"
printf 'MENUICON\n' > "$CIN_ROOT/home/.cinnamon/menu icon.svg"
HOME="$CIN_ROOT/home" XDG_CONFIG_HOME="$CIN_ROOT/config" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 PATH="$MOCK:/usr/bin:/bin" LC_ALL=C.UTF-8 \
    CIN_BACKUP="$CIN_BACKUP" bash -c '
source "$1"
APP_LANG=en
log_msg(){ :; }
save_desktop "$CIN_BACKUP" || exit 1
tar -tzf "$CIN_BACKUP/desktop/cinnamon-root-files.tar.gz"
' _ "$SCRIPT" > "$CIN_ROOT/list" 2>/dev/null || fail "Cinnamon root-file save failed for a filename containing spaces"
grep -Fqx 'menu icon.svg' "$CIN_ROOT/list" || fail "Cinnamon root-file tar lost a filename containing spaces"
if grep -Fq '/.cinnamon/' "$CIN_ROOT/list"; then
    fail "Cinnamon root-file tar embedded the source path instead of the basename"
fi
pass "Cinnamon root-file backup preserves whitespace in filenames"

# Cinnamon applet/desklet settings: since Cinnamon 5 each instance keeps its JSON
# in ~/.config/cinnamon/spices/<uuid>/<n>.json (older versions used
# ~/.cinnamon/configs). Both are saved and restored; only the old one used to
# be, so on a current Mint the applets came back with default settings (menu
# icon, weather location...). Restoring goes through the safe extraction.
SPI_ROOT="$TMP/cinnamon-spices"; SPI_BK="$SPI_ROOT/backup"
spi_home() {   # spi_home DIR [new] [old] -> fresh HOME holding the chosen locations
    rm -rf "$1"; mkdir -p "$1/.config"
    case " ${2:-} ${3:-} " in *" new "*)
        mkdir -p "$1/.config/cinnamon/spices/menu@cinnamon.org" "$1/.config/cinnamon/spices/weather@mockturtl"
        printf '{"menu-icon":"new-icon"}\n' > "$1/.config/cinnamon/spices/menu@cinnamon.org/0.json"
        printf '{"city":"Madrid"}\n' > "$1/.config/cinnamon/spices/weather@mockturtl/14.json" ;; esac
    case " ${2:-} ${3:-} " in *" old "*)
        mkdir -p "$1/.cinnamon/configs/menu@cinnamon.org"
        printf '{"menu-icon":"old-icon"}\n' > "$1/.cinnamon/configs/menu@cinnamon.org/0.json" ;; esac
}
spi_run() {   # spi_run save|restore HOME LANG -> spi_rc, spi_out (log lines + stderr); "save" starts from an empty backup
    [ "$1" = save ] && { rm -rf "$SPI_BK"; mkdir -p "$SPI_BK"; }
    spi_out=$(HOME="$2" XDG_CONFIG_HOME="$SPI_ROOT/cfg" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 \
        PATH="$MOCK:/usr/bin:/bin" LC_ALL=C.UTF-8 bash -c '
source "$1"; APP_LANG="$3"
log_msg() { printf "%s\n" "$1"; }
if [ "$2" = save ]; then save_desktop "$4"; else run_restore_module desktop "$4"; fi
' _ "$SCRIPT" "$1" "$3" "$SPI_BK" 2>&1)
    spi_rc=$?
}
for spi_lang in es en; do
    if [ "$spi_lang" = es ]; then spi_line='Restaurando ajustes de applets/desklets (icono del menú y demás)...'
    else spi_line='Restoring applet/desklet settings (menu icon and other settings)...'; fi
    # Both locations: separate archives, restored to both places; an existing file is replaced.
    spi_home "$SPI_ROOT/h1" new old; spi_run save "$SPI_ROOT/h1" "$spi_lang"
    [ "$spi_rc" -eq 0 ] || fail "cinnamon settings ($spi_lang): save failed (rc $spi_rc, out: $spi_out)"
    tar -tzf "$SPI_BK/desktop/spices.tar.gz" 2>/dev/null | grep -Fqx 'spices/menu@cinnamon.org/0.json' || fail "cinnamon settings ($spi_lang): ~/.config/cinnamon/spices (menu applet) was not saved"
    tar -tzf "$SPI_BK/desktop/spices.tar.gz" 2>/dev/null | grep -Fqx 'spices/weather@mockturtl/14.json' || fail "cinnamon settings ($spi_lang): ~/.config/cinnamon/spices (weather applet) was not saved"
    tar -tzf "$SPI_BK/desktop/configs.tar.gz" 2>/dev/null | grep -Fqx 'configs/menu@cinnamon.org/0.json' || fail "cinnamon settings ($spi_lang): ~/.cinnamon/configs was not saved"
    spi_home "$SPI_ROOT/h2"; mkdir -p "$SPI_ROOT/h2/.config/cinnamon/spices/menu@cinnamon.org"
    printf '{"menu-icon":"stale"}\n' > "$SPI_ROOT/h2/.config/cinnamon/spices/menu@cinnamon.org/0.json"
    spi_run restore "$SPI_ROOT/h2" "$spi_lang"
    [ "$spi_rc" -eq 0 ] || fail "cinnamon settings ($spi_lang): restore failed (rc $spi_rc, out: $spi_out)"
    grep -Fqx '{"menu-icon":"new-icon"}' "$SPI_ROOT/h2/.config/cinnamon/spices/menu@cinnamon.org/0.json" 2>/dev/null || fail "cinnamon settings ($spi_lang): the saved menu applet settings did not replace the existing ones"
    grep -Fqx '{"city":"Madrid"}' "$SPI_ROOT/h2/.config/cinnamon/spices/weather@mockturtl/14.json" 2>/dev/null || fail "cinnamon settings ($spi_lang): the weather applet settings were not restored"
    grep -Fqx '{"menu-icon":"old-icon"}' "$SPI_ROOT/h2/.cinnamon/configs/menu@cinnamon.org/0.json" 2>/dev/null || fail "cinnamon settings ($spi_lang): ~/.cinnamon/configs was not restored"
    [ "$(grep -Fxc -- "$spi_line" <<<"$spi_out")" -eq 1 ] || fail "cinnamon settings ($spi_lang): the restore notice was not shown exactly once (out: $spi_out)"
    # Neither location: nothing saved, nothing announced.
    spi_home "$SPI_ROOT/h3"; spi_run save "$SPI_ROOT/h3" "$spi_lang"
    [ "$spi_rc" -eq 0 ] || fail "cinnamon settings ($spi_lang): save without applet settings failed (rc $spi_rc)"
    [ ! -e "$SPI_BK/desktop/spices.tar.gz" ] && [ ! -e "$SPI_BK/desktop/configs.tar.gz" ] || fail "cinnamon settings ($spi_lang): archives were made with nothing to save"
    spi_home "$SPI_ROOT/h4"; spi_run restore "$SPI_ROOT/h4" "$spi_lang"
    [ "$spi_rc" -eq 0 ] || fail "cinnamon settings ($spi_lang): restore without applet settings failed (rc $spi_rc)"
    ! grep -Fqx -- "$spi_line" <<<"$spi_out" || fail "cinnamon settings ($spi_lang): announced a restore with nothing to restore"
done
# Only one location: only that one is saved and restored, and the other is not created.
spi_home "$SPI_ROOT/h5" new; spi_run save "$SPI_ROOT/h5" es
[ -f "$SPI_BK/desktop/spices.tar.gz" ] && [ ! -e "$SPI_BK/desktop/configs.tar.gz" ] || fail "cinnamon settings: only ~/.config/cinnamon/spices exists but the archives do not match"
spi_home "$SPI_ROOT/h6"; spi_run restore "$SPI_ROOT/h6" es
grep -Fqx '{"city":"Madrid"}' "$SPI_ROOT/h6/.config/cinnamon/spices/weather@mockturtl/14.json" 2>/dev/null || fail "cinnamon settings: spices-only copy was not restored"
[ ! -e "$SPI_ROOT/h6/.cinnamon" ] || fail "cinnamon settings: restoring a spices-only copy created ~/.cinnamon"
spi_home "$SPI_ROOT/h7" old; spi_run save "$SPI_ROOT/h7" es
[ -f "$SPI_BK/desktop/configs.tar.gz" ] && [ ! -e "$SPI_BK/desktop/spices.tar.gz" ] || fail "cinnamon settings: only ~/.cinnamon/configs exists but the archives do not match"
spi_home "$SPI_ROOT/h8"; spi_run restore "$SPI_ROOT/h8" es
grep -Fqx '{"menu-icon":"old-icon"}' "$SPI_ROOT/h8/.cinnamon/configs/menu@cinnamon.org/0.json" 2>/dev/null || fail "cinnamon settings: configs-only copy was not restored"
[ ! -e "$SPI_ROOT/h8/.config/cinnamon" ] || fail "cinnamon settings: restoring a configs-only copy created ~/.config/cinnamon"
# A crafted spices archive is refused (safe extraction), writes nothing outside, and does not stop the other restore.
spi_home "$SPI_ROOT/h9" new old; spi_run save "$SPI_ROOT/h9" es
python3 - "$SPI_BK/desktop/spices.tar.gz" <<'PYSPICES'
import io
import tarfile
import sys
with tarfile.open(sys.argv[1], "w:gz") as tf:
    data = b"must-not-escape\n"
    info = tarfile.TarInfo("../spices-escape.json")
    info.size = len(data)
    tf.addfile(info, io.BytesIO(data))
PYSPICES
spi_home "$SPI_ROOT/h10"; spi_run restore "$SPI_ROOT/h10" es
[ "$spi_rc" -ne 0 ] || fail "cinnamon settings: a crafted spices archive was restored with rc 0"
grep -Fq 'spices.tar.gz' <<<"$spi_out" || fail "cinnamon settings: no warning naming the refused archive (out: $spi_out)"
[ ! -e "$SPI_ROOT/h10/.config/spices-escape.json" ] || fail "cinnamon settings: a crafted spices archive wrote outside ~/.config/cinnamon"
grep -Fqx '{"menu-icon":"old-icon"}' "$SPI_ROOT/h10/.cinnamon/configs/menu@cinnamon.org/0.json" 2>/dev/null || fail "cinnamon settings: refusing the spices archive stopped the ~/.cinnamon/configs restore"
pass "cinnamon settings: ~/.config/cinnamon/spices and ~/.cinnamon/configs are saved and restored (es/en)"

# Language autodetection: Spanish preference -> ES, other defaults -> EN.
got=$(HOME="$HOME_DIR" XDG_CONFIG_HOME="$TMP/detect-es" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LANGUAGE=es LANG=C LC_ALL='' \
    bash -c 'source "$1"; printf "%s" "$APP_LANG"' _ "$SCRIPT")
[ "$got" = es ] || fail "Spanish language preference detected as $got"
got=$(HOME="$HOME_DIR" XDG_CONFIG_HOME="$TMP/detect-default" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 LANGUAGE=ca LANG=C LC_ALL='' \
    bash -c 'source "$1"; printf "%s" "$APP_LANG"' _ "$SCRIPT")
[ "$got" = en ] || fail "non-Spanish language preference detected as $got"
pass "realistic language autodetection"

# Quick toggle from the interactive menu.
SEQ=$'L\n5\n'
HOME="$HOME_DIR" XDG_CONFIG_HOME="$TMP/toggle" MINT_SETUP_BACKUPS_DIR="$BACKUPS" PATH="$MOCK:/usr/bin:/bin" \
ZENITY_CAPTURE="$TMP/toggle-calls" ZENITY_LIST_CHOICES="$SEQ" LC_ALL=C.UTF-8 \
bash "$SCRIPT" >/dev/null 2>&1 || fail "menu language toggle flow exited non-zero"
[ "$(cat "$TMP/toggle/mint-setup/language")" = "es" ] || fail "interactive L toggle did not persist Spanish"
grep -Fq 'Cambiar idioma' "$TMP/toggle-calls/calls" || fail "interactive L toggle did not redraw in Spanish"
pass "interactive language toggle"

# Compare (menu option 3) end to end, in both languages, with and without
# changes. The real menu runs and the exact report is checked. Nothing may reach
# stderr: in English T() printed "bad array subscript" for each blank line of
# the report (two with no changes, one with changes).
CMP_BACKUPS="$TMP/compare-backups"; CMP_BIN="$TMP/compare-bin"
mkdir -p "$CMP_BIN"
cat > "$CMP_BIN/gsettings" <<'GS'
#!/bin/sh
echo "'Same'"
GS
chmod +x "$CMP_BIN/gsettings"
for kind in changes same; do
    mkdir -p "$CMP_BACKUPS/$kind/appearance"
    printf 'NAME=%q\nDATE=%q\nMODULES=%q\n' "Compare $kind" '2026-10-18 10:00:00' appearance > "$CMP_BACKUPS/$kind/manifest.conf"
done
printf "gtk-theme='Old'\n" > "$CMP_BACKUPS/changes/appearance/interface.dconf"
printf "gtk-theme='Same'\n" > "$CMP_BACKUPS/same/appearance/interface.dconf"
for lang in es en; do
    mkdir -p "$TMP/compare-cfg-$lang/mint-setup"
    printf '%s\n' "$lang" > "$TMP/compare-cfg-$lang/mint-setup/language"
    if [ "$lang" = es ]; then
        t_head='Comparando el sistema actual con:'; t_title='Cambios detectados'
        t_theme='• El tema ha cambiado'; t_none='No se han detectado cambios relevantes en las áreas guardadas.'
    else
        t_head='Comparing the current system with:'; t_title='Detected changes'
        t_theme='• The theme has changed'; t_none='No relevant changes were detected in the saved areas.'
    fi
    for kind in changes same; do
        out="$TMP/compare-$lang-$kind"
        SEQ=$(printf '3\n%s\n5\n' "$CMP_BACKUPS/$kind")
        HOME="$HOME_DIR" XDG_CONFIG_HOME="$TMP/compare-cfg-$lang" MINT_SETUP_BACKUPS_DIR="$CMP_BACKUPS" \
            PATH="$CMP_BIN:$MOCK:/usr/bin:/bin" ZENITY_CAPTURE="$out" ZENITY_LIST_CHOICES="$SEQ" LC_ALL=C.UTF-8 \
            bash "$SCRIPT" >/dev/null 2>"$out.err" || fail "compare flow exited non-zero ($lang, $kind)"
        [ ! -s "$out.err" ] || fail "compare flow printed to stderr ($lang, $kind): $(head -c 300 "$out.err")"
        {
            printf '%s\n%s\n\n%s\n-------------------\n' "$t_head" "$CMP_BACKUPS/$kind" "$t_title"
            if [ "$kind" = changes ]; then printf '%s\n' "$t_theme"; else printf '\n%s\n' "$t_none"; fi
        } > "$out.expected"
        cmp -s "$out/report" "$out.expected" || fail "compare report differs ($lang, $kind): $(diff "$out.expected" "$out/report" 2>&1 | head -c 300)"
    done
done
pass "compare flow in ES and EN, with and without changes: exact report and clean stderr"

# 12.46: do_compare. The saved wallpaper that a restore applies is not a change: restore_wallpaper_uri
# points the key at its copy under <Pictures>/MintSetupWallpapers, not at the path in the dump, so
# comparing right after a restore reported "Wallpaper changed" exactly as for a different one. Besides
# the theme, no branch of the function had a test: icons, wallpaper, applets, packages and the order of
# the lines are all checked here, in ES and EN, against the exact report.
CM2_DIR="$TMP/cmp2"; rm -rf "$CM2_DIR"; mkdir -p "$CM2_DIR/bin" "$CM2_DIR/state" "$CM2_DIR/home" "$CM2_DIR/backups"
cat > "$CM2_DIR/bin/gsettings" <<'GS'
#!/bin/sh
# The state is the GVariant text "get" prints, one file per key (the third argument).
f="$CM2_STATE/$3"
case "$1" in
    get) [ -f "$f" ] || exit 1; cat "$f" ;;
    set) printf "'%s'\n" "$4" > "$f" ;;
esac
GS
cat > "$CM2_DIR/bin/zenity" <<'ZEN'
#!/bin/sh
for a in "$@"; do case "$a" in --filename=*) cp "${a#--filename=}" "$CM2_STATE/report" ;; esac; done
ZEN
cat > "$CM2_DIR/bin/apt-mark" <<'APT'
#!/bin/sh
[ "${1:-}" = showmanual ] && cat "$CM2_STATE/apt-now" 2>/dev/null
exit 0
APT
chmod +x "$CM2_DIR/bin/gsettings" "$CM2_DIR/bin/zenity" "$CM2_DIR/bin/apt-mark"
cm2_state() {   # the system holds exactly what the base backup holds
    rm -rf "$CM2_DIR/state"; mkdir -p "$CM2_DIR/state"
    printf "'Mint-Y'\n" > "$CM2_DIR/state/gtk-theme"
    printf "'Mint-Y-Aqua'\n" > "$CM2_DIR/state/icon-theme"
    printf "'file:///usr/share/backgrounds/orig.jpg'\n" > "$CM2_DIR/state/picture-uri"
    printf "['panel1:left:0:menu@cinnamon.org:0', 'panel1:right:0:systray@cinnamon.org:1']\n" > "$CM2_DIR/state/enabled-applets"
    printf 'curl\ngit\nvim\n' > "$CM2_DIR/state/apt-now"
}
cm2_backup() {   # cm2_backup NAME ORIGINAL_URI [SAVED_IMAGE_NAME] -> path of the copy (the package list is unsorted on purpose)
    local d="$CM2_DIR/backups/$1"
    rm -rf "$d"; mkdir -p "$d/appearance" "$d/desktop" "$d/software"
    printf "gtk-theme='Mint-Y'\nicon-theme='Mint-Y-Aqua'\n" > "$d/appearance/interface.dconf"
    printf "picture-uri='%s'\n" "$2" > "$d/appearance/background.dconf"
    printf "enabled-applets=['panel1:left:0:menu@cinnamon.org:0', 'panel1:right:0:systray@cinnamon.org:1']\n" > "$d/desktop/cinnamon.dconf"
    printf 'vim\ngit\ncurl\n' > "$d/software/apt-manual.list"
    if [ -n "${3:-}" ]; then printf '%s\n' "$3" > "$d/appearance/wallpaper.filename"; printf 'IMG' > "$d/appearance/wallpaper-$3"; fi
    printf '%s' "$d"
}
cm2_lib() {   # cm2_lib LANG BACKUP CODE: the program as a library, with the stubs, the home and the language of the case
    HOME="$CM2_DIR/home" CM2_STATE="$CM2_DIR/state" MINT_SETUP_TEST=1 LC_ALL=C.UTF-8 PATH="$CM2_DIR/bin:$MOCK:/usr/bin:/bin" bash -c '
source "$1"; APP_LANG="$2"; BK="$3"
pick_backup_dir() { printf "%s" "$BK"; }
eval "$4"
' _ "$SCRIPT" "$1" "$2" "$3" 2>&1
}
cm2_expect() {   # cm2_expect BACKUP LINE... -> the exact report (no lines: the "no changes" text)
    local bk="$1"; shift
    printf '%s\n%s\n\n%s\n-------------------\n' "$CM2_HEAD" "$bk" "$CM2_TITLE"
    if [ "$#" -eq 0 ]; then printf '\n%s\n' "$CM2_NONE"; else printf '%s\n' "$@"; fi
}
cm2_check() {   # cm2_check LANG WHAT BACKUP LINE...: runs do_compare on the current state and compares the report
    local lang="$1" what="$2" bk="$3" out want
    shift 3
    rm -f "$CM2_DIR/state/report"
    out=$(cm2_lib "$lang" "$bk" do_compare)
    [ -z "$out" ] || fail "compare $what ($lang): output on the terminal: $out"
    want=$(cm2_expect "$bk" "$@")
    [ "$(cat "$CM2_DIR/state/report" 2>/dev/null)" = "$want" ] || fail "compare $what ($lang): report differs. Got: [$(tail -c 400 "$CM2_DIR/state/report" 2>/dev/null)] Expected: [$(printf '%s' "$want" | tail -c 400)]"
}
for cm2_lang in es en; do
    if [ "$cm2_lang" = es ]; then
        CM2_HEAD='Comparando el sistema actual con:'; CM2_TITLE='Cambios detectados'
        CM2_NONE='No se han detectado cambios relevantes en las áreas guardadas.'
        CM2_THEME='• El tema ha cambiado'; CM2_ICONS='• Los iconos han cambiado'; CM2_BG='• Nuevo fondo de pantalla'
        CM2_APPLETS='• Ha cambiado la lista de applets del panel'
        CM2_ADD='• %s paquete(s) nuevo(s) instalado(s) desde el guardado'; CM2_DEL='• %s paquete(s) eliminado(s) desde el guardado'
    else
        CM2_HEAD='Comparing the current system with:'; CM2_TITLE='Detected changes'
        CM2_NONE='No relevant changes were detected in the saved areas.'
        CM2_THEME='• The theme has changed'; CM2_ICONS='• The icons have changed'; CM2_BG='• Wallpaper changed'
        CM2_APPLETS='• The panel applet list has changed'
        CM2_ADD='• Packages installed since the backup: %s'; CM2_DEL='• Packages removed since the backup: %s'
    fi
    # shellcheck disable=SC2059  # CM2_ADD and CM2_DEL are the format strings under test
    cm2_add() { printf "$CM2_ADD" "$1"; }
    # shellcheck disable=SC2059
    cm2_del() { printf "$CM2_DEL" "$1"; }
    cm2_bk=$(cm2_backup base 'file:///usr/share/backgrounds/orig.jpg')
    cm2_state; cm2_check "$cm2_lang" "nothing changed" "$cm2_bk"
    cm2_state; printf "'Other'\n" > "$CM2_DIR/state/gtk-theme"; cm2_check "$cm2_lang" "theme" "$cm2_bk" "$CM2_THEME"
    cm2_state; printf "'Other'\n" > "$CM2_DIR/state/icon-theme"; cm2_check "$cm2_lang" "icons" "$cm2_bk" "$CM2_ICONS"
    cm2_state; printf "'file:///usr/share/backgrounds/otro.jpg'\n" > "$CM2_DIR/state/picture-uri"; cm2_check "$cm2_lang" "wallpaper" "$cm2_bk" "$CM2_BG"
    cm2_state; printf "['panel1:left:0:menu@cinnamon.org:0']\n" > "$CM2_DIR/state/enabled-applets"; cm2_check "$cm2_lang" "applets" "$cm2_bk" "$CM2_APPLETS"
    cm2_state; printf 'curl\ngit\nvim\nemacs\nnano\n' > "$CM2_DIR/state/apt-now"; cm2_check "$cm2_lang" "packages added" "$cm2_bk" "$(cm2_add 2)"
    cm2_state; printf 'curl\nvim\n' > "$CM2_DIR/state/apt-now"; cm2_check "$cm2_lang" "package removed" "$cm2_bk" "$(cm2_del 1)"
    cm2_state; printf 'curl\nvim\nemacs\nnano\ntmux\n' > "$CM2_DIR/state/apt-now"; cm2_check "$cm2_lang" "packages added and removed" "$cm2_bk" "$(cm2_add 3)" "$(cm2_del 1)"
    cm2_state
    printf "'Other'\n" > "$CM2_DIR/state/gtk-theme"; printf "'Other'\n" > "$CM2_DIR/state/icon-theme"
    printf "'file:///usr/share/backgrounds/otro.jpg'\n" > "$CM2_DIR/state/picture-uri"; printf "[]\n" > "$CM2_DIR/state/enabled-applets"
    printf 'curl\nvim\nemacs\n' > "$CM2_DIR/state/apt-now"
    cm2_check "$cm2_lang" "everything changed" "$cm2_bk" "$CM2_THEME" "$CM2_ICONS" "$CM2_BG" "$CM2_APPLETS" "$(cm2_add 1)" "$(cm2_del 1)"
done
pass "compare: every branch (theme, icons, wallpaper, applets, packages added and removed, all together, none) gives the exact report (es/en)"

# shellcheck disable=SC2016  # evaluated by the child shell, which defines BK
cm2_restore='restore_wallpaper_uri "$BK/appearance" picture-uri ""'
# shellcheck disable=SC2016  # same
cm2_restore_rc='restore_wallpaper_uri "$BK/appearance" picture-uri ""; echo "RC:$?"'
# The wallpaper of a restored copy: restore_wallpaper_uri applies it and the comparison that follows is
# clean, whatever the name of the image; a different wallpaper is still reported, also when the copy
# holds an image and when it has none.
for cm2_lang in es en; do
    if [ "$cm2_lang" = es ]; then CM2_HEAD='Comparando el sistema actual con:'; CM2_TITLE='Cambios detectados'; CM2_NONE='No se han detectado cambios relevantes en las áreas guardadas.'; CM2_BG='• Nuevo fondo de pantalla'
    else CM2_HEAD='Comparing the current system with:'; CM2_TITLE='Detected changes'; CM2_NONE='No relevant changes were detected in the saved areas.'; CM2_BG='• Wallpaper changed'; fi
    for cm2_img in 'orig.jpg' "Rob's pic.jpg" 'año ñ & b.png' 'a b.jpg'; do
        cm2_bk=$(cm2_backup wp 'file:///usr/share/backgrounds/orig.jpg' "$cm2_img")
        cm2_state
        [ -z "$(cm2_lib "$cm2_lang" "$cm2_bk" "$cm2_restore")" ] || fail "wallpaper restore ($cm2_lang, $cm2_img): the restore printed something"
        grep -q 'MintSetupWallpapers' "$CM2_DIR/state/picture-uri" || fail "wallpaper restore ($cm2_lang, $cm2_img): the key was not pointed at the copy ($(cat "$CM2_DIR/state/picture-uri"))"
        cm2_check "$cm2_lang" "after restoring the copy of $cm2_img" "$cm2_bk"
        cm2_state; cm2_check "$cm2_lang" "the original path of $cm2_img still in place" "$cm2_bk"
        cm2_state; printf "'file:///home/x/Pictures/%s'\n" "$cm2_img" > "$CM2_DIR/state/picture-uri"
        cm2_check "$cm2_lang" "a different wallpaper with the name of $cm2_img" "$cm2_bk" "$CM2_BG"
    done
    cm2_bk=$(cm2_backup wp-none 'file:///usr/share/backgrounds/orig.jpg')
    cm2_state; cm2_check "$cm2_lang" "no saved image, the original path in place" "$cm2_bk"
    cm2_state; printf "'file://%s/Pictures/MintSetupWallpapers/orig.jpg'\n" "$CM2_DIR/home" > "$CM2_DIR/state/picture-uri"
    cm2_check "$cm2_lang" "no saved image, another wallpaper" "$cm2_bk" "$CM2_BG"
    # A saved name whose image is missing: the restore leaves the key alone, so the copy's place is no proof.
    cm2_bk=$(cm2_backup wp-noimg 'file:///usr/share/backgrounds/orig.jpg' 'orig.jpg'); rm -f "$cm2_bk/appearance/wallpaper-orig.jpg"
    cm2_state; printf "'file://%s/Pictures/MintSetupWallpapers/orig.jpg'\n" "$CM2_DIR/home" > "$CM2_DIR/state/picture-uri"
    cm2_check "$cm2_lang" "saved name without its image, another wallpaper" "$cm2_bk" "$CM2_BG"
    # A dump without a picture-uri key has nothing to compare.
    cm2_bk=$(cm2_backup wp-nokey 'file:///usr/share/backgrounds/orig.jpg'); printf "picture-options='zoom'\n" > "$cm2_bk/appearance/background.dconf"
    cm2_state; printf "'file:///elsewhere.jpg'\n" > "$CM2_DIR/state/picture-uri"
    cm2_check "$cm2_lang" "dump without a wallpaper key" "$cm2_bk"
done
pass "compare: the wallpaper a restore applies is not a change, for any image name; a different one still is (es/en)"

# The property the restore keeps (and wallpaper_restore_dest now carries for both callers): the name in
# wallpaper.filename comes from the copy, so it is reduced to its last component and the image is written
# inside MintSetupWallpapers, never outside; "." and ".." restore nothing and are not an error.
for cm2_evil in '../../evil.png' '/tmp/evil-abs/evil.png' 'sub/dir/evil.png'; do
    cm2_bk=$(cm2_backup wp-evil 'file:///usr/share/backgrounds/orig.jpg')
    printf '%s\n' "$cm2_evil" > "$cm2_bk/appearance/wallpaper.filename"; printf 'IMG' > "$cm2_bk/appearance/wallpaper-evil.png"
    cm2_state; rm -rf "$CM2_DIR/home/Pictures" "$CM2_DIR/home/evil.png" "$CM2_DIR/evil.png"
    cm2_out=$(cm2_lib en "$cm2_bk" "$cm2_restore_rc")
    [ "$cm2_out" = "RC:0" ] || fail "tampered wallpaper name $cm2_evil: the restore failed or printed something ($cm2_out)"
    [ -f "$CM2_DIR/home/Pictures/MintSetupWallpapers/evil.png" ] || fail "tampered wallpaper name $cm2_evil: the image was not written inside the folder"
    [ -z "$(find "$CM2_DIR" -name evil.png ! -path '*/MintSetupWallpapers/*')" ] || fail "tampered wallpaper name $cm2_evil: a file landed outside the folder"
    grep -q 'MintSetupWallpapers/evil.png' "$CM2_DIR/state/picture-uri" || fail "tampered wallpaper name $cm2_evil: the key does not point at the copy ($(cat "$CM2_DIR/state/picture-uri"))"
done
for cm2_evil in '.' '..'; do
    cm2_bk=$(cm2_backup wp-evil 'file:///usr/share/backgrounds/orig.jpg')
    printf '%s\n' "$cm2_evil" > "$cm2_bk/appearance/wallpaper.filename"; printf 'IMG' > "$cm2_bk/appearance/wallpaper-$cm2_evil"
    cm2_state; rm -rf "$CM2_DIR/home/Pictures"; cm2_before=$(cat "$CM2_DIR/state/picture-uri")
    cm2_out=$(cm2_lib en "$cm2_bk" "$cm2_restore_rc")
    [ "$cm2_out" = "RC:0" ] || fail "wallpaper name \"$cm2_evil\": expected nothing to restore with rc 0 ($cm2_out)"
    [ "$(cat "$CM2_DIR/state/picture-uri")" = "$cm2_before" ] || fail "wallpaper name \"$cm2_evil\": the key changed"
    [ ! -e "$CM2_DIR/home/Pictures/MintSetupWallpapers" ] || fail "wallpaper name \"$cm2_evil\": the destination folder was created"
done
pass "compare: a tampered wallpaper name is reduced to its last component and written inside the folder; \".\" and \"..\" restore nothing"

# The counts of the closing dialogs of do_restore: a module that finished but
# failed is not a "completed" one ("Completed 1 of 1, but these failed: Firefox"
# contradicted itself). Real script and stub zenity, in ES and EN. Firefox is
# "open" (its module fails at once) and, per case, LibreWolf is closed (it
# succeeds), open (it fails) or replaced by VS Code with a slow "code" while the
# progress window closes at 1.5 s (a Cancel): the failed module is not counted.
CNT_BACKUP="$TMP/cnt-backups"; mkdir -p "$CNT_BACKUP/copy/vscode"
cp -a "$OPN_BACKUP/firefox" "$OPN_BACKUP/librewolf" "$CNT_BACKUP/copy/"
printf 'ext.one\n' > "$CNT_BACKUP/copy/vscode/extensions.list"
printf 'NAME=%q\nDATE=%q\nMODULES=%q\n' "Counts" '2026-10-20 10:00:00' firefox,librewolf,vscode > "$CNT_BACKUP/copy/manifest.conf"
CNT_BIN="$TMP/cnt-bin"; mkdir -p "$CNT_BIN"
printf '#!/bin/sh\nsleep 4\n' > "$CNT_BIN/code"
# shellcheck disable=SC2016  # the stub's own shell expands $* and $@, not this one
printf '#!/bin/bash\ncase "$*" in *--progress*) sleep 1.5; exit 0 ;; esac\nexec "%s/zenity" "$@"\n' "$MOCK" > "$CNT_BIN/zenity"
chmod +x "$CNT_BIN/code" "$CNT_BIN/zenity"
cnt_run() {   # cnt_run LANG MODULES RUNNING_NAMES [slow] -> cnt_cap = the zenity capture
    local lang="$1" path="$OPN_STUB_BIN:$MOCK:/usr/bin:/bin"
    [ "${4:-}" != slow ] || path="$CNT_BIN:$OPN_STUB_BIN:$MOCK:/usr/bin:/bin"
    mkdir -p "$TMP/cnt-cfg-$lang/mint-setup"; printf '%s\n' "$lang" > "$TMP/cnt-cfg-$lang/mint-setup/language"
    rm -rf "$OPN_HOME"; cp -a "$OPN_EXIST" "$OPN_HOME"; : > "$OPN_PGLOG"
    cnt_cap="$TMP/cnt-$lang-$2-${4:-}"; rm -rf "$cnt_cap"
    SEQ=$(printf '2\n%s\n%s\n5\n' "$CNT_BACKUP/copy" "$2")
    HOME="$OPN_HOME" XDG_CONFIG_HOME="$TMP/cnt-cfg-$lang" MINT_SETUP_BACKUPS_DIR="$CNT_BACKUP" \
        PATH="$path" OPN_RUNNING="$3" OPN_PGLOG="$OPN_PGLOG" \
        ZENITY_CAPTURE="$cnt_cap" ZENITY_LIST_CHOICES="$SEQ" ZENITY_QUESTION_RC=0 LC_ALL=C.UTF-8 \
        timeout 60 bash "$SCRIPT" >/dev/null 2>"$cnt_cap.err" || fail "restore counts flow exited non-zero ($lang, $2)"
    [ ! -s "$cnt_cap.err" ] || fail "restore counts flow printed to stderr ($lang, $2): $(head -c 300 "$cnt_cap.err")"
}
for cnt_lang in es en; do
    if [ "$cnt_lang" = es ]; then
        cnt_one='Se completaron 1 de 2 módulo(s), pero fallaron: Firefox.'
        cnt_both='Se completaron 0 de 2 módulo\(s\), pero fallaron: (Firefox, LibreWolf|LibreWolf, Firefox)\.'
        cnt_cancel='Se completaron 0 de 2 módulo(s).'; cnt_q1='«'; cnt_q2='»'
    else
        cnt_one='Completed modules: 1 of 2, but these failed: Firefox.'
        cnt_both='Completed modules: 0 of 2, but these failed: (Firefox, LibreWolf|LibreWolf, Firefox)\.'
        cnt_cancel='Completed modules: 0 of 2.'; cnt_q1='“'; cnt_q2='”'
    fi
    cnt_run "$cnt_lang" firefox,librewolf firefox
    grep -q '^--warning ' "$cnt_cap/calls" || fail "restore counts ($cnt_lang): no warning with one module failed"
    grep -Fq -- "$cnt_one" "$cnt_cap/calls" || fail "restore counts ($cnt_lang): one of two failed, the dialog does not say '$cnt_one' (warning: $(grep -A4 '^--warning ' "$cnt_cap/calls" | tr '\n' '|' | head -c 400))"
    cnt_run "$cnt_lang" firefox,librewolf "firefox librewolf"
    grep -Eq -- "$cnt_both" "$cnt_cap/calls" || fail "restore counts ($cnt_lang): both failed, the dialog does not say 0 of 2 (warning: $(grep -A4 '^--warning ' "$cnt_cap/calls" | tr '\n' '|' | head -c 400))"
    cnt_run "$cnt_lang" firefox,vscode firefox slow
    grep -Fq -- "$cnt_cancel" "$cnt_cap/calls" || fail "restore counts ($cnt_lang): cancelled with one failed and one running, the dialog does not say '$cnt_cancel' (warning: $(grep -A4 '^--warning ' "$cnt_cap/calls" | tr '\n' '|' | head -c 400))"
    grep -Fq -- "${cnt_q1}VS Code${cnt_q2}" "$cnt_cap/calls" || fail "restore counts ($cnt_lang): the module in progress is not named as half-done"
    ! grep -Fq -- "${cnt_q1}Firefox${cnt_q2}" "$cnt_cap/calls" || fail "restore counts ($cnt_lang): the module that had already failed is named as half-done"
done
pass "restore dialogs: a failed module is not counted as completed (one of two, both, and cancelled with one failed) in es/en"

# 12.25: gsettings prints a string that contains an apostrophe between double
# quotes. save_wallpaper_uri only stripped single quotes, so such a wallpaper
# was skipped without a word (rc 0, nothing in the copy).
WPQ_ROOT="$TMP/wallpaper-quotes"
mkdir -p "$WPQ_ROOT/home/Pictures"
# Each case: file name => exactly what "gsettings get" prints (@P@ = Pictures folder).
cat > "$WPQ_ROOT/saved.txt" <<'CASES'
plain pic.jpg => 'file://@P@/plain%20pic.jpg'
Rob's pic.jpg => "file://@P@/Rob's%20pic.jpg"
it's "x".jpg => "file://@P@/it's%20\"x\".jpg"
a\b.jpg => 'file://@P@/a\\b.jpg'
Rob's a\b.jpg => "file://@P@/Rob's%20a\\b.jpg"
Fondo ñ.jpg => 'file://@P@/Fondo%20%C3%B1.jpg'
CASES
# Values that are not a file:// string: nothing is saved, and it is not an error.
cat > "$WPQ_ROOT/skipped.txt" <<'CASES'
empty =>
'' => ''
"" => ""
@s => @s ''
http => 'http://example.com/a.jpg'
missing => 'file://@P@/none.jpg'
unquoted => file://@P@/plain%20pic.jpg
mixed1 => 'file://@P@/plain%20pic.jpg"
mixed2 => "file://@P@/plain%20pic.jpg'
samechar => xfile://@P@/plain%20pic.jpgx
lone1 => '
lone2 => "
CASES
# shellcheck disable=SC2097,SC2098  # values taken from this shell are deliberately re-exported to the child
WPQ_OUT=$(HOME="$WPQ_ROOT/home" XDG_CONFIG_HOME="$WPQ_ROOT/config" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 \
    WPQ_ROOT="$WPQ_ROOT" bash -c '
source "$1"
pics="$HOME/Pictures"; out="$WPQ_ROOT/out"; wp_key=picture-uri; wp_val=""
xdg_dir() { printf "%s" "$HOME/Pictures"; }
gsettings() {
    if [ "$1" = set ]; then printf "%s\n" "$4" >> "$WPQ_ROOT/set-calls"; return 0; fi
    [ "$1" = get ] && [ "$3" = "$wp_key" ] || return 1
    printf "%s\n" "$wp_val"
}
fresh() { rm -rf "$out"; mkdir -p "$out"; }
nfiles() { find "$out" -type f | wc -l; }
while IFS= read -r line; do
    name="${line%% => *}"; wp_val="${line#* => }"; wp_val="${wp_val//@P@/$pics}"
    printf "img:%s" "$name" > "$pics/$name"; fresh; wp_key=picture-uri
    save_wallpaper_uri "$out" picture-uri ""; rc=$?
    if [ "$rc" -eq 0 ] && [ "$(cat "$out/wallpaper.filename" 2>/dev/null)" = "$name" ] \
        && [ "$(cat "$out/wallpaper-$name" 2>/dev/null)" = "img:$name" ] && [ "$(nfiles)" -eq 2 ]; then
        echo "OK saved: $name"
    else
        echo "BAD saved: $name (rc $rc, files: $(nfiles))"
    fi
done < "$WPQ_ROOT/saved.txt"
printf "img:plain" > "$pics/plain pic.jpg"
while IFS= read -r line; do
    name="${line%% =>*}"; wp_val="${line#*=>}"; wp_val="${wp_val# }"; wp_val="${wp_val//@P@/$pics}"
    fresh; save_wallpaper_uri "$out" picture-uri ""; rc=$?
    if [ "$rc" -eq 0 ] && [ "$(nfiles)" -eq 0 ]; then echo "OK skipped: $name"; else echo "BAD skipped: $name (rc $rc, files: $(nfiles))"; fi
done < "$WPQ_ROOT/skipped.txt"
# The dark variant goes through the same reader.
fresh; wp_key=picture-uri-dark; wp_val="\"file://$pics/Rob'"'"'s%20pic.jpg\""
save_wallpaper_uri "$out" picture-uri-dark "-dark"
if [ "$(cat "$out/wallpaper-dark.filename" 2>/dev/null)" = "Rob'"'"'s pic.jpg" ] && [ -f "$out/wallpaper-dark-Rob'"'"'s pic.jpg" ] && [ "$(nfiles)" -eq 2 ]; then echo "OK dark"; else echo "BAD dark"; fi
# Round trip: save, then restore points the key at an encoded copy of the same image.
fresh; wp_key=picture-uri; wp_val="\"file://$pics/Rob'"'"'s%20pic.jpg\""
save_wallpaper_uri "$out" picture-uri ""; : > "$WPQ_ROOT/set-calls"
restore_wallpaper_uri "$out" picture-uri ""; rc=$?
want="file://$pics/MintSetupWallpapers/Rob%27s%20pic.jpg"
if [ "$rc" -eq 0 ] && [ "$(cat "$WPQ_ROOT/set-calls")" = "$want" ] && [ "$(cat "$pics/MintSetupWallpapers/Rob'"'"'s pic.jpg")" = "img:Rob'"'"'s pic.jpg" ]; then echo "OK round trip"; else echo "BAD round trip ($(cat "$WPQ_ROOT/set-calls"))"; fi
' _ "$SCRIPT" 2>"$WPQ_ROOT/err")
[ "$(printf '%s\n' "$WPQ_OUT" | grep -c '^OK saved: ')" -eq 6 ] || fail "wallpaper save: not all 6 quoting forms were saved: $(printf '%s\n' "$WPQ_OUT" | grep -v '^OK' | head -5 | tr '\n' '|')"
[ "$(printf '%s\n' "$WPQ_OUT" | grep -c '^OK skipped: ')" -eq 12 ] || fail "wallpaper save: a value that is not a file:// string was not skipped cleanly: $(printf '%s\n' "$WPQ_OUT" | grep -v '^OK' | head -5 | tr '\n' '|')"
printf '%s\n' "$WPQ_OUT" | grep -Fxq 'OK dark' || fail "wallpaper save: the -dark variant with an apostrophe was not saved"
printf '%s\n' "$WPQ_OUT" | grep -Fxq 'OK round trip' || fail "wallpaper save/restore round trip with an apostrophe failed: $(printf '%s\n' "$WPQ_OUT" | grep -v '^OK' | head -3 | tr '\n' '|')"
! printf '%s\n' "$WPQ_OUT" | grep -q '^BAD' || fail "wallpaper save: $(printf '%s\n' "$WPQ_OUT" | grep '^BAD' | head -3 | tr '\n' '|')"
[ ! -s "$WPQ_ROOT/err" ] || fail "wallpaper save printed to stderr: $(head -c 200 "$WPQ_ROOT/err")"
pass "wallpaper save reads GVariant strings in single or double quotes (apostrophe, escapes, backslash, -dark, round trip)"

# 12.26: if the wallpaper image or its .filename marker could not be written,
# save_wallpaper_uri said nothing (or only a raw "mv:" error) and the module
# still counted as saved. A destination that is a folder makes the write fail
# for any user, root included.
WPF_ROOT="$TMP/wallpaper-save-failure"
mkdir -p "$WPF_ROOT/home/Pictures"
printf 'IMG' > "$WPF_ROOT/home/Pictures/pic.jpg"
wpf_run() {   # $1 = es|en, $2 = ok | image | marker | missing
    # shellcheck disable=SC2097,SC2098  # values taken from this shell are deliberately re-exported to the child
    HOME="$WPF_ROOT/home" XDG_CONFIG_HOME="$WPF_ROOT/config" MINT_SETUP_BACKUPS_DIR="$BACKUPS" MINT_SETUP_TEST=1 \
        WPF_ROOT="$WPF_ROOT" WPF_LANG="$1" WPF_SCEN="$2" bash -c '
source "$1"
set_language "$WPF_LANG"
out="$WPF_ROOT/out-$WPF_SCEN"; rm -rf "$out"; mkdir -p "$out"
SAVE_PROBLEMS_FILE="$WPF_ROOT/problems-$WPF_SCEN"; : > "$SAVE_PROBLEMS_FILE"
img="$HOME/Pictures/pic.jpg"
case "$WPF_SCEN" in
    image)   mkdir "$out/wallpaper-pic.jpg" ;;
    marker)  mkdir "$out/wallpaper-dark.filename" ;;
    missing) img="$HOME/Pictures/gone.jpg" ;;
esac
gsettings() { [ "$1" = get ] || return 1; printf "%s\n" "\"file://$img\"" | sed "s/\"/'"'"'/g"; }
save_wpf() { save_wallpaper_uri "$1" picture-uri ""; save_wallpaper_uri "$1" picture-uri-dark "-dark"; }
run_save_module wpf "$out"; rc=$?
printf "RC:%s\n" "$rc"
printf "PROBLEMS:%s\n" "$(tr "\n" "|" < "$SAVE_PROBLEMS_FILE")"
printf "FILES:%s\n" "$(cd "$out" && find . -type f | sort | tr "\n" "|")"
' _ "$SCRIPT" 2>&1
}
for wpf_lang in es en; do
    if [ "$wpf_lang" = es ]; then
        wpf_w() { printf 'Aviso: no se pudo guardar «%s» de forma íntegra (¿disco lleno o permisos?); se omite.' "$1"; }
    else
        wpf_w() { printf 'Warning: “%s” could not be saved intact (disk full or permissions?); skipped.' "$1"; }
    fi
    wpf_img="$WPF_ROOT/home/Pictures/pic.jpg"
    WPF_OUT=$(wpf_run "$wpf_lang" ok)
    [ "$WPF_OUT" = "$(printf 'RC:0\nPROBLEMS:\nFILES:./wallpaper-dark-pic.jpg|./wallpaper-dark.filename|./wallpaper-pic.jpg|./wallpaper.filename|')" ] \
        || fail "wallpaper save failure ($wpf_lang): the control run (nothing blocked) is not clean: $(printf '%s' "$WPF_OUT" | tr '\n' '|')"
    WPF_OUT=$(wpf_run "$wpf_lang" image)
    [ "$WPF_OUT" = "$(printf '%s\nRC:1\nPROBLEMS:%s|\nFILES:./wallpaper-dark-pic.jpg|./wallpaper-dark.filename|' "$(wpf_w "$wpf_img")" "$wpf_img")" ] \
        || fail "wallpaper save failure ($wpf_lang): image copy blocked, wrong result: $(printf '%s' "$WPF_OUT" | tr '\n' '|')"
    WPF_OUT=$(wpf_run "$wpf_lang" marker)
    wpf_mk="$WPF_ROOT/out-marker/wallpaper-dark.filename"
    [ "$WPF_OUT" = "$(printf '%s\nRC:1\nPROBLEMS:%s|\nFILES:./wallpaper-dark-pic.jpg|./wallpaper-pic.jpg|./wallpaper.filename|' "$(wpf_w "$wpf_mk")" "$wpf_mk")" ] \
        || fail "wallpaper save failure ($wpf_lang): marker blocked, wrong result: $(printf '%s' "$WPF_OUT" | tr '\n' '|')"
    WPF_OUT=$(wpf_run "$wpf_lang" missing)
    [ "$WPF_OUT" = "$(printf 'RC:0\nPROBLEMS:\nFILES:')" ] \
        || fail "wallpaper save failure ($wpf_lang): a wallpaper that no longer exists must be skipped quietly: $(printf '%s' "$WPF_OUT" | tr '\n' '|')"
done
pass "wallpaper save: a failed image or marker write is reported and fails the module (es/en); a missing image stays quiet"

# 12.36: zenity takes the rows of --list as positional arguments and rejects the
# WHOLE list ("This option is not available", nothing shown) if one starts with
# "-". The label of a copy starts with its name, so one copy named "-pc" left
# both pickers empty and silent: restore, compare, export and delete all
# became unreachable. The zenity of this test applies that rule (verified with
# the real zenity 4.0.1 under Xvfb): only the options these pickers use pass.
PKL_ROOT="$TMP/picker-dash"; PKL_BK="$PKL_ROOT/backups"
mkdir -p "$PKL_ROOT/bin" "$PKL_ROOT/home" "$PKL_BK"
cat > "$PKL_ROOT/bin/zenity" <<'ZEN'
#!/bin/bash
rows=(); checklist=0
for a in "$@"; do
    case "$a" in
        --list) ;;
        --checklist) checklist=1 ;;
        --title=*|--text=*|--width=*|--height=*|--column=*|--hide-column=*|--print-column=*|--separator=*) ;;
        -*) echo "This option is not available. Please see --help for all possible usages." >&2; exit 1 ;;
        *) rows+=("$a") ;;
    esac
done
printf '%s\n' "${rows[@]}" > "$PKL_LOG"
if [ "$checklist" -eq 1 ]; then
    for ((i = 1; i < ${#rows[@]}; i += 3)); do printf '%s\n' "${rows[i]}"; done
else
    printf '%s\n' "${rows[0]}"
fi
ZEN
chmod +x "$PKL_ROOT/bin/zenity"
pkl_copy() {   # pkl_copy DIR NAME DATE: a saved copy; the newest is listed first
    mkdir -p "$PKL_BK/$1"
    printf 'NAME=%q\nDATE=%q\nMODULES=terminal\n' "$2" "$3" > "$PKL_BK/$1/manifest.conf"
    touch -d "$3" "$PKL_BK/$1"
}
pkl_copy Normal_3 "Normal" "2026-01-03 00:00"
pkl_copy pc_1 "-pc" "2026-01-02 00:00"
pkl_copy x_2 "--x" "2026-01-01 00:00"
pkl_run() {   # pkl_run FUNCTION: what that picker prints, with the rows it sent in $PKL_ROOT/rows
    HOME="$PKL_ROOT/home" MINT_SETUP_BACKUPS_DIR="$PKL_BK" PATH="$PKL_ROOT/bin:$PATH" PKL_LOG="$PKL_ROOT/rows" \
        LC_ALL=C.UTF-8 MINT_SETUP_TEST=1 bash -c 'source "$1"; "$2" Test' _ "$SCRIPT" "$1" 2>/dev/null
}
PKL_OUT=$(pkl_run pick_backup_dir)
[ "$PKL_OUT" = "$PKL_BK/Normal_3" ] || fail "pick_backup_dir returned nothing or the wrong copy with copies named '-pc' and '--x' (got: $PKL_OUT)"
[ "$(wc -l < "$PKL_ROOT/rows")" -eq 6 ] || fail "pick_backup_dir did not list the 3 copies (rows: $(tr '\n' '|' < "$PKL_ROOT/rows"))"
PKL_LABELS=$(awk 'NR % 2 == 0' "$PKL_ROOT/rows")
[ "$(printf '%s\n' "$PKL_LABELS" | grep -c '^-')" -eq 0 ] || fail "pick_backup_dir sent a row that starts with '-': $(printf '%s' "$PKL_LABELS" | tr '\n' '|')"
printf '%s\n' "$PKL_LABELS" | sed -n 2p | grep -Fq ' -pc — 2026-01-02 00:00 (' || fail "pick_backup_dir: the row of '-pc' is not ' -pc — date (size)'"
printf '%s\n' "$PKL_LABELS" | sed -n 3p | grep -Fq ' --x — 2026-01-01 00:00 (' || fail "pick_backup_dir: the row of '--x' is not ' --x — date (size)'"
printf '%s\n' "$PKL_LABELS" | sed -n 1p | grep -q '^Normal — 2026-01-03 00:00 (' || fail "pick_backup_dir: an ordinary name was modified"
PKL_OUT=$(pkl_run pick_backup_dirs_multi)
[ "$PKL_OUT" = "$(printf '%s\n' "$PKL_BK/Normal_3" "$PKL_BK/pc_1" "$PKL_BK/x_2")" ] || fail "pick_backup_dirs_multi did not return the 3 copies (got: $(printf '%s' "$PKL_OUT" | tr '\n' '|'))"
[ "$(awk 'NR % 3 == 0' "$PKL_ROOT/rows" | grep -c '^-')" -eq 0 ] || fail "pick_backup_dirs_multi sent a row that starts with '-'"
cat > "$PKL_ROOT/cases.sh" <<'CASES'
cases=0; bad=0
check() {   # check NAME EXPECTED_LABEL
    local got; got=$(backup_row_label "$1" D S); cases=$((cases + 1))
    [ "$got" = "$2" ] && return 0
    bad=$((bad + 1)); printf 'BAD %q -> %q (expected %q)\n' "$1" "$got" "$2"
}
check "-pc" " -pc — D (S)"
check "--" " -- — D (S)"
check "-" " - — D (S)"
check "pc-" "pc- — D (S)"
check "a -b" "a -b — D (S)"
check "Configuración" "Configuración — D (S)"
check "" " — D (S)"
check $'-a\nb' $' -a\nb — D (S)'
check "−x" "−x — D (S)"      # U+2212 minus sign: not a hyphen for zenity
check "–x" "–x — D (S)"      # en dash
printf 'CASES=%s BAD=%s\n' "$cases" "$bad"
CASES
PKL_CASES=$(HOME="$PKL_ROOT/home" MINT_SETUP_BACKUPS_DIR="$PKL_BK" LC_ALL=C.UTF-8 MINT_SETUP_TEST=1 \
    bash -c 'source "$1"; source "$2"' _ "$SCRIPT" "$PKL_ROOT/cases.sh" 2>&1)
[ "$(printf '%s\n' "$PKL_CASES" | tail -1)" = "CASES=10 BAD=0" ] || fail "backup_row_label: $(printf '%s' "$PKL_CASES" | tr '\n' '|')"
pass "copy pickers: a copy named with a leading '-' stays a row (one leading space) and no longer empties the list"

# 12.37: "Delete saved configurations" (Advanced, option 3) ran rm -rf without
# looking at the result and always said "N configuration(s) deleted". A copy with
# a folder without write permission (copied from read-only media) was left half
# deleted, manifest.conf included, so it could not be listed again either.
# rm_backup_dir opens the folders first; what still cannot be deleted is named in
# a warning with the true count. The rm of this test refuses names ending in
# "_stuck" (works for root too).
DEL_ROOT="$TMP/delete-copies"; mkdir -p "$DEL_ROOT/bin"
cat > "$DEL_ROOT/bin/rm" <<'RM'
#!/bin/bash
for a in "$@"; do
    case "$a" in *_stuck) echo "rm: cannot remove '$a': Operation not permitted" >&2; exit 1 ;; esac
done
exec /bin/rm "$@"
RM
chmod +x "$DEL_ROOT/bin/rm"
del_copy() {   # del_copy NAME [ro]: a copy under $DEL_ROOT/b (with an unwritable folder if "ro")
    mkdir -p "$DEL_ROOT/b/$1"; printf 'NAME=%s\nDATE=d\nMODULES=terminal\n' "$1" > "$DEL_ROOT/b/$1/manifest.conf"
    if [ "${2:-}" = ro ]; then mkdir -p "$DEL_ROOT/b/$1/ro/sub"; printf x > "$DEL_ROOT/b/$1/ro/sub/f"; chmod 555 "$DEL_ROOT/b/$1/ro/sub" "$DEL_ROOT/b/$1/ro"; fi
}
del_run() {   # del_run LANG NAME...: do_advanced option 3 on those copies; results in $DEL_ROOT/out
    local lang="$1"; shift
    rm -rf "$DEL_ROOT/out"; mkdir -p "$DEL_ROOT/out"
    HOME="$HOME_DIR" MINT_SETUP_BACKUPS_DIR="$DEL_ROOT/b" PATH="$DEL_ROOT/bin:$PATH" LC_ALL=C.UTF-8 MINT_SETUP_TEST=1 \
        bash -c '
source "$1"; root=$2; set_language "$3"; lock=$4; shift 4
out="$root/out"; DIRS=(); for n in "$@"; do DIRS+=("$root/b/$n"); done
zenity() {
    local a kind=""
    for a in "$@"; do case "$a" in --list|--question|--info|--warning|--error) kind="${a#--}" ;; esac; done
    for a in "$@"; do case "$a" in --text=*) printf "%s" "${a#--text=}" >> "$out/$kind" ;; esac; done
    [ "$kind" != list ] || echo 3
    return 0
}
pick_backup_dirs_multi() { printf "%s\n" "${DIRS[@]}"; }
[ "$lock" -eq 0 ] || chmod 500 "$root/b"   # after loading: the program checks that folder at start
do_advanced; echo "RC:$?" > "$out/rc"
' _ "$SCRIPT" "$DEL_ROOT" "$lang" "${DEL_LOCK:-0}" "$@" >/dev/null 2>&1
}
del_out() { cat "$DEL_ROOT/out/$1" 2>/dev/null; }   # the text of one kind of dialog ("" if none)
# 12.57: the names listed by the confirmation and by the warning were joined with a "\n" inside double
# quotes, which bash does not expand, and entered T_FMT as DATA (%s): the dialog (--no-markup) showed
# "• a\n• b\n" on one line. They go one per line now, with no line break at the end. The expected texts
# are written out with real line breaks ($'...').
for del_lang in es en; do
    if [ "$del_lang" = es ]; then
        del_q() { printf '¿Eliminar definitivamente estas %s configuración(es) guardada(s)?\n\n%s' "$1" "$2"; }
        del_ok() { printf '%s configuración(es) eliminada(s).' "$1"; }
        del_w() { printf 'Se eliminaron %s de %s configuración(es). No se pudieron eliminar (sin permiso de escritura o disco de solo lectura):\n\n%s' "$1" "$2" "$3"; }
    else
        del_q() { printf 'Permanently delete %s saved configurations?\n\n%s' "$1" "$2"; }
        del_ok() { printf 'Saved configurations deleted: %s.' "$1"; }
        del_w() { printf 'Deleted %s of %s saved configurations. These could not be deleted (no write permission or read-only disk):\n\n%s' "$1" "$2" "$3"; }
    fi
    rm -rf "$DEL_ROOT/b"; del_copy Copia_a; del_copy Copia_b
    del_run "$del_lang" Copia_a Copia_b
    [ "$(del_out question)" = "$(del_q 2 $'• Copia_a\n• Copia_b')" ] || fail "delete copies ($del_lang): wrong confirmation: $(del_out question)"
    [ "$(del_out info)" = "$(del_ok 2)" ] && [ -z "$(del_out warning)" ] || fail "delete copies ($del_lang): control run is not a clean success: $(del_out info) / $(del_out warning)"
    { [ ! -e "$DEL_ROOT/b/Copia_a" ] && [ ! -e "$DEL_ROOT/b/Copia_b" ]; } || fail "delete copies ($del_lang): control copies were not deleted"
    # a copy with folders without write permission must go away completely
    rm -rf "$DEL_ROOT/b"; del_copy Copia_ro ro
    del_run "$del_lang" Copia_ro
    { [ "$(del_out info)" = "$(del_ok 1)" ] && [ -z "$(del_out warning)" ] && [ ! -e "$DEL_ROOT/b/Copia_ro" ]; } \
        || fail "delete copies ($del_lang): a copy with read-only folders was not deleted (info: $(del_out info); left: $(find "$DEL_ROOT/b" -mindepth 1 -maxdepth 1 -printf '%f '))"
    # one that cannot be deleted: honest count, named, the others still deleted
    rm -rf "$DEL_ROOT/b"; del_copy Copia_a; del_copy Copia_stuck; del_copy Copia_b
    del_run "$del_lang" Copia_a Copia_stuck Copia_b
    [ "$(del_out warning)" = "$(del_w 2 3 '• Copia_stuck')" ] || fail "delete copies ($del_lang): wrong partial-failure warning: $(del_out warning)"
    [ -z "$(del_out info)" ] || fail "delete copies ($del_lang): success notice shown after a failure: $(del_out info)"
    { [ ! -e "$DEL_ROOT/b/Copia_a" ] && [ ! -e "$DEL_ROOT/b/Copia_b" ] && [ -d "$DEL_ROOT/b/Copia_stuck" ]; } \
        || fail "delete copies ($del_lang): wrong set of copies left after a partial failure: $(find "$DEL_ROOT/b" -mindepth 1 -maxdepth 1 -printf '%f ')"
    # two that cannot be deleted: the warning names them one per line
    rm -rf "$DEL_ROOT/b"; del_copy Copia_a; del_copy Copia_stuck; del_copy Otra_stuck
    del_run "$del_lang" Copia_a Copia_stuck Otra_stuck
    [ "$(del_out warning)" = "$(del_w 1 3 $'• Copia_stuck\n• Otra_stuck')" ] || fail "delete copies ($del_lang): the names that failed are not one per line: $(del_out warning)"
    # every one fails: 0 of N, and the dialog is a warning, never an info
    rm -rf "$DEL_ROOT/b"; del_copy Copia_stuck
    del_run "$del_lang" Copia_stuck
    { [ "$(del_out warning)" = "$(del_w 0 1 '• Copia_stuck')" ] && [ -z "$(del_out info)" ] && [ -d "$DEL_ROOT/b/Copia_stuck" ]; } \
        || fail "delete copies ($del_lang): total failure reported wrongly: $(del_out warning) / $(del_out info)"
done
# Without root only: a folder that cannot be modified fails for real, not by the test rm.
if [ "$(id -u)" -ne 0 ]; then
    rm -rf "$DEL_ROOT/b"; del_copy Copia_a
    DEL_LOCK=1 del_run "$del_lang" Copia_a   # del_w is still the one of the last language
    chmod 700 "$DEL_ROOT/b"
    [ "$(del_out warning)" = "$(del_w 0 1 '• Copia_a')" ] && [ -z "$(del_out info)" ] && [ -d "$DEL_ROOT/b/Copia_a" ] \
        || fail "delete copies: a parent folder without write permission was reported as deleted: $(del_out warning) / $(del_out info)"
fi
chmod -R u+rwX "$DEL_ROOT" 2>/dev/null
pass "delete saved copies: read-only folders are opened first, a failure is reported with the true count (es/en)"
pass "delete saved copies: the confirmation and the warning list one name per line, without a literal \\n (es/en)"

printf 'All user-flow tests passed.\n'
