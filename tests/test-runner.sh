#!/bin/bash
# Tests for the orchestrator itself (tests/run.sh): result accounting, --only / --skip and
# TEST_STRICT (12.61). Each case copies the real run.sh next to fake suites in a throw-away tree.
set -u
umask 022   # fixture modes must not depend on the contributor's umask

# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ms_init

FAKE="$TMP/fake"
OUT="" ERR="" RC=0

# new_tree: an empty tests/ folder holding only the real run.sh.
new_tree() {
    rm -rf -- "$FAKE"
    mkdir -p "$FAKE/tests"
    cp -- "$ROOT/tests/run.sh" "$FAKE/tests/run.sh"
}

# suite NAME BODY: a fake suite tests/test-NAME.sh.
suite() { printf '#!/bin/bash\n%s\n' "$2" > "$FAKE/tests/test-$1.sh"; }

# run_runner STRICT [ARG...]: STRICT is the value given to TEST_STRICT ("-" leaves it unset).
# Sets OUT (stdout), ERR (stderr) and RC.
run_runner() {
    local strict="$1" pre
    shift
    pre=(env -u TEST_TIMEOUT)
    if [ "$strict" = - ]; then pre+=(-u TEST_STRICT); else pre+=(TEST_STRICT="$strict"); fi
    RC=0
    OUT=$("${pre[@]}" bash "$FAKE/tests/run.sh" "$@" 2>"$TMP/err") || RC=$?
    ERR=$(cat -- "$TMP/err")
}

# status_of NAME: the PASS / SKIP / FAIL word printed for tests/test-NAME.sh.
status_of() { printf '%s\n' "$OUT" | awk -v n="test-$1.sh" '$2 == n { print $1; exit }'; }
# summary: the totals line without the elapsed time.
summary() { printf '%s\n' "$OUT" | sed -n -E 's/^([0-9]+ passed.*), [0-9]+s\)$/\1)/p'; }
has_out() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
has_err() { printf '%s\n' "$ERR" | grep -qF -- "$1"; }
# check DESCRIPTION EXPECTED ACTUAL
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

NOTE='TEST_STRICT=1: a SKIP counts as a failure'

# --- Without TEST_STRICT: the accounting stays what it was ---------------------------------------
new_tree
suite pass 'echo "PASS: one"'
suite skipsuite 'echo "SKIP: needs a tool"; exit 77'
suite skipline 'echo "PASS: one"; echo "SKIP: one check needs root"'
for v in - 0 ""; do
    run_runner "$v"
    label="TEST_STRICT=${v:-empty}"; [ "$v" = - ] && label="TEST_STRICT unset"
    check "$label: exit 0" 0 "$RC"
    check "$label: totals" "2 passed, 0 failed, 1 skipped (3 suites)" "$(summary)"
    check "$label: suite statuses" "PASS SKIP PASS" "$(status_of pass) $(status_of skipsuite) $(status_of skipline)"
    if has_out 'SKIP: needs a tool' && has_out 'SKIP: one check needs root'; then
        pass "$label: both SKIP reasons are listed"
    else fail "$label: both SKIP reasons are listed"; fi
    if has_out 'TEST_STRICT' || has_err 'TEST_STRICT'; then fail "$label: says nothing about TEST_STRICT"
    else pass "$label: says nothing about TEST_STRICT"; fi
done
suite fail 'echo "FAIL: broken" >&2; exit 1'
run_runner -
check "a real failure: exit 1" 1 "$RC"
check "a real failure: totals" "2 passed, 1 failed, 1 skipped (4 suites)" "$(summary)"
if has_err 'Failed: tests/test-fail.sh' && ! has_err 'TEST_STRICT'; then pass "a real failure: named, with no strict note"
else fail "a real failure: named, with no strict note"; fi

# --- TEST_STRICT=1: a SKIP is a failure -----------------------------------------------------------
new_tree
suite pass 'echo "PASS: one"'
run_runner 1
check "strict, all suites pass: exit 0" 0 "$RC"
check "strict, all suites pass: totals" "1 passed, 0 failed, 0 skipped (1 suites)" "$(summary)"
if [ -z "$ERR" ] && ! has_out 'TEST_STRICT'; then pass "strict, all suites pass: no strict note"
else fail "strict, all suites pass: no strict note"; fi

suite skipsuite 'echo "SKIP: needs a tool"; exit 77'
suite skipline 'echo "PASS: one"; echo "SKIP: one check needs root"'
suite silent77 'exit 77'
run_runner 1
check "strict, skipped suites: exit 1" 1 "$RC"
check "strict, skipped suites: totals" "1 passed, 3 failed, 0 skipped (4 suites)" "$(summary)"
check "strict, skipped suites: statuses" "PASS FAIL FAIL FAIL" \
    "$(status_of pass) $(status_of silent77) $(status_of skipline) $(status_of skipsuite)"
if has_out 'SKIP: needs a tool' && has_out 'SKIP: one check needs root'; then pass "strict: the SKIP reasons are listed"
else fail "strict: the SKIP reasons are listed"; fi
check "strict: a note under each of the 3 failures" 3 "$(printf '%s\n' "$OUT" | grep -cF -- "$NOTE")"
if has_err 'Failed: tests/test-silent77.sh tests/test-skipline.sh tests/test-skipsuite.sh' \
    && has_err 'TEST_STRICT=1: 3 of them failed only because they skipped checks'; then
    pass "strict: the failed suites and the count of SKIP failures go to stderr"
