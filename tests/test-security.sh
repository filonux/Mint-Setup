#!/bin/bash
# Security suite: guards that must hold for every future change. Static checks
# scan the program source (comments excluded); dynamic checks run it in the
# sandbox. Each static pattern is paired with a positive control, so a check can
# never pass just because its regex stopped matching anything.
#
# Permission modes of real backups (700/600) and manifest values parsed as data
# are covered end to end in test-user-flow.sh; this suite covers the rest.
# shellcheck disable=SC2016  # control samples and ms_lib payloads are intentionally single-quoted
set -u
umask 022   # fixture modes must not depend on the contributor's umask

# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
ms_init

# Program source without full-line comments.
CODE="$TMP/code.sh"
grep -vE '^[[:space:]]*#' "$SCRIPT" > "$CODE"

# no_match NAME REGEX SAMPLE: REGEX must match SAMPLE (control) and nothing in the code.
no_match() {
    local name="$1" regex="$2" sample="$3" hits
    if ! printf '%s\n' "$sample" | grep -Eq -- "$regex"; then
        fail "$name (control pattern does not match its sample)"
        return
    fi
    if hits=$(grep -nE -- "$regex" "$CODE" | head -3) && [ -n "$hits" ]; then
        fail "$name: $(printf '%s' "$hits" | cut -c1-120 | head -1)"
    else
        pass "$name"
    fi
}

# --- Static: dangerous constructs ---------------------------------------------
no_match "no eval in the program" \
    '(^|[;&|({[:space:]])eval([[:space:]]|$)' \
    'x=1; eval "$cmd"'
no_match "sudo is never executed (privileges go through pkexec)" \
    '(^|[;&|(])[[:space:]]*sudo[[:space:]]' \
    '    sudo apt-get install foo'
no_match "no fixed /tmp, /var/tmp or /dev/shm paths" \
    '(/tmp|/var/tmp|/dev/shm)([/"[:space:]]|$)' \
    'out=/tmp/mint-setup.log'
no_match "no PID-based temporary names" \
    '(/|\.)[A-Za-z_-]*\$\$' \
    'f="$dir/work.$$"'
no_match "no bare .tmp / .part siblings (temporaries come from mktemp)" \
    '"\$[A-Za-z_{}]+\.(tmp|part)"' \
    'tmp="$dest.tmp"'

# --- Static: privileged calls go through prun ---------------------------------
# prun is the only place that runs pkexec: under flock, and with
# --disable-internal-agent (without it pkexec falls back to a text prompt on the
# terminal that never validates). The dynamic suites trace the calls they reach
# (test-privileged-invariance.sh, the LUKS block of test-robustness.sh); the source
# is scanned for the rest (save_docker, the repository copy, usermod, root_preauth,
# prun's fallback branch). A call is "pkexec" in command position or after a quoted
# or variable argument (atomic_capture "$dest" pkexec ...); messages, "command -v
# pkexec" and file names are not. Not seen: pkexec behind options (env A=1 pkexec,
# timeout 5 pkexec), behind a variable ("$pk") or an alias.
PK_ALLOWED='flock "$PKEXEC_LOCK" pkexec --disable-internal-agent'
PK_CALL="((^|[;&|({!])[[:space:]]*pkexec|(^|[[:space:]])(if|while|until|then|do|else|elif|exec|command|nohup|timeout|xargs)[[:space:]]+pkexec|([\"'}]|\\\$[A-Za-z_][A-Za-z0-9_]*)[[:space:]]+pkexec)([[:space:]]|\$)"

pk_scan() {   # pk_scan FILE: numbered lines that run pkexec, minus prun's own flagged call
    awk -v ok="$PK_ALLOWED" '{ while ((i = index($0, ok)) > 0) $0 = substr($0, 1, i - 1) substr($0, i + length(ok)); print }' "$1" |
        grep -nE -- "$PK_CALL"
}
pk_sample() {   # pk_sample hit|miss 'line': the scan must (not) flag this line
    printf '%s\n' "$2" > "$TMP/pk-sample"
    if pk_scan "$TMP/pk-sample" >/dev/null; then [ "$1" = hit ]; else [ "$1" = miss ]; fi
}
pk_bad=""
while IFS= read -r line; do pk_sample hit "$line" || pk_bad="$pk_bad [hit: $line]"; done <<'SAMPLES'
pkexec true
    pkexec bash -c 'x'
