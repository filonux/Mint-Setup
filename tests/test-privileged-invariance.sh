#!/bin/bash
set -euo pipefail
umask 022   # fixture modes must not depend on the contributor's umask
ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/script/mint-setup.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# The program names its temporary files <TMPDIR>/tmp.XXXXXXXXXX. TMPDIR points to a folder inside $TMP that
# is not called "tmp": the trace comparison below cannot depend on the caller's TMPDIR (/dev/shm,
# /run/user/1000...), and a pattern that assumes /tmp/tmp.XXXXXXXXXX fails here in every environment.
mkdir -p "$TMP/scratch"; export TMPDIR="$TMP/scratch"
# The program puts its pkexec lock in XDG_RUNTIME_DIR / XDG_CACHE_HOME: never the real ones.
unset XDG_RUNTIME_DIR XDG_CACHE_HOME
for lang in en es; do
  H="$TMP/home-$lang"; B="$TMP/backup-$lang"; BIN="$TMP/bin-$lang"; CFG="$TMP/cfg-$lang"
  mkdir -p "$H/.docker" "$B/network" "$B/bluetooth" "$B/software" "$B/docker" "$BIN" "$CFG"
  export HOME="$H" XDG_CONFIG_HOME="$CFG" MINT_SETUP_TEST=1 LC_ALL=C PATH="$BIN:/usr/bin:/bin"
  cat > "$BIN/pkexec" <<'S'
#!/bin/sh
printf 'PKEXEC %s\n' "$*" >> "$TRACE"
case "$*" in
  *'tar czf - -C /var/lib bluetooth'*) tar czf - -C /var/lib bluetooth 2>/dev/null || true; exit 0;;
  *'tar czf - -C /etc/NetworkManager system-connections'*) tar czf - -C /etc/NetworkManager system-connections 2>/dev/null || true; exit 0;;
  *) exit 0;;
esac
S
  cat > "$BIN/apt-cache" <<'S'
#!/bin/sh
[ "${1:-}" = pkgnames ] && printf 'bash\ncoreutils\n'
S
  cat > "$BIN/apt-mark" <<'S'
#!/bin/sh
printf 'bash\n'
S
  cat > "$BIN/flatpak" <<'S'
#!/bin/sh
case "$*" in *remotes*) printf 'flathub\thttps://example.invalid/repo\n';; *list*) printf 'org.example.App\tflathub\n';; *) :;; esac
S
  cat > "$BIN/docker" <<'S'
#!/bin/sh
exit 0
S
  cat > "$BIN/getent" <<'S'
#!/bin/sh
[ "$1" = group ] && exit 1
exit 1
S
  chmod +x "$BIN"/*
  export TRACE="$TMP/trace-$lang"
  : > "$TRACE"
  # Fixtures only; the real /etc is never touched: privileged calls end at the pkexec stub above.
  printf 'bash\n' > "$B/software/apt-manual.list"
  printf 'flathub\thttps://example.invalid/repo\n' > "$B/software/flatpak-remotes.list"
  printf 'org.example.App\tflathub\n' > "$B/software/flatpak.list"
  printf '{"log-driver":"json-file"}\n' > "$B/docker/daemon.json"
  tar czf "$B/bluetooth/bluetooth.tar.gz" --files-from /dev/null
  tar czf "$B/network/system-connections.tar.gz" --files-from /dev/null
  bash -c 'source "$1"; set_language "$2"; save_network "$3"; save_bluetooth "$3"; restore_network "$3"; restore_bluetooth "$3"; restore_software "$3"; restore_docker "$3"' _ "$SCRIPT" "$lang" "$B" >/dev/null 2>&1 || { echo FAIL-$lang; exit 1; }
done
# Every privileged call reaches pkexec through prun, so --disable-internal-agent
# comes first; a direct pkexec would fall back to its own text prompt on the
# terminal when no graphical agent is registered. Each language makes 7 calls
# (Network and Bluetooth save and restore, apt-get update and install, the
# Docker copy); the exact count keeps the check from passing on an empty trace.
for lang in en es; do
  calls=$(grep -c '^PKEXEC ' "$TMP/trace-$lang" || true)
  bare=$(grep '^PKEXEC ' "$TMP/trace-$lang" | grep -vc '^PKEXEC --disable-internal-agent ' || true)
  if [ "$calls" -ne 7 ] || [ "$bare" -ne 0 ]; then
    echo "FAIL-$lang: $calls pkexec calls (expected 7), $bare without --disable-internal-agent" >&2
    exit 1
  fi
done
echo 'PASS: every privileged call passes --disable-internal-agent to pkexec'
# Ignore only command text that is intentionally language-bearing by testing normalized traces; there should be none.
norm() { sed -E 's#[^[:space:]]*/tmp\.[A-Za-z0-9]+#/tmp/TMPDIR#g; s#backup-(en|es)/docker#backup/docker#g' "$1"; }
norm "$TMP/trace-en" > "$TMP/norm-en"
norm "$TMP/trace-es" > "$TMP/norm-es"
if diff -u "$TMP/norm-en" "$TMP/norm-es" >/dev/null; then
  echo 'PASS: privileged/system module command traces invariant across languages'
else
  echo 'FAIL: privileged/system module command traces differ' >&2
  diff -u "$TMP/norm-en" "$TMP/norm-es" >&2 || true
  exit 1
fi
