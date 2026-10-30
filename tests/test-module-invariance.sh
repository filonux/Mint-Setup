#!/bin/bash
set -euo pipefail
umask 022   # fixture modes must not depend on the contributor's umask

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/script/mint-setup.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# The program puts its pkexec lock in XDG_RUNTIME_DIR / XDG_CACHE_HOME: never the real ones.
unset XDG_RUNTIME_DIR XDG_CACHE_HOME
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

modules=(desktop appearance nemo software startup displays sound network bluetooth keyboard mouse touchpad firefox librewolf thunderbird libreoffice onlyoffice vscode docker terminal)
restore_safe=(desktop appearance nemo startup displays sound keyboard mouse touchpad firefox librewolf thunderbird libreoffice onlyoffice vscode terminal)

seed="$TMP/seed"
mkdir -p "$seed/.config" "$seed/.local/share/cinnamon/applets" "$seed/.local/share/cinnamon/desklets" "$seed/.local/share/cinnamon/extensions" "$seed/.cinnamon/configs" \
         "$seed/.config/autostart" "$seed/Pictures" "$seed/.themes/demo" "$seed/.local/share/themes/demo" "$seed/.icons/demo" \
         "$seed/.local/share/icons/demo" "$seed/.fonts" "$seed/.local/share/fonts" "$seed/.config/gtk-3.0" \
         "$seed/.mozilla/firefox/p1" "$seed/.librewolf/p1" "$seed/.thunderbird/p1" "$seed/.config/libreoffice" \
         "$seed/.config/onlyoffice" "$seed/.local/share/onlyoffice" "$seed/.config/Code/User/snippets" \
         "$seed/.config/Code/User/profiles/profile1" "$seed/.docker"
for f in .bashrc .bash_aliases .profile .zshrc; do printf 'saved-%s\n' "$f" > "$seed/$f"; done
printf 'starship\n' > "$seed/.config/starship.toml"
printf 'gtk\n' > "$seed/.config/gtk-3.0/settings.ini"
printf 'applet\n' > "$seed/.local/share/cinnamon/applets/a.js"
printf 'desklet\n' > "$seed/.local/share/cinnamon/desklets/d.js"
printf 'extension\n' > "$seed/.local/share/cinnamon/extensions/e.js"
printf 'config\n' > "$seed/.cinnamon/configs/c.json"
printf 'startup\n' > "$seed/.config/autostart/a.desktop"
printf 'firefox\n' > "$seed/.mozilla/firefox/p1/bookmarks"
printf 'librewolf\n' > "$seed/.librewolf/p1/bookmarks"
printf 'thunderbird\n' > "$seed/.thunderbird/p1/accounts"
printf 'libreoffice\n' > "$seed/.config/libreoffice/config"
printf 'onlyoffice\n' > "$seed/.config/onlyoffice/config"
printf 'plugin\n' > "$seed/.local/share/onlyoffice/plugin"
printf 'snippet\n' > "$seed/.config/Code/User/snippets/snip.code-snippets"
printf 'profile\n' > "$seed/.config/Code/User/profiles/profile1/settings.json"
printf 'docker\n' > "$seed/.docker/config.json"
: > "$seed/Pictures/wallpaper.png"
find "$seed" -exec touch -t 202001010101 {} +

make_mocks() {
    local lang="$1"; local bin="$TMP/bin-$lang"
    mkdir -p "$bin"
    cat > "$bin/dconf" <<'CMD'
#!/bin/sh
case "$*" in *gnome/terminal*) printf '[terminal]\nprofile-id=test\n';; *) printf '[fixture]\nvalue=test\n';; esac
CMD
    cat > "$bin/gsettings" <<CMD
#!/bin/sh
if [ "\${1:-}" = get ] && [ "\${2:-}" = org.cinnamon.desktop.background ]; then printf "'file://$seed/Pictures/wallpaper.png'\\n"; exit 0; fi
if [ "\${1:-}" = get ] && [ "\${2:-}" = org.gnome.desktop.interface ]; then printf "'default'\\n"; exit 0; fi
printf 'ok\\n'
CMD
    cat > "$bin/pactl" <<'CMD'
#!/bin/sh
case "$*" in *default-sink*) echo sink-test;; *default-source*) echo source-test;; esac
CMD
    cat > "$bin/xrandr" <<'CMD'
#!/bin/sh
echo 'Screen 0: 1920x1080 0mm x 0mm'
CMD
    cat > "$bin/apt-mark" <<'CMD'