if pkexec true; then
if ! pkexec true; then
ok && pkexec true
ok || pkexec true
a; pkexec true
x=$(pkexec cat /etc/f)
cat f | pkexec tee /etc/f
{ pkexec true; }
then pkexec true
exec pkexec true
command pkexec true
atomic_capture "$dir/daemon.json" pkexec cat /etc/docker/daemon.json
atomic_capture 'x' pkexec cat /etc/f
flock $LOCK pkexec true
flock "$PKEXEC_LOCK" pkexec "$@" </dev/null
flock "$PKEXEC_LOCK" pkexec --user root "$@" </dev/null
pkexec --disable-internal-agent true
SAMPLES
while IFS= read -r line; do pk_sample miss "$line" || pk_bad="$pk_bad [miss: $line]"; done <<'SAMPLES'
command -v pkexec >/dev/null 2>&1 || return 1
if ! command -v pkexec >/dev/null 2>&1; then
log_msg "$(T "Aviso: pkexec no está disponible; instala los paquetes a mano.")"
msg_error "$(T "pkexec no está disponible; no se puede leer el dispositivo.")"
add_exact "pkexec no está disponible" "pkexec is not available"
add_exact "Aviso: sin permisos y pkexec no disponible" "Warning: no pkexec"
PKEXEC_LOCK="$PKEXEC_LOCK_DIR/.${APP_NAME}-pkexec.lock"
rm -f -- "$cache/.${APP_NAME}-pkexec.lock"
rm -f x   # pkexec leftovers
flock "$PKEXEC_LOCK" pkexec --disable-internal-agent "$@" </dev/null
flock "$PKEXEC_LOCK" pkexec --disable-internal-agent "$@" </dev/null 2>"$err" || rc=$?
SAMPLES
if [ -z "$pk_bad" ]; then pass "pkexec scan: every call form is flagged and no message or file name is (controls)"
else fail "pkexec scan controls:$pk_bad"; fi

if [ "$(grep -cF -- "$PK_ALLOWED" "$CODE")" -ge 1 ]; then pass "prun still runs pkexec under flock with --disable-internal-agent"
else fail "prun no longer contains: $PK_ALLOWED"; fi
if hits=$(pk_scan "$CODE" | head -3) && [ -n "$hits" ]; then
    fail "pkexec runs outside prun, or prun lost its flock or flag: $(printf '%s' "$hits" | cut -c1-120 | head -1)"
else pass "pkexec runs only inside prun, under flock and with --disable-internal-agent"; fi

# The scan against the real source: each privileged call turned back into a direct
# pkexec, and each pkexec line of prun without its flag or its flock, must be flagged.
pk_mut() {   # pk_mut LINE SED_SCRIPT: the program source with that sed edit on LINE only
    sed "$1$2" "$CODE" > "$TMP/pk-mut"
    pk_scan "$TMP/pk-mut" | grep -q "^$1:"
}
pk_sites=$(grep -nE '(^|[^[:alnum:]_.-])prun[[:space:]]' "$CODE" | cut -d: -f1)
pk_locks=$(grep -nF -- "$PK_ALLOWED" "$CODE" | cut -d: -f1)
pk_missed=""
for n in $pk_sites; do pk_mut "$n" 's/\bprun\b/pkexec/' || pk_missed="$pk_missed prun@$n"; done
for n in $pk_locks; do
    pk_mut "$n" 's/ --disable-internal-agent//' || pk_missed="$pk_missed noflag@$n"
    pk_mut "$n" 's/flock "$PKEXEC_LOCK" //' || pk_missed="$pk_missed noflock@$n"
done
if [ -n "$pk_sites" ] && [ -z "$pk_missed" ]; then
    pass "pkexec scan flags each of the $(printf '%s\n' "$pk_sites" | wc -l) privileged call sites turned into pkexec, and prun without its flag or flock"
else fail "pkexec scan missed a mutated call:${pk_missed:- (no prun call site found)}"; fi

# --- Static: required hardening ----------------------------------------------
if grep -qE '^umask 077$' "$SCRIPT"; then pass "umask 077 is set at top level"; else fail "umask 077 is missing at top level"; fi
if grep -qE '^set -uo pipefail$' "$SCRIPT"; then pass "set -uo pipefail is enabled"; else fail "set -uo pipefail is missing"; fi
if grep -qE 'mktemp' "$CODE"; then pass "temporary files are created with mktemp"; else fail "mktemp is never used"; fi

