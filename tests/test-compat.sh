#!/bin/bash
# Distribution-compatibility suite. Distributions and package managers are
# simulated (fake os-release files, stub commands, `command -v` filtering), so
# the same checks run on any host. Expected failures have positive controls.
# shellcheck disable=SC2016  # ms_lib payloads are intentionally single-quoted
set -u
umask 022   # fixture modes must not depend on the contributor's umask

# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
ms_init

CALLS="$TMP/calls"; : > "$CALLS"
ms_env_set CALLS "$CALLS"
ms_stub apt-get 'echo "apt-get $*" >> "$CALLS"'
ms_stub apt-mark 'echo "apt-mark $*" >> "$CALLS"; printf "vim\ncurl\n"'
ms_stub apt-cache 'echo "apt-cache $*" >> "$CALLS"'
ms_stub dnf 'echo "dnf $*" >> "$CALLS"; case "$*" in *repoquery*) printf "%s" "${DNF_OUT:-}" ;; esac'
ms_stub pacman 'echo "pacman $*" >> "$CALLS"; case "$*" in *-Qqen*) printf "%s" "${PACMAN_OUT:-}" ;; esac'
ms_stub zypper 'echo "zypper $*" >> "$CALLS"'

osrel() {   # osrel NAME ID ID_LIKE PRETTY -> path of a fake os-release
    mkdir -p "$TMP/os"
    {
        printf 'ID=%s\n' "$2"
        [ -n "$3" ] && printf 'ID_LIKE="%s"\n' "$3"
        printf 'PRETTY_NAME="%s"\n' "$4"
    } > "$TMP/os/$1"
    printf '%s' "$TMP/os/$1"
}

# Payload prefix: hide the commands listed in MS_HIDE from `command -v`.
HIDE='command() { if [ "${1:-}" = "-v" ]; then case " ${MS_HIDE:-} " in *" $2 "*) return 1 ;; esac; fi; builtin command "$@"; }'

detect() {   # detect FILE "hidden commands" -> "pkg|id|name"
    ms_env_set MINT_SETUP_OS_RELEASE "$1"; ms_env_set MS_HIDE "$2"
    ms_lib "$HIDE; detect_platform; printf '%s|%s|%s' \"\$PLATFORM_PKG\" \"\$PLATFORM_OS_ID\" \"\$PLATFORM_NAME\""
}

# --- distribution and package-manager detection --------------------------------
check_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected [$3], got [$2])"; fi; }

check_eq "Linux Mint -> apt"        "$(detect "$(osrel mint linuxmint 'ubuntu debian' 'Linux Mint 22.3')" 'dnf pacman zypper')" "apt|linuxmint|Linux Mint 22.3"
check_eq "Ubuntu -> apt"            "$(detect "$(osrel ubuntu ubuntu debian 'Ubuntu 24.04 LTS')" 'dnf pacman zypper')" "apt|ubuntu|Ubuntu 24.04 LTS"
check_eq "Debian -> apt"            "$(detect "$(osrel debian debian '' 'Debian GNU/Linux 12')" 'dnf pacman zypper')" "apt|debian|Debian GNU/Linux 12"
check_eq "Fedora -> dnf"            "$(detect "$(osrel fedora fedora '' 'Fedora Linux 42')" 'apt-get apt-mark apt-cache pacman zypper')" "dnf|fedora|Fedora Linux 42"
check_eq "Arch derivative -> pacman" "$(detect "$(osrel manjaro manjaro 'arch' 'Manjaro Linux')" 'apt-get apt-mark apt-cache dnf zypper')" "pacman|manjaro|Manjaro Linux"
check_eq "openSUSE -> zypper"       "$(detect "$(osrel suse opensuse-tumbleweed 'opensuse suse' 'openSUSE Tumbleweed')" 'apt-get apt-mark apt-cache dnf pacman')" "zypper|opensuse-tumbleweed|openSUSE Tumbleweed"
check_eq "unknown distro falls back to the first available manager" "$(detect "$(osrel odd oddos '' 'Odd OS')" 'apt-get apt-mark apt-cache pacman zypper')" "dnf|oddos|Odd OS"
check_eq "no package manager at all"  "$(detect "$(osrel bare bareos '' 'Bare OS')" 'apt-get apt-mark apt-cache dnf pacman zypper')" "|bareos|Bare OS"
check_eq "missing os-release keeps a usable name" "$(detect "$TMP/os/does-not-exist" 'dnf pacman zypper lsb_release')" "apt||Linux"
printf 'ID=evil\nPRETTY_NAME="x"; touch %s/pwned\n' "$TMP" > "$TMP/os/evil"
detect "$TMP/os/evil" 'dnf pacman zypper' >/dev/null
ok "os-release content is read as data, never executed" test ! -e "$TMP/pwned"