#!/bin/sh
echo bash
echo coreutils
CMD
    cat > "$bin/flatpak" <<'CMD'
#!/bin/sh
case "$*" in *remotes*) printf 'flathub\thttps://dl.flathub.org/repo/flathub.flatpakrepo\n';; *list*) printf 'org.example.App\tflathub\n';; esac
CMD
    cat > "$bin/code" <<'CMD'
#!/bin/sh
case "$*" in *--list-extensions*) printf 'ms-test.one\nms-test.two\n';; esac
CMD
    cat > "$bin/code-insiders" <<'CMD'
#!/bin/sh
exit 0
CMD
    cat > "$bin/docker" <<'CMD'
#!/bin/sh
exit 0
CMD
    cat > "$bin/pkexec" <<'CMD'
#!/bin/sh
exit 1
CMD
    # Nothing is running: the browser, mail and office restores skip (and fail)
    # while their application is open, so the host's processes must not matter.
    cat > "$bin/pgrep" <<'CMD'
#!/bin/sh
exit 1
CMD
    cat > "$bin/fc-cache" <<'CMD'
#!/bin/sh
exit 0
CMD
    cat > "$bin/systemctl" <<'CMD'
#!/bin/sh
exit 0
CMD
    cat > "$bin/xdg-user-dir" <<'CMD'
#!/bin/sh
printf '%s\n' "$HOME/Pictures"
CMD
    chmod +x "$bin"/*
}

hash_tree() {
    local dir="$1" out="$2"
    find "$dir" -type f -printf '%P\n' | sort > "$out.files"
    (cd "$dir" && while IFS= read -r f; do sha256sum "$f"; done < "$out.files") > "$out.hash"
}

for lang in en es; do
    home="$TMP/home-$lang"; backup="$TMP/backup-$lang"
    cp -a "$seed" "$home"; mkdir -p "$backup"
    make_mocks "$lang"
    for mod in "${modules[@]}"; do
        HOME="$home" XDG_CONFIG_HOME="$TMP/cfg-$lang" MINT_SETUP_TEST=1 LC_ALL=C \
        PATH="$TMP/bin-$lang:/usr/bin:/bin" bash -c 'source "$1"; set_language "$2"; save_'"$mod"' "$3"' \
        _ "$SCRIPT" "$lang" "$backup" >/dev/null 2>&1 || fail "save_$mod failed in $lang"
    done
    hash_tree "$backup" "$TMP/save-$lang"
done

diff -u "$TMP/save-en.files" "$TMP/save-es.files" >/dev/null || fail "save module file sets differ by language"
diff -u "$TMP/save-en.hash" "$TMP/save-es.hash" >/dev/null || fail "save module contents differ by language"
pass "all save modules invariant across languages"

backup="$TMP/restore-source"
mkdir -p "$backup"
HOME="$seed" XDG_CONFIG_HOME="$TMP/cfg-seed" MINT_SETUP_TEST=1 LC_ALL=C PATH=/usr/bin:/bin \
    bash -c 'source "$1"; set_language en; for m in "$@"; do save_"$m" "$2"; done' _ "$SCRIPT" "$backup" "${restore_safe[@]}" >/dev/null 2>&1

for lang in en es; do
    home="$TMP/restore-home-$lang"; cp -a "$seed" "$home"
    printf 'changed\n' > "$home/.bashrc"
    rm -rf "$home/.mozilla" "$home/.librewolf" "$home/.thunderbird" "$home/.config/libreoffice" "$home/.config/onlyoffice" "$home/.local/share/onlyoffice" "$home/.config/Code"
    make_mocks "$lang"
    for mod in "${restore_safe[@]}"; do
        HOME="$home" XDG_CONFIG_HOME="$TMP/restore-cfg-$lang" MINT_SETUP_TEST=1 LC_ALL=C \
        PATH="$TMP/bin-$lang:/usr/bin:/bin" bash -c 'source "$1"; set_language "$2"; restore_'"$mod"' "$3"' \
        _ "$SCRIPT" "$lang" "$backup" >/dev/null 2>&1 || fail "restore_$mod failed in $lang"
    done
    hash_tree "$home" "$TMP/restore-$lang"
done

diff -u "$TMP/restore-en.files" "$TMP/restore-es.files" >/dev/null || fail "restore module file sets differ by language"
diff -u "$TMP/restore-en.hash" "$TMP/restore-es.hash" >/dev/null || fail "restore module contents differ by language"
pass "all safe restore modules invariant across languages"

printf 'All module-invariance tests passed.\n'