# --- Dynamic: umask and file modes --------------------------------------------
mask=$(ms_lib 'umask' 2>/dev/null)
if [ "$mask" = 0077 ]; then pass "sourcing the program leaves umask 0077"; else fail "umask after sourcing is '$mask', expected 0077"; fi

target="$HOME_DIR/private-check/file.conf"
mkdir -p "$HOME_DIR/private-check"
if ms_lib 'printf "secret\n" | atomic_write "$1"' "$target" && [ -f "$target" ]; then
    mode=$(stat -c %a "$target")
    if [ "$mode" = 600 ]; then pass "atomic_write creates new files with mode 600"; else fail "atomic_write created mode $mode, expected 600"; fi
else
    fail "atomic_write did not create the file"
fi
leftovers=$(find "$HOME_DIR/private-check" -mindepth 1 ! -name file.conf | wc -l)
if [ "$leftovers" -eq 0 ]; then pass "atomic_write leaves no temporary files behind"; else fail "atomic_write left $leftovers temporary file(s)"; fi

# --- Dynamic: tar_archive_is_safe ---------------------------------------------
# Every saved archive goes through this check before it is extracted. It rejects absolute
# names and ".." components, and an archive that cannot be listed to the end (truncated,
# corrupt, not gzip). The restore tests above it pass even with the check removed, because
# GNU tar refuses ".." members by itself and strips a leading "/" without complaint, so the
# verdicts are pinned here directly. Archives are written with `tar -P --no-recursion`, which
# stores every name exactly as given (the warnings tar prints about them are discarded).
TS_BASE="$TMP/tarcheck"; TS_SRC="$TS_BASE/src"; TS_OUT="$TS_BASE/out"
mkdir -p "$TS_SRC/a/b" "$TS_SRC/dir" "$TS_SRC/dir con espacios" "$TS_SRC/a..b" "$TS_SRC/..." "$TS_SRC/n"$'\n'"l" "$TS_OUT"
for f in b dir/f 'dir con espacios/ñandú.txt' ..foo foo.. 'a..b/c' .../x "n"$'\n'"l/c" a/b.txt; do : > "$TS_SRC/$f"; done
: > "$TS_BASE/up"; : > "$TS_BASE/abs"
head -c 20000 /dev/urandom > "$TS_SRC/blob"   # incompressible: a truncation cuts the middle of the stream

ts_mk() {   # ts_mk NAME member... -> $TS_OUT/NAME.tar.gz
    local name="$1"
    shift
    (cd "$TS_SRC" && tar -c --no-recursion -zPf "$TS_OUT/$name.tar.gz" -- "$@") 2>/dev/null
}
ts_verdict() { ms_lib 'tar_archive_is_safe "$1"' "$1" >/dev/null 2>&1; }   # 0 = accepted
ts_accepts() {   # ts_accepts "what" NAME
    if ! tar -tzf "$TS_OUT/$2.tar.gz" >/dev/null 2>&1; then fail "tar_archive_is_safe: $1 (fixture is not a valid archive)"
    elif ts_verdict "$TS_OUT/$2.tar.gz"; then pass "tar_archive_is_safe accepts $1"
    else fail "tar_archive_is_safe rejected $1"; fi
}
ts_rejects() {   # ts_rejects "what" NAME: a well-formed archive that only the NAMES make unsafe
    if ! tar -tzf "$TS_OUT/$2.tar.gz" >/dev/null 2>&1; then fail "tar_archive_is_safe: $1 (fixture is not a valid archive)"
    elif ts_verdict "$TS_OUT/$2.tar.gz"; then fail "tar_archive_is_safe accepted $1"
    else pass "tar_archive_is_safe rejects $1"; fi
}
ts_rejects_broken() {   # ts_rejects_broken "what" FILE: tar itself cannot read it to the end
    if tar -tzf "$2" >/dev/null 2>&1; then fail "tar_archive_is_safe: $1 (fixture is readable)"
    elif ts_verdict "$2"; then fail "tar_archive_is_safe accepted $1"
    else pass "tar_archive_is_safe rejects $1"; fi
}