# --- desktop detection --------------------------------------------------------
desk() { ms_env_set XDG_CURRENT_DESKTOP "$1"; ms_lib 'detect_platform; is_cinnamon_desktop && echo yes || echo no'; }
check_eq "X-Cinnamon counts as Cinnamon" "$(desk X-Cinnamon)" yes
check_eq "GNOME is not Cinnamon"          "$(desk GNOME)" no
check_eq "unknown desktop shows no warning" "$(desk '')" yes

# --- install hints and dependency check ---------------------------------------
hint() { ms_env_set MINT_SETUP_OS_RELEASE "$1"; ms_env_set MS_HIDE "$2"; ms_lib "$HIDE; detect_platform; shift 0; install_hint dconf gsettings"; }
check_eq "apt hint"    "$(hint "$(osrel mint linuxmint 'ubuntu debian' x)" 'dnf pacman zypper')" "sudo apt install dconf-cli libglib2.0-bin"
check_eq "dnf hint"    "$(hint "$(osrel fedora fedora '' x)" 'apt-get apt-mark apt-cache pacman zypper')" "sudo dnf install dconf glib2"
check_eq "pacman hint" "$(hint "$(osrel arch arch '' x)" 'apt-get apt-mark apt-cache dnf zypper')" "sudo pacman -S dconf glib2"
check_eq "zypper hint" "$(hint "$(osrel suse opensuse-tumbleweed 'opensuse suse' x)" 'apt-get apt-mark apt-cache dnf pacman')" "sudo zypper install dconf glib2-tools"

# apt-get is no longer mandatory: a system without it still passes the check.
ms_env_set MINT_SETUP_OS_RELEASE "$(osrel fedora fedora '' 'Fedora Linux 42')"
ms_env_set MS_HIDE 'apt-get apt-mark apt-cache pacman zypper'
for c in dconf gsettings; do ms_stub "$c"; done
ms_lib "$HIDE; detect_platform; check_dependencies" >/dev/null 2>&1
ok "dependency check passes without apt-get on a dnf system" test $? -eq 0
# Missing dconf: fails, and the dialog text carries the dnf-specific hint (control: the failure is real).
ms_env_set MS_HIDE 'apt-get apt-mark apt-cache pacman zypper dconf'
rm -f "$ZEN/texts" "$ZEN/index"
ms_lib "$HIDE; detect_platform; check_dependencies" >/dev/null 2>&1; rc=$?
ok "dependency check fails when dconf is missing" test "$rc" -eq 1
ok "missing-dependency dialog suggests the dnf command" grep -Fq 'sudo dnf install dconf' "$ZEN/texts"

# --- Applications module: save --------------------------------------------------
SAVE_PREFIX='pack_dir() { :; }; SAVE_CONTEXT=1 SAVE_MODULE_FAILED=0'
save_sw() {   # save_sw "hidden" -> runs save_software into $TMP/out and prints FAILED flag
    rm -rf "$TMP/out"; mkdir -p "$TMP/out"
    ms_env_set MS_HIDE "$1"
    ms_lib "$HIDE; detect_platform; $SAVE_PREFIX; save_software \"$TMP/out\" >/dev/null 2>&1; echo FAILED:\$SAVE_MODULE_FAILED"
}
ms_env_set MINT_SETUP_OS_RELEASE "$(osrel fedora fedora '' 'Fedora Linux 42')"
ms_env_set DNF_OUT $'zeta\nalpha\nalpha\n'
out=$(save_sw 'apt-get apt-mark apt-cache pacman zypper')
check_eq "dnf save does not flag failure"      "$out" "FAILED:0"
check_eq "dnf list is sorted, unique, one per line" "$(cat "$TMP/out/software/native-packages.list")" $'alpha\nzeta'
check_eq "dnf manager is recorded"             "$(cat "$TMP/out/software/native-packages.manager")" "dnf"
ok "dnf system writes no APT list"             test ! -e "$TMP/out/software/apt-manual.list"
ms_env_set DNF_OUT 'one\ntwo\n'    # some dnf versions print the escape instead of a newline
save_sw 'apt-get apt-mark apt-cache pacman zypper' >/dev/null
check_eq "literal \\n separators are normalised" "$(cat "$TMP/out/software/native-packages.list")" $'one\ntwo'

ms_env_set MINT_SETUP_OS_RELEASE "$(osrel arch arch '' 'Arch Linux')"
ms_env_set PACMAN_OUT $'neovim\nfirefox\n'
out=$(save_sw 'apt-get apt-mark apt-cache dnf zypper')
check_eq "pacman save does not flag failure"   "$out" "FAILED:0"
check_eq "pacman list is sorted"               "$(cat "$TMP/out/software/native-packages.list")" $'firefox\nneovim'