else fail "strict: the failed suites and the count of SKIP failures go to stderr"; fi

run_runner 1 -v
check "strict with -v: exit 1" 1 "$RC"
check "strict with -v: a note under each of the 3 failures" 3 "$(printf '%s\n' "$OUT" | grep -cF -- "$NOTE")"

# A real failure next to a SKIP: only the SKIP is counted as "failed only because they skipped".
new_tree
suite fail 'echo "FAIL: broken" >&2; exit 1'
suite skipsuite 'echo "SKIP: needs a tool"; exit 77'
run_runner -
check "default, failure and SKIP: totals" "0 passed, 1 failed, 1 skipped (2 suites)" "$(summary)"
run_runner 1
check "strict, failure and SKIP: exit 1" 1 "$RC"
check "strict, failure and SKIP: totals" "0 passed, 2 failed, 0 skipped (2 suites)" "$(summary)"
if has_err 'Failed: tests/test-fail.sh tests/test-skipsuite.sh' \
    && has_err 'TEST_STRICT=1: 1 of them failed only because they skipped checks'; then
    pass "strict, failure and SKIP: only the SKIP is counted as a strict failure"
else fail "strict, failure and SKIP: only the SKIP is counted as a strict failure"; fi
check "strict, failure and SKIP: a real failure has no strict note" 1 "$(printf '%s\n' "$OUT" | grep -cF -- "$NOTE")"

# A failing suite that also skipped something is a plain failure, not a strict one.
new_tree
suite skipfail 'echo "SKIP: one check"; echo "FAIL: broken" >&2; exit 1'
run_runner 1
check "strict, failing suite with a SKIP: exit 1" 1 "$RC"
check "strict, failing suite with a SKIP: totals" "0 passed, 1 failed, 0 skipped (1 suites)" "$(summary)"
if has_err 'Failed: tests/test-skipfail.sh' && ! has_err 'TEST_STRICT' && ! has_out 'TEST_STRICT'; then
    pass "strict, failing suite with a SKIP: no strict note"
else fail "strict, failing suite with a SKIP: no strict note"; fi

# The reason of a SKIP is a SKIP line, usually far above the end of the log: that line is listed,
# not the tail of the log.
new_tree
suite longlog 'echo "SKIP: early reason"; seq 1 60 | sed "s/^/PASS: filler /"'
for v in - 1; do
    run_runner "$v"
    label="long log, TEST_STRICT=${v/-/unset}"
    if has_out 'SKIP: early reason' && ! has_out 'PASS: filler'; then pass "$label: the SKIP line is listed, not the log tail"
    else fail "$label: the SKIP line is listed, not the log tail"; fi
done
check "long log, strict: FAIL" FAIL "$(status_of longlog)"

# Only a line that starts with SKIP is a skipped check.
new_tree
suite mentions 'echo "PASS: SKIP is only mentioned here"; echo "  SKIP indented"; echo "NOSKIP: x"; echo "PASS: SKIPPED is not at the start"'
run_runner 1
check "strict, SKIP not at the start of a line: exit 0" 0 "$RC"
check "strict, SKIP not at the start of a line: PASS" PASS "$(status_of mentions)"

# --skip and --only choose the suites; leaving one out is not a SKIP.
new_tree
suite pass 'echo "PASS: one"'
suite skipsuite 'echo "SKIP: needs a tool"; exit 77'
suite skipline 'echo "PASS: one"; echo "SKIP: one check needs root"'
run_runner 1 --skip skipsuite --skip skipline
check "strict with --skip: exit 0" 0 "$RC"
check "strict with --skip: totals" "1 passed, 0 failed, 0 skipped (1 suites)" "$(summary)"
run_runner 1 --only skipline
check "strict with --only on a SKIP: exit 1" 1 "$RC"
run_runner 1 --only pass
check "strict with --only on a PASS: exit 0" 0 "$RC"
run_runner 1 --list
check "strict with --list: exit 0" 0 "$RC"
check "strict with --list: the three suites" "tests/test-pass.sh tests/test-skipline.sh tests/test-skipsuite.sh" \
    "$(printf '%s\n' "$OUT" | tr '\n' ' ' | sed 's/ $//')"

# --- A value that is not 0 or 1 is a usage error, and nothing runs ---------------------------------
for v in yes true 2 -1 " 1" 01; do
    run_runner "$v"
    check "TEST_STRICT='$v': exit 2" 2 "$RC"
    if has_err "TEST_STRICT must be 0 or 1, not '$v'" && [ -z "$OUT" ]; then pass "TEST_STRICT='$v': refused before any suite runs"
    else fail "TEST_STRICT='$v': refused before any suite runs"; fi
done
run_runner yes --list
check "TEST_STRICT=yes with --list: exit 2" 2 "$RC"
run_runner yes --help
if [ "$RC" -eq 0 ] && has_out 'Mint-Setup test orchestrator'; then pass "TEST_STRICT=yes with --help: the help is still shown"
else fail "TEST_STRICT=yes with --help: the help is still shown"; fi

# --- --help documents the variable ---------------------------------------------------------------
run_runner - --help
if has_out 'TEST_STRICT=1' && has_out 'TEST_TIMEOUT'; then pass "--help documents TEST_STRICT and TEST_TIMEOUT"
else fail "--help documents TEST_STRICT and TEST_TIMEOUT"; fi

ms_finish
