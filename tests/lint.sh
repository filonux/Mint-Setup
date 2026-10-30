#!/bin/bash
# Mint-Setup static-analysis gate.
#
#   bash tests/lint.sh
#
# Checks, in order:
#   1. bash -n on every shell script.
#   2. ShellCheck on every shell script (SHELLCHECK_BIN, or "shellcheck" in PATH).
#   3. File hygiene on text files: LF only, no BOM, valid UTF-8, no tabs,
#      no trailing whitespace, final newline.
#   4. File modes: no file is executable (git would record 100755), except EXEC_OK.
#   5. YAML syntax of everything under .github/ (needs python3 + PyYAML).
#
# Environment:
#   SHELLCHECK_BIN   ShellCheck binary to use.
#   LINT_STRICT=1    Fail when ShellCheck is missing or not the pinned version,
#                    or when PyYAML is missing (CI sets this).
#
# Exit status: 0 clean, 1 findings, 2 usage/environment error.

set -u

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

EXPECTED_SHELLCHECK="0.11.0"
EXEC_OK=(script/mint-setup.sh)   # the program: executable or not, the README covers both
SHELLCHECK_BIN="${SHELLCHECK_BIN:-shellcheck}"
STRICT="${LINT_STRICT:-0}"
problems=0

bad() { printf 'LINT: %s\n' "$*" >&2; problems=$((problems + 1)); }
info() { printf '%s\n' "$*"; }

# NUL-separated list of repository files: tracked or untracked-but-not-ignored
# inside a git checkout, every regular file otherwise.
repo_files() {
    if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$ROOT" ls-files -z --cached --others --exclude-standard
    else
        find . -type f -not -path './.git/*' -printf '%P\0'
    fi
}

all_files=()
shell_files=()
text_files=()
yaml_files=()
while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    all_files+=("$f")
    case "$f" in
        *.sh) shell_files+=("$f"); text_files+=("$f") ;;
        *.yml|*.yaml) yaml_files+=("$f"); text_files+=("$f") ;;
        LICENSE.txt) ;;   # legal text: never reformatted
        *.md|*.txt|*.desktop|*.conf) text_files+=("$f") ;;
    esac
done < <(repo_files)

# --- 1. bash -n --------------------------------------------------------------
for f in "${shell_files[@]}"; do
    if ! err=$(bash -n "$f" 2>&1); then
        bad "bash -n failed: $f: $err"
    fi
done
info "bash -n: ${#shell_files[@]} script(s) checked"

# --- 2. ShellCheck -----------------------------------------------------------
if command -v "$SHELLCHECK_BIN" >/dev/null 2>&1; then
    version=$("$SHELLCHECK_BIN" --version 2>/dev/null | sed -n 's/^version: *//p')
    if [ "$version" != "$EXPECTED_SHELLCHECK" ]; then
        if [ "$STRICT" = 1 ]; then
            bad "ShellCheck $version found, $EXPECTED_SHELLCHECK required"
        else
            info "note: ShellCheck $version found; CI pins $EXPECTED_SHELLCHECK"
        fi
    fi
    if ! sc_out=$("$SHELLCHECK_BIN" -x -P SCRIPTDIR --severity=style --format=gcc "${shell_files[@]}" 2>&1); then
        printf '%s\n' "$sc_out" >&2
        bad "ShellCheck reported findings ($(printf '%s\n' "$sc_out" | grep -c ': \(error\|warning\|note\|info\):') in total)"
    fi
    info "ShellCheck ${version:-?}: ${#shell_files[@]} script(s) checked"
elif [ "$STRICT" = 1 ]; then
    bad "ShellCheck not found (set SHELLCHECK_BIN or install it)"
else
    info "note: ShellCheck not found; skipped (LINT_STRICT=1 makes this an error)"
fi

# --- 3. File hygiene ---------------------------------------------------------
for f in "${text_files[@]}"; do
    [ -s "$f" ] || continue
    if grep -q $'\r' "$f"; then bad "$f: contains CR characters (use LF line endings)"; fi
    if head -c 3 "$f" | grep -q $'\xEF\xBB\xBF'; then bad "$f: starts with a UTF-8 BOM"; fi
    if ! iconv -f UTF-8 -t UTF-8 "$f" >/dev/null 2>&1; then bad "$f: not valid UTF-8"; fi
    if n=$(grep -n $'\t' "$f" | head -3) && [ -n "$n" ]; then
        bad "$f: contains tab characters (first: ${n%%:*})"
    fi
    if n=$(grep -nE '[[:space:]]+$' "$f" | head -3) && [ -n "$n" ]; then
        bad "$f: trailing whitespace (first: line ${n%%:*})"
    fi
    if [ "$(tail -c 1 "$f" | wc -l)" -eq 0 ]; then bad "$f: missing final newline"; fi
done
info "hygiene: ${#text_files[@]} text file(s) checked"

# --- 4. File modes -----------------------------------------------------------
# Nothing here needs the executable bit (the suites run as "bash tests/...", the README tells
# users to chmod +x the program), so one that is set by accident (a drive that marks every
# file executable, chmod 777) would be pushed as mode 100755. A file is flagged when its
# permissions on disk or the mode git has recorded for it say "executable".
exec_allowed() {
    local p
    for p in "${EXEC_OK[@]}"; do [ "$1" = "$p" ] && return 0; done
    return 1
}
for f in "${all_files[@]}"; do
    exec_allowed "$f" && continue
    if [ -n "$(find "./$f" -maxdepth 0 -type f -perm /111 2>/dev/null)" ] \
        || [ "$(GIT_LITERAL_PATHSPECS=1 git -C "$ROOT" ls-files -s -- "$f" 2>/dev/null | cut -c1-6)" = 100755 ]; then
        bad "$f: executable (git would record mode 100755); run chmod 644 \"$f\" and, in a git checkout, git add it again"
    fi
done
info "modes: ${#all_files[@]} file(s) checked"

# --- 5. YAML syntax ----------------------------------------------------------
if [ "${#yaml_files[@]}" -gt 0 ]; then
    if python3 -c 'import yaml' >/dev/null 2>&1; then
        for f in "${yaml_files[@]}"; do
            if ! err=$(python3 -c 'import sys, yaml
with open(sys.argv[1], encoding="utf-8") as fh:
    list(yaml.safe_load_all(fh))' "$f" 2>&1); then
                bad "invalid YAML: $f: ${err##*$'\n'}"
            fi
        done
        info "YAML: ${#yaml_files[@]} file(s) parsed"
    elif [ "$STRICT" = 1 ]; then
        bad "python3 with PyYAML is required to validate YAML (apt install python3-yaml)"
    else
        info "note: PyYAML not available; YAML syntax check skipped"
    fi
fi

if [ "$problems" -gt 0 ]; then
    printf 'lint: %d problem(s)\n' "$problems" >&2
    exit 1
fi
info "lint: OK"