ms_env_set MINT_SETUP_OS_RELEASE "$(osrel mint linuxmint 'ubuntu debian' 'Linux Mint 22.3')"
out=$(save_sw 'dnf pacman zypper')
check_eq "APT system keeps the APT list (control)" "$(cat "$TMP/out/software/apt-manual.list")" $'curl\nvim'
ok "APT system writes no native list"          test ! -e "$TMP/out/software/native-packages.list"

# --- Applications module: restore on a system without APT -----------------------
mkdir -p "$TMP/bk/software"
printf 'vim\ncurl\n' > "$TMP/bk/software/apt-manual.list"
printf 'alpha\nzeta\n' > "$TMP/bk/software/native-packages.list"
printf 'dnf\n' > "$TMP/bk/software/native-packages.manager"
: > "$CALLS"
ms_env_set MINT_SETUP_OS_RELEASE "$(osrel fedora fedora '' 'Fedora Linux 42')"
ms_env_set MS_HIDE 'apt-get apt-mark apt-cache pacman zypper flatpak'
ms_env_set LC_ALL C.UTF-8
res=$(ms_lib "$HIDE; detect_platform; set_language en; RESTORE_CONTEXT=1; restore_software \"$TMP/bk\"; echo \"RC:\$?\"" 2>&1)
ok "restore on dnf reports a partial result"          grep -Fq 'RC:1' <<<"$res"
ok "APT data on a non-APT system is explained"        grep -Fq 'does not use APT' <<<"$res"
ok "guided restore prints the exact dnf command"      grep -Fq "xargs -a $TMP/bk/software/native-packages.list sudo dnf install" <<<"$res"
ok "restore never ran a package manager or pkexec"    test ! -s "$CALLS"

printf 'pacman\n' > "$TMP/bk/software/native-packages.manager"
res=$(ms_lib "$HIDE; detect_platform; set_language en; restore_software \"$TMP/bk\"; echo \"RC:\$?\"" 2>&1)
ok "a list from another manager is not applied"       grep -Fq 'comes from pacman, but this system uses dnf' <<<"$res"

# Positive control: on an APT system the same backup does not take the guided path.
ms_env_set MINT_SETUP_OS_RELEASE "$(osrel mint linuxmint 'ubuntu debian' 'Linux Mint 22.3')"
ms_env_set MS_HIDE 'dnf pacman zypper flatpak'
res=$(ms_lib "$HIDE; detect_platform; set_language en; restore_software \"$TMP/bk\" 2>&1 | head -40" 2>&1)
ok "APT system does not claim APT is unavailable (control)" bash -c '! grep -Fq "does not use APT" <<<"$1"' _ "$res"

# --- Backups remember where they came from; restore warns about foreign ones ---
mkdir -p "$TMP/bk2/terminal"
printf 'NAME=%q\nDATE=%q\nMINT_RELEASE=%q\nOS_ID=%q\nPKG_MANAGER=%q\nMODULES=%q\n' 'Mint box' '2026-10-01' 'Linux Mint 22.3' linuxmint apt terminal > "$TMP/bk2/manifest.conf"
restore_prompt() {   # restore_prompt OS-RELEASE-FILE -> text of the confirmation dialog
    ms_env_set MINT_SETUP_OS_RELEASE "$1"; rm -f "$ZEN/index"
    ZENITY_LIST_CHOICES='terminal' ms_lib "detect_platform; set_language en
pick_backup_dir() { printf '%s\n' \"$TMP/bk2\"; }
confirm() { printf 'CONFIRM:%s\n' \"\$1\"; return 1; }
do_restore" 2>&1
}
res=$(restore_prompt "$(osrel fedora fedora '' 'Fedora Linux 42')")
ok "restoring a Mint backup on Fedora shows the cross-distribution warning" grep -Fq 'saved on “Linux Mint 22.3” and this system is “Fedora Linux 42”' <<<"$res"
res=$(restore_prompt "$(osrel mint linuxmint 'ubuntu debian' 'Linux Mint 22.3')")
ok "same distribution shows no warning (control)"  grep -Fq 'CONFIRM:' <<<"$res"
ok "same distribution: warning text is absent"     bash -c '! grep -Fq "saved on" <<<"$1"' _ "$res"

# --- Main menu hint outside Cinnamon --------------------------------------------
menu_text() {
    ms_env_set XDG_CURRENT_DESKTOP "$1"; rm -f "$ZEN/texts" "$ZEN/index"
    ZENITY_LIST_CHOICES='5' ms_lib 'set_language en; main_menu' >/dev/null 2>&1
    cat "$ZEN/texts"
}
ok "GNOME session: the menu mentions the detected desktop" grep -Fq 'Detected desktop: GNOME' <<<"$(menu_text GNOME)"
ok "Cinnamon session: no desktop warning"           bash -c '! grep -Fq "Detected desktop" <<<"$1"' _ "$(menu_text X-Cinnamon)"

ms_finish