ts_mk plain dir/f a/b.txt b
ts_accepts "plain relative names (control)" plain
ts_mk dotslash ./dir/f ./b
ts_accepts 'names starting with "./"' dotslash
ts_mk lookalikes ..foo foo.. a..b/c ... .../x
ts_accepts 'names that only look like ".." (..foo foo.. a..b/c ... .../x)' lookalikes
ts_mk spaces 'dir con espacios/ñandú.txt'
ts_accepts "spaces and accents in a name" spaces
ts_mk newline "n"$'\n'"l/c"
ts_accepts "a newline inside a name" newline
head -c 10240 /dev/zero | gzip -c > "$TS_OUT/empty-valid.tar.gz"
ts_accepts "a valid archive with no members" empty-valid

ts_mk up-first ../up b
ts_rejects '".." as the first component' up-first
ts_mk up-dot ./../up b
ts_rejects '".." after "./"' up-dot
ts_mk up-middle a/../b dir/f
ts_rejects '".." in the middle of a name' up-middle
ts_mk up-end a/b/.. dir/f
ts_rejects '".." as the last component' up-end
ts_mk up-only .. dir/f
ts_rejects 'a member named ".."' up-only
ts_mk absolute "$TS_BASE/abs" b
ts_rejects "an absolute path" absolute
ts_mk bad-last dir/f a/b.txt b a/../b
ts_rejects 'a ".." member after several good ones' bad-last
ts_mk bad-newline "n"$'\n'"l/../b"
ts_rejects '".." right after a name with a newline' bad-newline

ts_mk big blob b
ts_size=$(stat -c %s "$TS_OUT/big.tar.gz")
ts_accepts "a larger valid archive (control for the damaged copies)" big
head -c $(( ts_size * 6 / 10 )) "$TS_OUT/big.tar.gz" > "$TS_OUT/truncated.tar.gz"
ts_rejects_broken "a truncated archive" "$TS_OUT/truncated.tar.gz"
cp -- "$TS_OUT/big.tar.gz" "$TS_OUT/bad-crc.tar.gz"
ts_crc_byte=$(tail -c 6 "$TS_OUT/big.tar.gz" | head -c 1 | od -An -tu1 | tr -d ' ')
printf '%b' "\\0$(printf '%03o' $(( 255 - ts_crc_byte )))" | dd of="$TS_OUT/bad-crc.tar.gz" bs=1 seek=$(( ts_size - 6 )) conv=notrunc 2>/dev/null
ts_rejects_broken "an archive whose gzip checksum is wrong (every name still lists fine)" "$TS_OUT/bad-crc.tar.gz"
(cd "$TS_SRC" && tar -c --no-recursion -f "$TS_OUT/not-gzip.tar.gz" -- dir/f b) 2>/dev/null
ts_rejects_broken "a plain tar that is not gzip" "$TS_OUT/not-gzip.tar.gz"
: > "$TS_OUT/zero-bytes.tar.gz"
ts_rejects_broken "an empty file" "$TS_OUT/zero-bytes.tar.gz"
if ts_verdict "$TS_OUT/missing.tar.gz"; then fail "tar_archive_is_safe accepted a missing file"; else pass "tar_archive_is_safe rejects a missing file"; fi

# --- Dynamic: root guard ------------------------------------------------------
# Control: an unprivileged user reaches normal behavior.
if ms_app --version >/dev/null 2>&1; then pass "unprivileged --version runs (control)"; else fail "unprivileged --version failed"; fi

ms_env_set MS_FAKE_UID 0
rm -rf -- "$ZEN" "$BACKUPS"
root_out=$(ms_app 2>&1); root_rc=$?
if [ "$root_rc" -eq 1 ]; then pass "running as root exits with status 1"; else fail "root run exited with $root_rc, expected 1"; fi
if grep -q -- '--error' "$ZEN/calls" 2>/dev/null || printf '%s' "$root_out" | grep -qi 'root'; then
    pass "root run explains the refusal"
else
    fail "root run gave no explanation"
fi
if [ ! -e "$BACKUPS" ]; then pass "root run creates no backup directory"; else fail "root run created $BACKUPS"; fi

# Zenity installed but unusable (no display, e.g. over SSH): the refusal must
# still reach stderr instead of vanishing with exit status 1.
ms_stub zenity 'exit 1'
root_err=$(ms_app 2>&1 >/dev/null); root_rc=$?
if [ "$root_rc" -eq 1 ] && printf '%s' "$root_err" | grep -qi 'root'; then
    pass "root refusal reaches stderr when Zenity cannot open a dialog"
else
    fail "root refusal was silent with a failing Zenity (rc=$root_rc)"
fi

ms_finish
