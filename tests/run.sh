#!/bin/bash
# Mint-Setup test orchestrator.
#
#   bash tests/run.sh                  run every suite
#   bash tests/run.sh --list           list the suites and exit
#   bash tests/run.sh --only NAME      run only suites whose file name contains NAME (repeatable)
#   bash tests/run.sh --skip NAME      skip suites whose file name contains NAME (repeatable)
#   bash tests/run.sh -v               stream suite output instead of showing it only on failure
#
# Every tests/test-*.sh runs in its own process, with the desktop/session
# variables removed so a real display or D-Bus session can never be reached.
# Suites are independent and build their own isolated HOME.
#
# Suite exit status: 0 = PASS, 77 = SKIP (automake convention), anything else = FAIL.
# A suite that passes but skipped some of its own checks (lines starting with SKIP) lists them under its result.
# Environment:
#   TEST_TIMEOUT   seconds per suite (default 900).
#   TEST_STRICT=1  a SKIP is a failure: a suite that exits 77 and a passing suite that prints SKIP
#                  lines both count as FAIL, so a missing tool cannot hide tests (CI sets it).
#                  Suites left out with --skip are not SKIPs. Default 0; any other value is a usage error.
# Exit status: 0 all suites passed or were skipped, 1 at least one failed, 2 usage error.

set -u

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

only=()
skip=()
verbose=0
list_only=0
while [ $# -gt 0 ]; do
    case "$1" in
        --list) list_only=1 ;;
        --only) [ $# -ge 2 ] || { echo "run.sh: --only needs a value" >&2; exit 2; }; only+=("$2"); shift ;;
        --skip) [ $# -ge 2 ] || { echo "run.sh: --skip needs a value" >&2; exit 2; }; skip+=("$2"); shift ;;
        -v|--verbose) verbose=1 ;;
        -h|--help) awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "run.sh: unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

strict=0
case "${TEST_STRICT:-0}" in
    0) ;;
    1) strict=1 ;;
    *) echo "run.sh: TEST_STRICT must be 0 or 1, not '$TEST_STRICT'" >&2; exit 2 ;;
esac

matches_any() {   # matches_any NAME PATTERN...
    local name="$1" p
    shift
    for p in "$@"; do
        case "$name" in *"$p"*) return 0 ;; esac
    done
    return 1
}

suites=()
for f in tests/test-*.sh; do
    [ -f "$f" ] || continue
    name="${f##*/}"
    if [ "${#only[@]}" -gt 0 ] && ! matches_any "$name" "${only[@]}"; then continue; fi
    if [ "${#skip[@]}" -gt 0 ] && matches_any "$name" "${skip[@]}"; then continue; fi
    suites+=("$f")
done

if [ "$list_only" -eq 1 ]; then
    printf '%s\n' "${suites[@]}"
    exit 0
fi
if [ "${#suites[@]}" -eq 0 ]; then
    echo "run.sh: no suites selected" >&2
    exit 2
fi

umask 022   # deterministic fixture modes for every suite

timeout_bin=""
command -v timeout >/dev/null 2>&1 && timeout_bin="timeout ${TEST_TIMEOUT:-900}"

passed=0; failed=0; skipped=0; strict_failed=0
failed_names=()
started=$SECONDS
workdir=$(mktemp -d) || exit 2
log="$workdir/suite.log"
trap 'rm -rf -- "$workdir"' EXIT

for suite in "${suites[@]}"; do
    t0=$SECONDS
    # Each suite gets a throw-away HOME as a safety net: even a careless test
    # can never create or modify anything in the contributor's real home.
    suite_home="$workdir/home-${suite##*/}"
    mkdir -p "$suite_home/.config"
    # shellcheck disable=SC2086  # $timeout_bin is intentionally two words
    env -u DISPLAY -u WAYLAND_DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u XDG_RUNTIME_DIR \
        -u MINT_SETUP_BACKUPS_DIR -u MINT_SETUP_TEST -u XDG_DATA_HOME -u XDG_CACHE_HOME \
        HOME="$suite_home" XDG_CONFIG_HOME="$suite_home/.config" \
        $timeout_bin bash "$suite" > "$log" 2>&1
    rc=$?
    elapsed=$((SECONDS - t0))
    skip_lines=$(grep -c '^SKIP' "$log")
    case "$rc" in
        0)  status=PASS ;;
        77) status=SKIP ;;
        *)  status=FAIL ;;
    esac
    strict_skip=0
    if [ "$strict" -eq 1 ] && [ "$status" != FAIL ] && { [ "$rc" -eq 77 ] || [ "$skip_lines" -gt 0 ]; }; then
        status=FAIL; strict_skip=1; strict_failed=$((strict_failed + 1))
    fi
    case "$status" in
        PASS) passed=$((passed + 1)) ;;
        SKIP) skipped=$((skipped + 1)) ;;
        *)    failed=$((failed + 1)); failed_names+=("$suite") ;;
    esac
    printf '%-4s  %-40s %3ss\n' "$status" "${suite#tests/}" "$elapsed"
    if [ "$strict_skip" -eq 1 ]; then
        printf '      | TEST_STRICT=1: a SKIP counts as a failure\n'
    fi
    if [ "$verbose" -eq 1 ] || { [ "$status" = FAIL ] && [ "$strict_skip" -eq 0 ]; }; then
        if [ "$verbose" -eq 0 ]; then   # FAIL lines first: PASS lines after them push them out of the tail
            fails=$(awk '/^PASS: /{p=0} /^FAIL: /{p=1} p' "$log" | head -n 60)
            if [ -n "$fails" ]; then
                printf '      | -- FAIL lines --\n'
                printf '%s\n' "$fails" | sed 's/^/      | /'
                printf '      | -- last 40 lines --\n'
            fi
        fi
        sed 's/^/      | /' "$log" | tail -n "$([ "$verbose" -eq 1 ] && echo 400 || echo 40)"
    elif [ "$skip_lines" -gt 0 ]; then   # a SKIP suite, or a passing one that skipped some checks
        sed -n '/^SKIP/p' "$log" | head -5 | sed 's/^/      | /'
    fi
done

printf '\n%d passed, %d failed, %d skipped (%d suites, %ds)\n' \
    "$passed" "$failed" "$skipped" "${#suites[@]}" "$((SECONDS - started))"
if [ "$failed" -gt 0 ]; then
    printf 'Failed: %s\n' "${failed_names[*]}" >&2
    if [ "$strict_failed" -gt 0 ]; then
        printf 'TEST_STRICT=1: %d of them failed only because they skipped checks\n' "$strict_failed" >&2
    fi
    exit 1
fi
exit 0
