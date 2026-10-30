#!/bin/bash
# Copyright (C) 2026 Filonux
#
# License:
#   Mint-Setup is free software distributed under the terms of the
#   GNU General Public License version 3 (GPLv3).
#   See the LICENSE.txt file for the full text of the license.
###############################################################################
# Mint-Setup
# Author: Filonux
#
# Saves and restores the user environment configuration on Linux Mint
# (Cinnamon): desktop, appearance, Nemo, installed applications, startup
# applications, displays, sound, network, Bluetooth, keyboard, mouse,
# touchpad, and the own configuration of specific applications: Firefox,
# LibreWolf, Thunderbird, LibreOffice, ONLYOFFICE, VS Code, Docker and the
# terminal.
#
# It does not replace Timeshift or MintBackup. It complements them:
#   - Timeshift restores the system.
#   - MintBackup restores personal files.
#   - Mint-Setup rebuilds the working environment.
#
# Philosophy: the program does not copy the system, it describes how it is
# configured (using dconf, gsettings, apt-mark, flatpak, extension lists...)
# and, when restoring, applies that configuration again on a fresh Linux Mint
# installation.
#
# Every module (Desktop, Appearance, Nemo, Applications... and each specific
# application) is independent: Save and Restore show a checklist to choose
# exactly which modules to touch in each operation.
#
# Advanced settings adds, besides the modules above, backup and emergency
# restore of the LUKS header of encrypted disks: unlike the modules, it is not
# a user configuration but a copy tied to one specific physical disk.
#
# The Network and Bluetooth modules ask for administrator permissions through
# pkexec both when saving and when restoring (they read and write paths that
# only root can touch) and may contain credentials (Wi-Fi passwords in plain
# text, pairing keys). The Docker module asks for administrator permissions
# only for the daemon part (/etc/docker/daemon.json) and to add the user to
# the docker group; its user configuration (~/.docker) does not need them.
#
# Usage: mint-setup.sh [--install | --uninstall [--keep-config | --purge] [--yes]]
#        mint-setup.sh [-l | --toggle-language | --version | -h | --help]
#
# Compatibility: designed for Linux Mint (Cinnamon). On other distributions
# with zenity, dconf and gsettings it works the same, except the modules tied
# to Cinnamon and Nemo (only partly applied) and the automatic restoration of
# native packages (APT only; Flatpak works on any distribution).
#
# Requires: zenity, dconf, gsettings and tar (mandatory). These are optional
# and checked separately: flatpak, pkexec, pactl, iconv, gio, fc-cache,
# xdg-user-dir, pgrep, code (VS Code) and cryptsetup (LUKS header). If one is
# missing, the step that uses it is skipped or warns (if pgrep is missing, the
# application is assumed, as a precaution, to possibly be open), without
# interrupting the rest of the save/restore.
###############################################################################

# shellcheck disable=SC1111  # the typographic quotes “ ” of the EN catalog are intentional

# Minimum bash: 4.4. Under 4.3, "set -u" treats an empty array as unset, so
# "${array[@]}" on an empty one aborts with "unbound variable" halfway through a
# save or restore. This is the first command and uses only syntax every bash
# parses, so an older one stops here without touching anything. The text is
# bilingual because the language catalog does not exist yet.
if [ "${BASH_VERSINFO[0]}" -lt 4 ] \
    || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    echo "Mint-Setup needs bash 4.4 or newer; this is bash $BASH_VERSION." >&2
    echo "Mint-Setup necesita bash 4.4 o superior; esta es bash $BASH_VERSION." >&2
    exit 1
fi

set -uo pipefail

# Every file or folder this script creates from now on is born without
# permissions for "group" or "others". Several modules may contain
# credentials (Wi-Fi, Bluetooth pairing); this keeps them from being exposed
# even for an instant, instead of relying only on the final chmod of
# do_save().
umask 077

# The Restore progress dialog (see do_restore) writes straight to a named
# pipe connected to zenity, outside any subshell. If the user closes that
# window halfway through the operation, the next "echo" into the broken pipe
# would raise SIGPIPE; ignoring it keeps that from killing the whole script
# instead of just failing that one write.
trap '' PIPE

# This script is meant to run as the normal desktop user: the steps that need
# privileges (Network, Bluetooth, installing packages...) already ask for
# specific permissions with pkexec when required. Running the WHOLE script as
# root or with sudo is an easy mistake to make, seeing so many "administrator
# permissions" warnings, but it breaks the program: $HOME would become root's,
# so it would save and read the wrong configuration without saying so.
APP_NAME="Mint-Setup"
APP_VERSION="3.1.0"
# --version is resolved before anything else (including the root check below),
# so the installed version can be queried from another script without
# triggering zenity dialogs or the "do not run this as root" warning.
for arg in "$@"; do
    [ "$arg" = "--version" ] && { echo "$APP_NAME $APP_VERSION"; exit 0; }
done

# =============================================================================
# ATOMIC WRITES
# =============================================================================
# Rules followed by every write the program makes over data that already
# exists (user configuration, finished backups):
#   1. Data is never written straight to the destination: it is written to a
#      hidden temporary file INSIDE THE SAME DIRECTORY (same filesystem, a
#      requirement for rename(2) to be atomic).
#   2. Data is flushed to disk (fsync) before publishing.
#   3. It is published with "mv -T" (rename): the destination is always the
#      complete old content or the complete new content, never a mix.
#   4. If something fails or the script is interrupted, the temporary file is
#      removed and the destination is left untouched.
# Temporary files are named ".<name>.mstmp.XXXXXX" (see ms_tmp_stem for long names).

_MS_TRAP_PID=$$   # PID of the process that has the cleanup traps installed
_MS_TMP=()
_MS_DIR_SWAP_OLD=""
_MS_DIR_SWAP_DEST=""

# Registers a temporary file so it is deleted if the script ends halfway.
# Subprocesses (Restore modules running in the background, pipelines) do not
# inherit the main EXIT trap: the first temporary file they register installs
# one of their own and opens a list of their own, so they never delete what
# the parent process is still using.
# bash 5.1 (Mint 21): a pipeline element or background job that installed that trap ends with
# the status of the last command it ran, not the one given to "return" (a failed write counted
# as written). What can run there must end with a command that carries the status: "return $?"
# right after the call (atomic_write, atomic_tar) or "exit" (restore_module_job). "local rc=$?;
# return "$rc"" does not keep it. bash 5.2 is not affected.
ms_tmp_track() {
    if [ "$BASHPID" != "$_MS_TRAP_PID" ]; then
        _MS_TRAP_PID=$BASHPID
        _MS_TMP=()
        trap 'ms_tmp_cleanup' EXIT
        trap 'ms_tmp_cleanup; exit 143' TERM
        trap 'ms_tmp_cleanup; exit 130' INT
        trap 'ms_tmp_cleanup; exit 129' HUP
    fi
    _MS_TMP+=("$1")
}

ms_tmp_untrack() {
    local p keep=()
    for p in "${_MS_TMP[@]+"${_MS_TMP[@]}"}"; do
        [ "$p" = "$1" ] || keep+=("$p")
    done
    _MS_TMP=("${keep[@]+"${keep[@]}"}")
}

# Deletes a temporary file or folder. A staged copy can hold read-only folders
# (e.g. 0555) whose content rm cannot delete, so a real folder (never a link) is
# opened first.
ms_rm_tmp() {
    if [ -d "$1" ] && [ ! -L "$1" ]; then chmod -R u+rwX -- "$1" 2>/dev/null; fi
    rm -rf -- "$1" 2>/dev/null
}

ms_tmp_cleanup() {
    local p
    for p in "${_MS_TMP[@]+"${_MS_TMP[@]}"}"; do
        ms_rm_tmp "$p"
    done
    _MS_TMP=()
}

# Deletes the given temporary files and removes them from the list.
ms_tmp_discard() {
    local p
    for p in "$@"; do
        ms_rm_tmp "$p"
        ms_tmp_untrack "$p"
    done
}

# Puts back the previous copy that an export set aside (see do_export_backup) and clears
# the swap record. If it cannot be put back it is the user's only copy: it is taken off
# the temporary list so the exit cleanup does not delete it, its place is left in
# MS_DIR_SWAP_STUCK and the return code is 1. A destination that exists again means the
# new copy was published: the old one stays a temporary and is deleted as usual.
MS_DIR_SWAP_STUCK=""
ms_dir_swap_restore() {
    local old="$_MS_DIR_SWAP_OLD" dest="$_MS_DIR_SWAP_DEST"
    MS_DIR_SWAP_STUCK=""
    _MS_DIR_SWAP_OLD=""
    _MS_DIR_SWAP_DEST=""
    [ -n "$old" ] && [ -n "$dest" ] && [ -d "$old" ] || return 0
    [ ! -e "$dest" ] && [ ! -L "$dest" ] || return 0
    ms_tmp_untrack "$old"
    mv -T -- "$old" "$dest" 2>/dev/null && return 0
    MS_DIR_SWAP_STUCK="$old"
    return 1
}

# fsync of files or folders. Best effort: if "sync" does not accept
# arguments, atomicity stays intact; only the durability guarantee against a
# power cut at that very instant is lost.
ms_fsync() {
    sync -- "$@" 2>/dev/null || true
}

# The part of the name "$2" that goes into the name of its temporary file, left in the
# variable named "$1". A temporary adds up to 17 bytes to it (".", ".mstmp." or ".mint-old."
# and six random characters): with a name of 242 to 255 bytes, valid on its own, the
# temporary was not and the write failed. Names of more than MS_TMP_STEM_MAX bytes keep only
# their first MS_TMP_STEM_MAX, with everything outside [A-Za-z0-9._-] turned into "_" (a
# multibyte character cut in half would give a name that some filesystems refuse); that keeps
# a temporary under 143 bytes, the limit of eCryptfs. Any other name is used as it is, minus
# its leading dot.
MS_TMP_STEM_MAX=100
ms_tmp_stem() {
    local LC_ALL=C __s="${2#.}"
    if [ "${#__s}" -gt "$MS_TMP_STEM_MAX" ]; then
        __s="${__s:0:MS_TMP_STEM_MAX}"
        __s="${__s//[!A-Za-z0-9._-]/_}"
    fi
    printf -v "$1" '%s' "$__s"
}

# Creates a temporary sibling of "$2" (same directory) and leaves its path in
# the variable named "$1". "$3" = "d" creates a directory instead of a file.
# A variable is used (not $(...)) so the temporary file is registered in the
# current process.
ms_mktemp() {
    local __var="$1" target="$2" kind="${3:-f}" parent base stem made
    parent=$(dirname -- "$target")
    base=$(basename -- "$target")
    ms_tmp_stem stem "$base"
    if [ "$kind" = d ]; then
        made=$(mktemp -d -- "$parent/.$stem.mstmp.XXXXXX" 2>/dev/null) || return 1
    else
        made=$(mktemp -- "$parent/.$stem.mstmp.XXXXXX" 2>/dev/null) || return 1
    fi
    ms_tmp_track "$made"
    printf -v "$__var" '%s' "$made"
}

# If the destination is a symbolic link (e.g. a .bashrc managed with stow),
# it is resolved so the real file is replaced and the link is kept.
ms_resolve_dest() {
    if [ -L "$1" ]; then
        readlink -f -- "$1" 2>/dev/null || printf '%s' "$1"
    else
        printf '%s' "$1"
    fi
}

# Permissions of the temporary file: if the destination already existed its
# own are kept; if not, it stays at 600 (umask 077) and "executable" is only
# added if the source was. Permissions are never widened beyond what the
# umask would give.
ms_set_mode() {
    local tmp="$1" dest="$2" src="${3:-}"
    if [ -e "$dest" ]; then
        chmod --reference="$dest" -- "$tmp" 2>/dev/null || true
    elif [ -n "$src" ] && [ -x "$src" ]; then
        chmod u+x -- "$tmp" 2>/dev/null || true
    fi
}

# Publishes "$1" (the temporary file) as "$2" with an atomic rename and syncs
# the folder.
ms_commit() {
    local tmp="$1" dest="$2"
    ms_fsync "$tmp"
    mv -T -- "$tmp" "$dest" || return 1
    ms_tmp_untrack "$tmp"
    ms_fsync "$(dirname -- "$dest")"
    return 0
}

# Marks the module being restored as failed (it does nothing outside a restore).
restore_mark_failed() {
    if [ "${RESTORE_CONTEXT:-0}" -eq 1 ]; then
        RESTORE_MODULE_FAILED=1
    fi
}

# Reads stdin and writes it atomically to "$1" (optional mode in "$2").
# It usually ends a pipeline, so the wrapper ends with "return $?" (see ms_tmp_track).
atomic_write() {
    atomic_write_run "$@"
    return $?
}

atomic_write_run() {
    local dest tmp mode="${2:-}"
    dest=$(ms_resolve_dest "$1")
    ms_mktemp tmp "$dest" || { restore_mark_failed; return 1; }
    if cat > "$tmp" && ms_set_mode "$tmp" "$dest" && { [ -z "$mode" ] || chmod "$mode" -- "$tmp"; } && ms_commit "$tmp" "$dest"; then
        return 0
    fi
    ms_tmp_discard "$tmp"
    restore_mark_failed
    return 1
}

# Copies the file "$1" to "$2" atomically (optional mode in "$3").
atomic_copy() {
    local src="$1" dest tmp mode="${3:-}"
    dest=$(ms_resolve_dest "$2")
    [ -f "$src" ] || { restore_mark_failed; return 1; }
    ms_mktemp tmp "$dest" || { restore_mark_failed; return 1; }
    if cp -- "$src" "$tmp" && ms_set_mode "$tmp" "$dest" "$src" && { [ -z "$mode" ] || chmod "$mode" -- "$tmp"; } && ms_commit "$tmp" "$dest"; then
        return 0
    fi
    ms_tmp_discard "$tmp"
    restore_mark_failed
    return 1
}

# Like atomic_copy, but if the destination already exists and its content
# differs, it first saves a copy of it as "<destination>.mint-setup.bak" (or
# ".bak.1", ".bak.2"... if that exists: a previous copy is never overwritten)
# so a restore that overwrites hand-edited files (.bashrc, settings.json...)
# can be undone. If the content is identical it does nothing extra.
atomic_copy_keep_bak() {
    local src="$1" dest bak i=1
    dest=$(ms_resolve_dest "$2")
    [ -f "$src" ] || return 1
    if [ -f "$dest" ] && ! cmp -s -- "$src" "$dest"; then
        bak="$dest.mint-setup.bak"
        while [ -e "$bak" ]; do bak="$dest.mint-setup.bak.$i"; i=$((i + 1)); done
        atomic_copy "$dest" "$bak" || return 1
        recovery_journal_add "$bak"
    fi
    atomic_copy "$src" "$2"
}

# Records the recovery copy so "--uninstall --purge" can remove it.
recovery_journal_add() {
    ( umask 077; mkdir -p -- "$LANGUAGE_CONFIG_DIR" && printf '%q\n' "$1" >> "$RECOVERY_JOURNAL" ) 2>/dev/null || true
}

# Runs "$2..." and saves its standard output to "$1" ONLY if the command
# succeeds. If it fails, the destination is neither created nor touched (so a
# failed dump is never later mistaken for a legitimate empty dump).
atomic_capture() {
    local dest tmp
    dest=$(ms_resolve_dest "$1"); shift
    ms_mktemp tmp "$dest" || { restore_mark_failed; return 1; }
    if "$@" > "$tmp" && ms_set_mode "$tmp" "$dest" && ms_commit "$tmp" "$dest"; then
        return 0
    fi
    ms_tmp_discard "$tmp"
    restore_mark_failed
    return 1
}

# Checks that a .tar.gz is intact (it is fully decompressed) and that it
# contains no absolute paths or ".." components.
tar_archive_is_safe() {
    tar -tzf "$1" 2>/dev/null | awk '
        /^\// || /(^|\/)\.\.(\/|$)/ { bad = 1; exit }
        END { exit bad }
    '
}

# Creates the .tar.gz "$1" with the tar arguments "$2...". It is written to a
# temporary file and only published if the resulting archive is intact. tar
# returns 1 ("a file changed as it was being read") even when it produces a
# valid archive, so what decides is the verification; a code of 2 or more
# (fatal error, e.g. an unreadable file) is always rejected. The wrapper: see ms_tmp_track.
atomic_tar() {
    atomic_tar_run "$@"
    return $?
}

atomic_tar_run() {
    local dest tmp rc
    dest=$(ms_resolve_dest "$1"); shift
    ms_mktemp tmp "$dest" || return 1
    tar czf "$tmp" "$@" 2>/dev/null
    rc=$?
    if [ "$rc" -le 1 ] && tar -tzf "$tmp" >/dev/null 2>&1 && ms_commit "$tmp" "$dest"; then
        return 0
    fi
    ms_tmp_discard "$tmp"
    return 1
}

# Moves every item of the folder "$1" into "$2" with an atomic rename (they
# must be on the same filesystem). Folders that already exist are merged;
# files that already exist are replaced whole (or left alone if "$3" = keep).
# What was already in "$2" and is not in "$1" is kept, just as "tar x" did.
ms_merge_tree() {
    # LC_ALL=C: in a UTF-8 locale "read -d ''" swallows the NUL that follows a name
    # ending in an incomplete multibyte sequence (e.g. a Latin-1 "é") and drops the
    # NEXT entry, which the restore would then lose without any error.
    local LC_ALL=C
    local src="$1" dst="$2" mode="${3:-overwrite}" entry name rc=0 perm
    mkdir -p -- "$dst" || return 1
    while IFS= read -r -d '' entry; do
        name="${entry##*/}"
        if [ -d "$entry" ] && [ ! -L "$entry" ]; then
            # Moving a folder to another parent, or emptying it, needs rwx on it
            # (rename rewrites its ".."): a read-only one from the copy (0555) made
            # the restore fail and left the stage behind. It is ours, so it is
            # opened here and gets its stored mode back after the move.
            perm=""
            if ! { [ -r "$entry" ] && [ -w "$entry" ] && [ -x "$entry" ]; }; then
                perm=$(stat -c %a -- "$entry" 2>/dev/null) || perm=""
                chmod u+rwx -- "$entry" 2>/dev/null
            fi
            if [ -d "$dst/$name" ] && [ ! -L "$dst/$name" ]; then
                ms_merge_tree "$entry" "$dst/$name" "$mode" || rc=1
            elif [ -e "$dst/$name" ] || [ -L "$dst/$name" ]; then
                rc=1   # there was a file where the archive brings a folder
            elif mv -T -- "$entry" "$dst/$name"; then
                [ -z "$perm" ] || chmod "$perm" -- "$dst/$name" 2>/dev/null || rc=1
            else
                rc=1
            fi
        else
            if [ "$mode" = keep ] && { [ -e "$dst/$name" ] || [ -L "$dst/$name" ]; }; then
                continue
            fi
            if [ -d "$dst/$name" ] && [ ! -L "$dst/$name" ]; then
                rc=1   # there was a folder where the archive brings a file
                continue
            fi
            mv -f -T -- "$entry" "$dst/$name" || rc=1
        fi
    done < <(find "$src" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    return "$rc"
}

# Extracts the .tar.gz "$1" into the folder "$2" without ever touching the
# destination until the whole archive has been verified and extracted to a
# hidden temporary folder inside "$2". "$3" = keep does not overwrite what
# already exists. "$4" = number of leading path components dropped from every
# member (tar --strip-components): with 1, the CONTENT of the stored folder
# goes straight into "$2", whatever that folder was called. If the extraction
# worked but the final merge hit something it cannot replace, what did not
# clash IS already applied: it sets SAFE_EXTRACT_PARTIAL=1 so restore_problem
# does not say nothing was touched.
SAFE_EXTRACT_PARTIAL=0
safe_extract() {
    local archive="$1" parent="$2" mode="${3:-overwrite}" strip="${4:-0}" stage
    local -a strip_opt=()
    SAFE_EXTRACT_PARTIAL=0
    [ -f "$archive" ] || return 0
    tar_archive_is_safe "$archive" || return 1
    mkdir -p -- "$parent" || return 1
    ms_mktemp stage "$parent/stage" d || return 1
    [ "$strip" -gt 0 ] && strip_opt=(--strip-components="$strip")
    # -p: keeps the stored permissions (without it, umask 077 would trim them
    # and e.g. a world-readable file would end up readable by the user only).
    if tar xzpf "$archive" -C "$stage" "${strip_opt[@]+"${strip_opt[@]}"}" 2>/dev/null; then
        if ms_merge_tree "$stage" "$parent" "$mode"; then
            ms_tmp_discard "$stage"
            ms_fsync "$parent"
            return 0
        fi
        SAFE_EXTRACT_PARTIAL=1
        ms_fsync "$parent"
    fi
    ms_tmp_discard "$stage"
    restore_mark_failed
    return 1
}

# =============================================================================
# LANGUAGE
# =============================================================================

# An unset HOME would stop the script right here with a raw bash "unbound
# variable" error (set -u). It is defaulted to empty so that require_home
# (further down) reports it properly: unset and empty are the same problem.
: "${HOME=}"
LANGUAGE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mint-setup"
LANGUAGE_CONFIG_FILE="$LANGUAGE_CONFIG_DIR/language"
RECOVERY_JOURNAL="$LANGUAGE_CONFIG_DIR/recovery-copies.list"
APP_LANG=""

# -----------------------------------------------------------------------------
# Translation catalog ES → EN
# -----------------------------------------------------------------------------
# The source text of every visible string is in Spanish and goes through T()
# (or T_FMT() if it carries %s data or \n line breaks). With APP_LANG=es they
# return the text as is; with APP_LANG=en they look it up here. A string
# without an entry is shown in Spanish: add add_exact "<exact Spanish>" "<English>".
# -----------------------------------------------------------------------------
declare -A T_EXACT=()

add_exact() {
    T_EXACT["$1"]="$2"
}

add_exact "¿Qué deseas hacer?" "What do you want to do?"
add_exact "¿Qué deseas guardar?" "What do you want to save?"
add_exact "¿Qué deseas restaurar?" "What do you want to restore?"
add_exact "Nombre para esta configuración:" "Name for this configuration:"
add_exact "Selecciona una configuración guardada:" "Select a saved configuration:"
add_exact "Marca una o varias configuraciones guardadas:" "Select one or more saved configurations:"
add_exact "Idioma actual" "Current language"
add_exact "Cambiar idioma" "Change language"
add_exact "💾  Guardar configuración" "💾  Save configuration"
add_exact "♻️  Restaurar configuración" "♻️  Restore configuration"
add_exact "🔍  Comparar configuración" "🔍  Compare configuration"
add_exact "⚙️  Configuración avanzada" "⚙️  Advanced settings"
add_exact "🚪  Salir" "🚪  Exit"
add_exact "🌐  Cambiar idioma" "🌐  Change language"
add_exact "📂  Abrir carpeta de configuraciones guardadas" "📂  Open saved configurations folder"
add_exact "📤  Exportar copia a... (USB, disco externo...)" "📤  Export backup to... (USB, external drive...)"
add_exact "🗑️  Eliminar configuraciones guardadas" "🗑️  Delete saved configurations"
add_exact "🔐  Copia de seguridad del header LUKS" "🔐  Back up LUKS header"
add_exact "🚑  Restaurar header LUKS (emergencia)" "🚑  Restore LUKS header (emergency)"
add_exact "<b>%s</b> v%s\nAutor: Filonux\n\nGuarda y restaura la configuración del entorno de escritorio en Linux Mint (Cinnamon): paneles, applets, apariencia, Nemo, aplicaciones instaladas, aplicaciones de inicio, pantallas, sonido, red, bluetooth, teclado, ratón y touchpad. También guarda la configuración propia de aplicaciones concretas: Firefox, LibreWolf, Thunderbird, LibreOffice, ONLYOFFICE, VS Code, Docker y la terminal.\n\nNo sustituye a Timeshift ni a MintBackup: los complementa.\n• Timeshift recupera el sistema.\n• MintBackup recupera archivos personales.\n• %s reconstruye el entorno de trabajo.\n\nLos módulos Red y Bluetooth piden permisos de administrador tanto al guardar como al restaurar, y pueden contener credenciales (contraseñas Wi-Fi, claves de emparejamiento). El módulo Docker los pide solo para la parte del daemon y el grupo docker.\n\nConfiguración avanzada añade copia de seguridad y restauración de emergencia del header LUKS de discos cifrados (también requiere administrador).\n\nLas configuraciones guardadas se almacenan en:\n%s" "<b>%s</b> v%s\nAuthor: Filonux\n\nSaves and restores the desktop environment configuration on Linux Mint (Cinnamon): panels, applets, appearance, Nemo, installed applications, startup applications, displays, sound, network, Bluetooth, keyboard, mouse and touchpad. It also saves application-specific configuration for Firefox, LibreWolf, Thunderbird, LibreOffice, ONLYOFFICE, VS Code, Docker and the terminal.\n\nIt does not replace Timeshift or MintBackup: it complements them.\n• Timeshift restores the system.\n• MintBackup restores personal files.\n• %s rebuilds your working environment.\n\nThe Network and Bluetooth modules request administrator privileges when saving and restoring, and may contain credentials (Wi-Fi passwords, pairing keys). Docker requests administrator privileges only for the daemon and docker group.\n\nAdvanced settings also provide emergency backup and restoration of the LUKS header for encrypted disks (administrator privileges required).\n\nSaved configurations are stored in:\n%s"
add_exact "Módulo" "Module"
add_exact "Descripción" "Description"
add_exact "Configuración" "Configuration"
add_exact "Acción" "Action"
add_exact "Dispositivo" "Device"
add_exact "Tamaño" "Size"
add_exact "tamaño desconocido" "unknown size"
add_exact "Sel" "Select"
add_exact "Ruta" "Path"
add_exact "Op" "Opt."
add_exact "Restaurando configuración..." "Restoring configuration..."
add_exact "Guardando configuración..." "Saving configuration..."
add_exact "Elige dónde exportar la copia (USB, disco externo...)" "Choose where to export the backup (USB, external drive...)"
add_exact "Ruta del dispositivo (p. ej. /dev/sdb1):" "Device path (e.g. /dev/sdb1):"
add_exact "Cambios detectados" "Detected changes"
add_exact "Comparando el sistema actual con:" "Comparing the current system with:"
add_exact "No se han detectado cambios relevantes en las áreas guardadas." "No relevant changes were detected in the saved areas."
add_exact "Restaurando..." "Restoring..."
add_exact "Escritorio Cinnamon (posición/tamaño de paneles y barra de tareas, applets —incl. icono del menú—, desklets, extensiones, workspaces...)" "Cinnamon desktop (panel and taskbar position/size, applets —including the menu icon—, desklets, extensions, workspaces...)"
add_exact "Apariencia (tema de Cinnamon y de ventanas, iconos, cursor y fuentes completos, modo claro/oscuro, fondo, protector de pantalla)" "Appearance (Cinnamon and window themes, icons, cursor and fonts, light/dark mode, wallpaper, screensaver)"
add_exact "Nemo (accesos directos de escritorio y menú, marcadores, scripts, acciones, preferencias)" "Nemo (desktop and menu shortcuts, bookmarks, scripts, actions, preferences)"
add_exact "Aplicaciones (paquetes APT, Flatpak, repositorios adicionales)" "Applications (APT packages, Flatpak, additional repositories)"
add_exact "Aplicaciones de inicio (programas que se lanzan automáticamente al iniciar sesión)" "Startup Applications (programs launched automatically when you sign in)"
add_exact "Pantallas (resolución y disposición de monitores)" "Displays (monitor resolution and layout)"
add_exact "Sonido (tema de sonido, dispositivo de salida/entrada)" "Sound (sound theme, output/input device)"
add_exact "Mint-Setup - Comparador" "Mint-Setup - Compare"
add_exact "Mint-Setup - Exportar" "Mint-Setup - Export"
add_exact "Mint-Setup - Confirmación requerida" "Mint-Setup - Confirmation required"
add_exact "Mint-Setup - Header LUKS" "Mint-Setup - LUKS header"
add_exact "Mint-Setup - Elige la copia del header LUKS" "Mint-Setup - Choose the LUKS header backup"
add_exact "Todos los archivos | *" "All files | *"
add_exact " · quedan %s" " · %s left"
add_exact " · terminando..." " · finishing..."
add_exact " · tardando más de lo previsto (+%s)" " · taking longer than expected (+%s)"
add_exact "Red (conexiones NetworkManager — incluye contraseñas Wi-Fi en texto plano) ⚠️ requiere administrador" "Network (NetworkManager connections — includes Wi-Fi passwords in plain text) ⚠️ requires administrator privileges"
add_exact "Bluetooth (dispositivos emparejados) ⚠️ requiere administrador" "Bluetooth (paired devices) ⚠️ requires administrator privileges"
add_exact "Teclado (distribución, opciones XKB, repetición/retardo)" "Keyboard (layout, XKB options, repeat/delay)"
add_exact "Ratón (velocidad, aceleración, botones)" "Mouse (speed, acceleration, buttons)"
add_exact "Touchpad (toque para pulsar, scroll, gestos)" "Touchpad (tap-to-click, scrolling, gestures)"
add_exact "Firefox (perfil completo: marcadores, extensiones, preferencias) ⚠️ incluye contraseñas guardadas" "Firefox (full profile: bookmarks, extensions, preferences) ⚠️ includes saved passwords"
add_exact "LibreWolf (perfil completo: marcadores, extensiones, preferencias) ⚠️ incluye contraseñas guardadas" "LibreWolf (full profile: bookmarks, extensions, preferences) ⚠️ includes saved passwords"
add_exact "Thunderbird (cuentas, filtros, libreta de direcciones, extensiones) ⚠️ incluye contraseñas de correo" "Thunderbird (accounts, filters, address book, extensions) ⚠️ includes email passwords"
add_exact "LibreOffice (plantillas, autocorrección, extensiones, barras de herramientas)" "LibreOffice (templates, AutoCorrect, extensions, toolbars)"
add_exact "ONLYOFFICE (configuración de usuario y plugins de Desktop Editors)" "ONLYOFFICE (user settings and Desktop Editors plugins)"
add_exact "VS Code (extensiones instaladas, settings.json, keybindings, snippets, perfiles)" "VS Code (installed extensions, settings.json, keybindings, snippets, profiles)"
add_exact "Docker (config. de usuario y del daemon, grupo docker) ⚠️ parte requiere administrador" "Docker (user and daemon configuration, docker group membership) ⚠️ some operations require administrator privileges"
add_exact "Terminal (perfiles de GNOME Terminal, .bashrc/.zshrc y archivos de shell)" "Terminal (GNOME Terminal profiles, .bashrc/.zshrc and shell configuration files)"
add_exact "Escritorio Cinnamon" "Cinnamon desktop"
add_exact "Apariencia" "Appearance"
add_exact "Aplicaciones" "Applications"
add_exact "Aplicaciones de inicio" "Startup Applications"
add_exact "Pantallas" "Displays"
add_exact "Sonido" "Sound"
add_exact "Red" "Network"
add_exact "Bluetooth" "Bluetooth"
add_exact "Teclado" "Keyboard"
add_exact "Ratón" "Mouse"
add_exact "Aplicaciones restauradas." "Applications restored."
add_exact "Aplicaciones de inicio guardadas." "Startup applications saved."
add_exact "Aplicaciones de inicio restauradas." "Startup applications restored."
add_exact "Ratón guardado." "Mouse saved."
add_exact "Ratón restaurado." "Mouse restored."
add_exact "Conexiones de red guardadas." "Network connections saved."
add_exact "Conexiones de red restauradas." "Network connections restored."
add_exact "Bluetooth guardado." "Bluetooth saved."
add_exact "Bluetooth restaurado." "Bluetooth restored."
add_exact "Escritorio Cinnamon guardado." "Cinnamon desktop saved."
add_exact "No hay datos de escritorio en esta configuración guardada." "There is no desktop data in this saved configuration."
add_exact "Restaurando icono de menú personalizado..." "Restoring custom menu icon..."
add_exact "Escritorio Cinnamon restaurado. Puede que necesites reiniciar Cinnamon (Ctrl+Alt+Esc) o cerrar sesión." "Cinnamon desktop restored. You may need to restart Cinnamon (Ctrl+Alt+Esc) or sign out."
add_exact "Guardando tema, iconos, cursor y fuentes..." "Saving theme, icons, cursor and fonts..."
add_exact "Guardando archivos de temas GTK/Cinnamon instalados por el usuario..." "Saving user-installed GTK/Cinnamon theme files..."
add_exact "Guardando archivos de temas de iconos y cursor instalados por el usuario..." "Saving user-installed icon and cursor theme files..."
add_exact "Guardando fuentes instaladas por el usuario..." "Saving user-installed fonts..."
add_exact "No hay datos de apariencia en esta configuración guardada." "There is no appearance data in this saved configuration."
add_exact "Restaurando fuentes instaladas por el usuario..." "Restoring user-installed fonts..."
add_exact "Aviso: fc-cache no está disponible; puede que las fuentes no se vean hasta reiniciar sesión." "Warning: fc-cache is not available; the fonts may not appear until you sign out or restart the session."
add_exact "Restaurando tema, iconos, cursor y fuentes..." "Restoring theme, icons, cursor and fonts..."
add_exact "Guardando preferencias de Nemo..." "Saving Nemo preferences..."
add_exact "Guardando scripts de Nemo..." "Saving Nemo scripts..."
add_exact "Guardando lanzadores personalizados (menú, AppImages, etc.)..." "Saving custom launchers (menu, AppImages, etc.)..."
add_exact "Guardando marcadores de la barra lateral de Nemo..." "Saving Nemo sidebar bookmarks..."
add_exact "Nemo guardado." "Nemo saved."
add_exact "No hay datos de Nemo en esta configuración guardada." "There is no Nemo data in this saved configuration."
add_exact "Restaurando preferencias de Nemo..." "Restoring Nemo preferences..."
add_exact "Restaurando scripts de Nemo..." "Restoring Nemo scripts..."
add_exact "Aviso: no se pudo marcar algún acceso directo como de confianza (esto es normal si lo ejecutas fuera de una sesión de escritorio real, p. ej. por SSH). Ábrelo una vez desde Nemo y elige 'Confiar y lanzar' si hace falta." "Warning: some shortcuts could not be marked as trusted (this is normal when running outside a real desktop session, e.g. over SSH). Open it once from Nemo and choose 'Trust and Launch' if needed."
add_exact "Nota: si el Escritorio no muestra todavía el icono como de confianza, pulsa F5 sobre él para refrescar la vista; Nemo no siempre lo redibuja solo." "Note: if the Desktop still does not show the icon as trusted, press F5 to refresh the view; Nemo does not always redraw it automatically."
add_exact "Aviso: gio no está disponible; puede que tengas que autorizar cada acceso directo del Escritorio manualmente (clic derecho > Permitir lanzamiento)." "Warning: gio is not available; you may need to authorize each Desktop shortcut manually (right-click > Allow Launching)."
add_exact "Restaurando lanzadores personalizados (sin sobrescribir archivos existentes)..." "Restoring custom launchers (without overwriting existing files)..."
add_exact "Restaurando marcadores de la barra lateral de Nemo..." "Restoring Nemo sidebar bookmarks..."
add_exact "Nemo restaurado." "Nemo restored."
add_exact "No hay datos de aplicaciones en esta configuración guardada." "There is no application data in this saved configuration."
add_exact "Restaurando repositorios adicionales (se pedirá contraseña de administrador)..." "Restoring additional repositories (you will be prompted for the administrator password)..."
add_exact "Aviso: no se pudieron restaurar los repositorios (permisos denegados o cancelado)." "Warning: the repositories could not be restored (permission denied or cancelled)."
add_exact "Aviso: los repositorios se restauraron, pero «apt-get update» terminó con errores (algún repositorio puede haber dejado de existir o no responder)." "Warning: the repositories were restored, but “apt-get update” finished with errors (a repository may no longer exist or may not be responding)."
add_exact "Aviso: pkexec no está disponible; no se pueden restaurar los repositorios automáticamente." "Warning: pkexec is not available; the repositories cannot be restored automatically."
add_exact "Aviso: algunos paquetes APT no se pudieron instalar." "Warning: some APT packages could not be installed."
add_exact "Guardando aplicaciones de inicio..." "Saving startup applications..."
add_exact "No hay datos de aplicaciones de inicio en esta configuración guardada." "There is no startup application data in this saved configuration."
add_exact "Pantallas guardadas." "Displays saved."
add_exact "No hay datos de pantallas en esta configuración guardada." "There is no display data in this saved configuration."
add_exact "Restaurando distribución de monitores..." "Restoring monitor layout..."
add_exact "Pantallas restauradas." "Displays restored."
add_exact "Nota: monitors.xml está ligado al identificador (EDID) de cada monitor;" "Note: monitors.xml is tied to each monitor's identifier (EDID);"
add_exact "si el hardware de pantalla ha cambiado, puede que tengas que reajustar" "if the display hardware has changed, you may need to adjust"
add_exact "la distribución desde Configuración > Pantallas." "the layout from Settings > Displays."
add_exact "Aviso: pactl no está instalado; solo se guarda el tema de sonido, no el dispositivo predeterminado." "Warning: pactl is not installed; only the sound theme is saved, not the default device."
add_exact "No hay datos de sonido en esta configuración guardada." "There is no sound data in this saved configuration."
add_exact "Aviso: no se pudo restaurar el dispositivo de salida (puede que ya no exista)." "Warning: the output device could not be restored (it may no longer exist)."
add_exact "Aviso: no se pudo restaurar el dispositivo de entrada (puede que ya no exista)." "Warning: the input device could not be restored (it may no longer exist)."
add_exact "Aviso: pactl no está instalado; no se restaura el dispositivo predeterminado." "Warning: pactl is not installed; the default device will not be restored."
add_exact "Aviso: pkexec no está disponible; no se puede guardar la configuración de red (requiere acceso root)." "Warning: pkexec is not available; network configuration cannot be saved (root access required)."
add_exact "Guardando conexiones de NetworkManager (se pedirá contraseña de administrador)..." "Saving NetworkManager connections (you will be prompted for the administrator password)..."
add_exact "No hay datos de red en esta configuración guardada." "There is no network data in this saved configuration."
add_exact "Aviso: pkexec no está disponible; no se puede restaurar la configuración de red (requiere acceso root)." "Warning: pkexec is not available; network configuration cannot be restored (root access required)."
add_exact "Restaurando conexiones de NetworkManager, sin sobrescribir las existentes (se pedirá contraseña de administrador)..." "Restoring NetworkManager connections without overwriting existing ones (you will be prompted for the administrator password)..."
add_exact "Aviso: el archivo de conexiones de red guardado está dañado o incompleto; no se pudo restaurar." "Warning: the saved network connections file is damaged or incomplete; it could not be restored."
add_exact "Aviso: pkexec no está disponible; no se puede guardar la configuración de Bluetooth (requiere acceso root)." "Warning: pkexec is not available; Bluetooth configuration cannot be saved (root access required)."
add_exact "Guardando dispositivos Bluetooth emparejados (se pedirá contraseña de administrador)..." "Saving paired Bluetooth devices (you will be prompted for the administrator password)..."
add_exact "No hay datos de Bluetooth en esta configuración guardada." "There is no Bluetooth data in this saved configuration."
add_exact "Aviso: pkexec no está disponible; no se puede restaurar Bluetooth (requiere acceso root)." "Warning: pkexec is not available; Bluetooth cannot be restored (root access required)."
add_exact "Restaurando dispositivos Bluetooth emparejados, sin sobrescribir los existentes (se pedirá contraseña de administrador)..." "Restoring paired Bluetooth devices without overwriting existing ones (you will be prompted for the administrator password)..."
add_exact "Aviso: el archivo de Bluetooth guardado está dañado o incompleto; no se pudo restaurar." "Warning: the saved Bluetooth file is damaged or incomplete; it could not be restored."
add_exact "Teclado guardado." "Keyboard saved."
add_exact "No hay datos de teclado en esta configuración guardada." "There is no keyboard data in this saved configuration."
add_exact "Restaurando distribución(es) de teclado..." "Restoring keyboard layouts..."
add_exact "Teclado restaurado." "Keyboard restored."
add_exact "Guardando configuración del ratón..." "Saving mouse configuration..."
add_exact "No hay datos de ratón en esta configuración guardada." "There is no mouse data in this saved configuration."
add_exact "Restaurando configuración del ratón..." "Restoring mouse configuration..."
add_exact "Guardando configuración del touchpad..." "Saving touchpad configuration..."
add_exact "No hay datos de touchpad en esta configuración guardada." "There is no touchpad data in this saved configuration."
add_exact "Restaurando configuración del touchpad..." "Restoring touchpad configuration..."
add_exact "Firefox no está instalado o no tiene perfiles en este equipo." "Firefox is not installed or has no profiles on this computer."
add_exact "Aviso: Firefox está abierto. Ciérralo y vuelve a guardar para evitar una copia inconsistente del perfil." "Warning: Firefox is open. Close it and save again to avoid an inconsistent profile backup."
add_exact "Guardando perfil(es) de Firefox (marcadores, extensiones, preferencias)..." "Saving Firefox profiles (bookmarks, extensions, preferences)..."
add_exact "No hay datos de Firefox en esta configuración guardada." "There is no Firefox data in this saved configuration."
add_exact "Aviso: Firefox está abierto; ciérralo y vuelve a restaurar para evitar corromper el perfil. Este módulo se ha omitido." "Warning: Firefox is open; close it and restore again to avoid corrupting the profile. This module was skipped."
add_exact "Restaurando perfil(es) de Firefox (marcadores, extensiones, preferencias)..." "Restoring Firefox profiles (bookmarks, extensions, preferences)..."
add_exact "Firefox restaurado. Ábrelo para comprobar que carga el perfil correctamente." "Firefox restored. Open it to check that the profile loads correctly."
add_exact "LibreWolf no está instalado o no tiene perfiles en este equipo." "LibreWolf is not installed or has no profiles on this computer."
add_exact "Aviso: LibreWolf está abierto. Ciérralo y vuelve a guardar para evitar una copia inconsistente del perfil." "Warning: LibreWolf is open. Close it and save again to avoid an inconsistent profile backup."
add_exact "Guardando perfil(es) de LibreWolf (marcadores, extensiones, preferencias)..." "Saving LibreWolf profiles (bookmarks, extensions, preferences)..."
add_exact "No hay datos de LibreWolf en esta configuración guardada." "There is no LibreWolf data in this saved configuration."
add_exact "Aviso: LibreWolf está abierto; ciérralo y vuelve a restaurar para evitar corromper el perfil. Este módulo se ha omitido." "Warning: LibreWolf is open; close it and restore again to avoid corrupting the profile. This module was skipped."
add_exact "Restaurando perfil(es) de LibreWolf (marcadores, extensiones, preferencias)..." "Restoring LibreWolf profiles (bookmarks, extensions, preferences)..."
add_exact "LibreWolf restaurado. Ábrelo para comprobar que carga el perfil correctamente." "LibreWolf restored. Open it to check that the profile loads correctly."
add_exact "Thunderbird no está instalado o no tiene perfiles en este equipo." "Thunderbird is not installed or has no profiles on this computer."
add_exact "Aviso: Thunderbird está abierto. Ciérralo y vuelve a guardar para evitar una copia inconsistente del perfil." "Warning: Thunderbird is open. Close it and save again to avoid an inconsistent profile backup."
add_exact "Guardando perfil(es) de Thunderbird (cuentas, filtros, libreta de direcciones, extensiones)..." "Saving Thunderbird profiles (accounts, filters, address book, extensions)..."
add_exact "Thunderbird guardado." "Thunderbird saved."
add_exact "No hay datos de Thunderbird en esta configuración guardada." "There is no Thunderbird data in this saved configuration."
add_exact "Aviso: Thunderbird está abierto; ciérralo y vuelve a restaurar para evitar corromper el perfil. Este módulo se ha omitido." "Warning: Thunderbird is open; close it and restore again to avoid corrupting the profile. This module was skipped."
add_exact "Restaurando perfil(es) de Thunderbird (cuentas, filtros, libreta de direcciones, extensiones)..." "Restoring Thunderbird profiles (accounts, filters, address book, extensions)..."
add_exact "Thunderbird restaurado. Ábrelo para comprobar que carga el perfil correctamente." "Thunderbird restored. Open it to check that the profile loads correctly."
add_exact "LibreOffice no tiene configuración de usuario en este equipo." "LibreOffice has no user configuration on this computer."
add_exact "Aviso: LibreOffice está abierto (o el inicio rápido activo). Ciérralo del todo y vuelve a guardar para evitar una copia inconsistente." "Warning: LibreOffice is open (or quickstarter is active). Close it completely and save again to avoid an inconsistent backup."
add_exact "Guardando configuración de usuario de LibreOffice..." "Saving LibreOffice user configuration..."
add_exact "No hay datos de LibreOffice en esta configuración guardada." "There is no LibreOffice data in this saved configuration."
add_exact "Aviso: LibreOffice está abierto (o el inicio rápido activo); ciérralo del todo y vuelve a restaurar. Este módulo se ha omitido." "Warning: LibreOffice is open (or quickstarter is active); close it completely and restore again. This module was skipped."
add_exact "Restaurando configuración de usuario de LibreOffice..." "Restoring LibreOffice user configuration..."
add_exact "LibreOffice guardado." "LibreOffice saved."
add_exact "LibreOffice restaurado." "LibreOffice restored."
add_exact "ONLYOFFICE no tiene configuración de usuario en este equipo." "ONLYOFFICE has no user configuration on this computer."
add_exact "Aviso: ONLYOFFICE Desktop Editors está abierto. Ciérralo y vuelve a guardar para evitar una copia inconsistente." "Warning: ONLYOFFICE Desktop Editors is open. Close it and save again to avoid an inconsistent backup."
add_exact "Guardando configuración de usuario de ONLYOFFICE..." "Saving ONLYOFFICE user configuration..."
add_exact "Guardando plugins de ONLYOFFICE instalados por el usuario..." "Saving user-installed ONLYOFFICE plugins..."
add_exact "No hay datos de ONLYOFFICE en esta configuración guardada." "There is no ONLYOFFICE data in this saved configuration."
add_exact "Aviso: ONLYOFFICE Desktop Editors está abierto; ciérralo y vuelve a restaurar. Este módulo se ha omitido." "Warning: ONLYOFFICE Desktop Editors is open; close it and restore again. This module was skipped."
add_exact "Restaurando configuración de usuario de ONLYOFFICE..." "Restoring ONLYOFFICE user configuration..."
add_exact "Restaurando plugins de ONLYOFFICE..." "Restoring ONLYOFFICE plugins..."
add_exact "VS Code no está instalado en este equipo." "VS Code is not installed on this computer."
add_exact "Guardando lista de extensiones instaladas..." "Saving list of installed extensions..."
add_exact "Aviso: no se encontró el comando 'code' en el PATH; no se puede guardar la lista de extensiones (sí se guardarán settings.json y demás)." "Warning: the 'code' command was not found in PATH; the extension list cannot be saved (settings.json and the rest will still be saved)."
add_exact "Guardando perfiles con nombre de VS Code..." "Saving named VS Code profiles..."
add_exact "No hay datos de VS Code en esta configuración guardada." "There is no VS Code data in this saved configuration."
add_exact "Instalando extensiones de VS Code..." "Installing VS Code extensions..."
add_exact "Aviso: alguna extensión no se pudo instalar (revisa el detalle anterior); puede haberse retirado del marketplace o cambiado de identificador." "Warning: an extension could not be installed (see the previous details); it may have been removed from the marketplace or its identifier may have changed."
add_exact "Aviso: VS Code no está instalado (o 'code' no está en el PATH); instala VS Code y vuelve a restaurar este módulo para recuperar las extensiones." "Warning: VS Code is not installed (or 'code' is not in PATH); install VS Code and restore this module again to recover the extensions."
add_exact "Restaurando perfiles con nombre de VS Code..." "Restoring named VS Code profiles..."
add_exact "VS Code restaurado. Si estaba abierto, reinícialo para que cargue los cambios." "VS Code restored. If it was open, restart it to load the changes."
add_exact "Aviso: VS Code se restauró parcialmente; revisa los avisos anteriores." "Warning: VS Code was only partially restored; review the previous warnings."
add_exact "Docker no está instalado en este equipo." "Docker is not installed on this computer."
add_exact "Guardando configuración del daemon de Docker..." "Saving Docker daemon configuration..."
add_exact "Aviso: no se pudo leer /etc/docker/daemon.json (sin permisos de lectura y pkexec no disponible)." "Warning: /etc/docker/daemon.json could not be read (no read permission and pkexec is not available)."
add_exact "Guardando configuración de Docker CLI del usuario (contexts, config.json)..." "Saving user Docker CLI configuration (contexts, config.json)..."
add_exact "No hay datos de Docker en esta configuración guardada." "There is no Docker data in this saved configuration."
add_exact "Restaurando configuración del daemon de Docker (se pedirá contraseña de administrador)..." "Restoring Docker daemon configuration (you will be prompted for the administrator password)..."
add_exact "Aviso: no se pudo restaurar /etc/docker/daemon.json (permisos denegados o cancelado)." "Warning: /etc/docker/daemon.json could not be restored (permission denied or cancelled)."
add_exact "Aviso: /etc/docker/daemon.json se restauró, pero Docker no se pudo reiniciar; revisa «systemctl status docker»." "Warning: /etc/docker/daemon.json was restored, but Docker could not be restarted; check “systemctl status docker”."
add_exact "Aviso: «daemon.json» de la copia no es un archivo normal (por ejemplo, un enlace simbólico); no se restaura." "Warning: “daemon.json” in the backup is not a regular file (for example, a symbolic link); it is not restored."
add_exact "Restaurando configuración de Docker CLI del usuario..." "Restoring user Docker CLI configuration..."
add_exact "Tu usuario ya pertenece al grupo docker." "Your user is already a member of the docker group."
add_exact "Añadiendo tu usuario al grupo docker (se pedirá contraseña de administrador)..." "Adding your user to the docker group (you will be prompted for the administrator password)..."
add_exact "Hecho. Cierra sesión y vuelve a entrar para que el cambio de grupo surta efecto." "Done. Sign out and back in for the group change to take effect."
add_exact "Aviso: no se pudo añadir tu usuario al grupo docker (permisos denegados o cancelado)." "Warning: your user could not be added to the docker group (permission denied or cancelled)."
add_exact "Aviso: pkexec no está disponible; añádete al grupo manualmente con: sudo usermod -aG docker \$USER" "Warning: pkexec is not available; add yourself to the group manually with: sudo usermod -aG docker \$USER"
add_exact "Aviso: el grupo 'docker' no existe todavía en este equipo; instala el paquete docker.io/docker-ce antes de añadir el usuario al grupo." "Warning: the 'docker' group does not exist on this computer yet; install docker.io/docker-ce before adding the user to the group."
add_exact "Guardando perfiles de GNOME Terminal (colores, fuente, atajos)..." "Saving GNOME Terminal profiles (colors, font, shortcuts)..."
add_exact "Guardando archivos de configuración de la shell..." "Saving shell configuration files..."
add_exact "Guardando configuración de Starship..." "Saving Starship configuration..."
add_exact "No hay datos de terminal en esta configuración guardada." "There is no terminal data in this saved configuration."
add_exact "Restaurando perfiles de GNOME Terminal (colores, fuente, atajos)..." "Restoring GNOME Terminal profiles (colors, font, shortcuts)..."
add_exact "Restaurando archivos de configuración de la shell..." "Restoring shell configuration files..."
add_exact "Restaurando configuración de Starship..." "Restoring Starship configuration..."
add_exact "Terminal restaurada. Abre una nueva pestaña o ventana para ver los cambios." "Terminal restored. Open a new tab or window to see the changes."
add_exact "• El tema ha cambiado" "• The theme has changed"
add_exact "• Los iconos han cambiado" "• The icons have changed"
add_exact "• Ha cambiado la lista de applets del panel" "• The panel applet list has changed"
add_exact "Todavía no hay ninguna configuración guardada." "There are no saved configurations yet."
add_exact "Guardando árbol de configuración de Cinnamon..." "Saving the Cinnamon configuration tree..."
add_exact "Guardando applets/desklets/extensiones instalados por el usuario..." "Saving user-installed applets/desklets/extensions..."
add_exact "Guardando ajustes de applets/desklets (icono del menú y demás)..." "Saving applet/desklet settings (menu icon and other settings)..."
add_exact "Guardando icono de menú personalizado (si lo hay)..." "Saving custom menu icon (if present)..."
add_exact "Restaurando applets..." "Restoring applets..."
add_exact "Restaurando desklets..." "Restoring desklets..."
add_exact "Restaurando extensiones..." "Restoring extensions..."
add_exact "Restaurando ajustes de applets/desklets (icono del menú y demás)..." "Restoring applet/desklet settings (menu icon and other settings)..."
add_exact "Restaurando árbol de configuración de Cinnamon..." "Restoring the Cinnamon configuration tree..."
add_exact "Guardando preferencia de modo claro/oscuro..." "Saving light/dark mode preference..."
add_exact "Guardando tema de Cinnamon (Escritorio)..." "Saving Cinnamon theme (Desktop)..."
add_exact "Guardando tema de ventanas..." "Saving window theme..."
add_exact "Guardando protector de pantalla..." "Saving screensaver..."
add_exact "Guardando configuración del fondo de pantalla..." "Saving wallpaper settings..."
add_exact "Guardando configuración GTK3..." "Saving GTK3 configuration..."
add_exact "Apariencia guardada." "Appearance saved."
add_exact "Restaurando archivos de temas GTK/Cinnamon..." "Restoring GTK/Cinnamon theme files..."
add_exact "Restaurando archivos de temas de iconos y cursor..." "Restoring icon and cursor theme files..."
add_exact "Restaurando preferencia de modo claro/oscuro..." "Restoring light/dark mode preference..."
add_exact "Restaurando tema de Cinnamon (Escritorio)..." "Restoring Cinnamon theme (Desktop)..."
add_exact "Restaurando tema de ventanas..." "Restoring window theme..."
add_exact "Restaurando protector de pantalla..." "Restoring screensaver..."
add_exact "Restaurando fondo de pantalla..." "Restoring wallpaper..."
add_exact "Restaurando configuración GTK3..." "Restoring GTK3 configuration..."
add_exact "Apariencia restaurada." "Appearance restored."
add_exact "Guardando acciones personalizadas..." "Saving custom actions..."
add_exact "Guardando contenido del Escritorio (accesos directos incluidos)..." "Saving Desktop contents (including shortcuts)..."
add_exact "Nota: la posición exacta de los iconos del escritorio depende de los metadatos internos (GVFS) ligados a cada instalación, así que no se puede garantizar al 100% tras una instalación limpia." "Note: the exact position of desktop icons depends on internal GVFS metadata tied to each installation, so an exact layout cannot be guaranteed 100% after a clean installation."
add_exact "Restaurando acciones personalizadas..." "Restoring custom actions..."
add_exact "Restaurando accesos directos del Escritorio (sin sobrescribir archivos existentes)..." "Restoring Desktop shortcuts (without overwriting existing files)..."
add_exact "Marcando los accesos directos del Escritorio como de confianza..." "Marking Desktop shortcuts as trusted..."
add_exact "Guardando paquetes APT instalados manualmente..." "Saving manually installed APT packages..."
add_exact "Guardando repositorios Flatpak (remotes)..." "Saving Flatpak repositories (remotes)..."
add_exact "Guardando aplicaciones Flatpak..." "Saving Flatpak applications..."
add_exact "Guardando repositorios adicionales..." "Saving additional repositories..."
add_exact "Comprobando qué paquetes siguen disponibles en los repositorios..." "Checking which packages are still available in the repositories..."
add_exact "Aviso: ninguno de los paquetes guardados está disponible para instalar." "Warning: none of the saved packages are available to install."
add_exact "Añadiendo repositorios Flatpak (remotes)..." "Adding Flatpak repositories (remotes)..."
add_exact "Instalando aplicaciones Flatpak..." "Installing Flatpak applications..."
add_exact "Guardando distribución de monitores..." "Saving monitor layout..."
add_exact "Guardando configuración del plugin xrandr..." "Saving xrandr plugin configuration..."
add_exact "Restaurando configuración del plugin xrandr..." "Restoring xrandr plugin configuration..."
add_exact "Guardando tema de sonido y eventos..." "Saving sound theme and events..."
add_exact "Guardando dispositivo de salida/entrada predeterminado..." "Saving default output/input device..."
add_exact "Sonido guardado." "Sound saved."
add_exact "Restaurando tema de sonido y eventos..." "Restoring sound theme and events..."
add_exact "Restaurando dispositivo de salida predeterminado..." "Restoring default output device..."
add_exact "Restaurando dispositivo de entrada predeterminado..." "Restoring default input device..."
add_exact "Sonido restaurado." "Sound restored."
add_exact "Guardando distribución(es) de teclado y opciones XKB..." "Saving keyboard layouts and XKB options..."
add_exact "Guardando velocidad de repetición y retardo..." "Saving repeat rate and delay..."
add_exact "Restaurando velocidad de repetición y retardo..." "Restoring repeat rate and delay..."
add_exact "Touchpad guardado." "Touchpad saved."
add_exact "Touchpad restaurado." "Touchpad restored."
add_exact "Firefox guardado." "Firefox saved."
add_exact "LibreWolf guardado." "LibreWolf saved."
add_exact "Nota: si alguna cuenta usa POP3 sin 'dejar copia en el servidor', el correo local guardado aquí puede ser la única copia que existe; con IMAP el correo vive en el servidor y esto es solo una caché." "Note: if an account uses POP3 without 'leave a copy on the server', the local mail saved here may be the only copy that exists; with IMAP, mail remains on the server and this is only a cache."
add_exact "ONLYOFFICE guardado." "ONLYOFFICE saved."
add_exact "ONLYOFFICE restaurado." "ONLYOFFICE restored."
add_exact "Guardando settings.json, keybindings.json y snippets..." "Saving settings.json, keybindings.json and snippets..."
add_exact "VS Code guardado." "VS Code saved."
add_exact "Restaurando settings.json y keybindings.json..." "Restoring settings.json and keybindings.json..."
add_exact "Restaurando snippets..." "Restoring snippets..."
add_exact "Docker guardado." "Docker saved."
add_exact "Nota: si tu ~/.docker/config.json guarda credenciales de registros sin un 'credential helper' (campo \"auths\" con contraseñas en base64 en vez de \"credsStore\"), esta copia contendrá esas credenciales. Protege bien la carpeta de copia de seguridad." "Note: if your ~/.docker/config.json stores registry credentials without a 'credential helper' (the \"auths\" field contains base64 passwords instead of \"credsStore\"), this backup will contain those credentials. Keep the backup folder protected."
add_exact "Aviso: Docker no está instalado en este equipo; instálalo y vuelve a restaurar este módulo." "Warning: Docker is not installed on this computer; install it and restore this module again."
add_exact "Docker restaurado." "Docker restored."
add_exact "Terminal guardada." "Terminal saved."
add_exact "No se ha concedido la contraseña de administrador.\\n\\nAlgún módulo puede fallar o volver a pedirla más adelante; el resto se guardará igualmente." "Administrator authentication was not granted.\\n\\nA module may fail or ask for it again later; the rest will still be saved."
add_exact "Esta configuración guardada no contiene datos restaurables." "This saved configuration contains no restorable data."
add_exact "No se ha concedido la contraseña de administrador.\\n\\nLos módulos que la necesitan (Red, Bluetooth, Docker, Aplicaciones) pueden fallar o volver a pedirla más adelante; el resto se restaurará igualmente." "Administrator authentication was not granted.\\n\\nThe modules that need it (Network, Bluetooth, Docker, Applications) may fail or ask for it again later; the rest will still be restored."
add_exact "No se pudo mostrar la barra de progreso de Restaurar (¿hay una sesión gráfica activa?)." "Could not show the Restore progress bar (is an active graphical session available?)."
add_exact "No se pudo crear una carpeta temporal. Comprueba que hay espacio libre en el disco." "Could not create a temporary folder. Check that there is free space on the disk."
add_exact "No se pudo crear el archivo temporal." "Could not create the temporary file."
add_exact "Configuración restaurada.\\n\\nEs posible que necesites cerrar sesión o reiniciar Cinnamon (Ctrl+Alt+Esc) para ver todos los cambios." "Configuration restored.\\n\\nYou may need to sign out or restart Cinnamon (Ctrl+Alt+Esc) to see all changes."
add_exact "• Nuevo fondo de pantalla" "• Wallpaper changed"
add_exact "No se ha detectado ningún dispositivo cifrado con LUKS en este equipo.\\n\\n¿Quieres indicar la ruta manualmente (p. ej. /dev/sdb1)?" "No encrypted LUKS device was detected on this computer.\\n\\nDo you want to enter the path manually (e.g. /dev/sdb1)?"
add_exact "cryptsetup no está instalado; no se puede hacer la copia del header.\\n\\nInstálalo con:\\nsudo apt install cryptsetup" "cryptsetup is not installed; the header cannot be backed up.\\n\\nInstall it with:\\nsudo apt install cryptsetup"
add_exact "pkexec no está disponible; no se puede leer el dispositivo (requiere acceso root)." "pkexec is not available; administrator privileges are required to read the device."
add_exact "cryptsetup no está instalado; no se puede restaurar el header.\\n\\nInstálalo con:\\nsudo apt install cryptsetup" "cryptsetup is not installed; the header cannot be restored.\\n\\nInstall it with:\\nsudo apt install cryptsetup"
add_exact "pkexec no está disponible; no se puede escribir en el dispositivo (requiere acceso root)." "pkexec is not available; administrator privileges are required to write to the device."
add_exact "El archivo elegido no existe." "The selected file does not exist."
add_exact "Operación cancelada. No se ha modificado nada." "Operation cancelled. Nothing was modified."
add_exact "Mint-Setup - Guardar" "Mint-Setup - Save"
add_exact "Mint-Setup - Restaurar" "Mint-Setup - Restore"
add_exact "Mint-Setup - Avanzado" "Mint-Setup - Advanced settings"
add_exact "Mint-Setup - Eliminar" "Mint-Setup - Delete"
add_exact "• Red — contraseñas Wi-Fi en texto plano" "• Network — Wi-Fi passwords in plain text"
add_exact "• Bluetooth — claves de emparejamiento de tus dispositivos" "• Bluetooth — pairing keys for your devices"
add_exact "• Docker — posibles credenciales de registro en base64" "• Docker — possible registry credentials in base64"
add_exact "• Thunderbird — contraseñas de tus cuentas de correo" "• Thunderbird — passwords for your email accounts"
add_exact "• Firefox — contraseñas guardadas en el navegador" "• Firefox — saved passwords in the browser"
add_exact "• LibreWolf — contraseñas guardadas en el navegador" "• LibreWolf — saved passwords in the browser"
add_exact "⚠️ Esta copia incluirá datos sensibles:" "⚠️ This backup will include sensitive data:"
add_exact "Las contraseñas de navegador/correo solo van cifradas si usas una contraseña principal." "Browser/email passwords are only encrypted when you use a Primary Password."
add_exact "Protege bien ~/MintSetupBackups." "Keep ~/MintSetupBackups protected."
add_exact "Se te pedirá la contraseña de administrador varias veces, una por cada operación que la necesite." "You will be asked for the administrator password several times, once for each operation that needs it."
add_exact "# Guardando: %s" "# Saving: %s"
add_exact "«%s» no existe, o no es ni un dispositivo de bloques ni un archivo." "“%s” does not exist, or is neither a block device nor a file."
add_exact "%s configuración(es) eliminada(s)." "Saved configurations deleted: %s."
add_exact "Se eliminaron %s de %s configuración(es). No se pudieron eliminar (sin permiso de escritura o disco de solo lectura):\n\n%s" "Deleted %s of %s saved configurations. These could not be deleted (no write permission or read-only disk):\n\n%s"
add_exact "Configuración guardada correctamente en:\\n%s%s" "Configuration saved successfully to:\\n%s%s"
add_exact "No se pudo completar la copia. Ninguna configuración incompleta se ha publicado en la carpeta de copias." "The backup could not be completed. No incomplete configuration was published to the backup folder."
add_exact "\n\nMódulos que fallaron: %s" "\n\nModules that failed: %s"
add_exact "\n\nNo se pudo guardar de forma íntegra:%s" "\n\nCould not be saved intact:%s"
add_exact "  … y %s más" "  … and %s more"
add_exact "No se pudo asegurar que la carpeta de copias de seguridad tenga permisos privados (700):\n%s\n\nComprueba los permisos o el tipo de sistema de archivos, o define otra carpeta en MINT_SETUP_BACKUPS_DIR." "Could not ensure that the backup folder has private permissions (700):\n%s\n\nCheck the permissions or filesystem type, or set another folder with MINT_SETUP_BACKUPS_DIR."
add_exact "Ya existe una copia con ese nombre y fecha. Espera un segundo y vuelve a intentarlo." "A backup with that name and timestamp already exists. Wait a second and try again."
add_exact "Vas a restaurar lo siguiente sobre tu sistema actual:\\n\\n%s\\n\\nEsto sobrescribirá la configuración actual de esos módulos.%s\\n\\n¿Deseas continuar?" "You are about to restore the following to your current system:\\n\\n%s\\n\\nThis will overwrite the current configuration of those modules.%s\\n\\nContinue?"
add_exact "Ya existe una carpeta con ese nombre en el destino:\\n%s\\n\\n¿Sobrescribirla?" "A folder with that name already exists at the destination:\\n%s\\n\\nOverwrite it?"
add_exact "Se va a copiar el header LUKS de:\\n%s\\n\\na:\\n%s\\n\\n(y un volcado de texto con sus metadatos, por si este archivo se corrompiera)\\n\\nSe te pedirá la contraseña de administrador. ¿Continuar?" "The LUKS header will be copied from:\\n%s\\n\\nto:\\n%s\\n\\n(along with a text dump of its metadata, in case this file becomes corrupted)\\n\\nYou will be asked for the administrator password. Continue?"
add_exact "No se pudo hacer la copia del header (permisos denegados, cancelado, o «%s» no es un volumen LUKS válido).\\n\\nDetalle: %s" "Could not back up the header (permission denied, cancelled, or “%s” is not a valid LUKS volume).\\n\\nDetails: %s"
add_exact "Header LUKS restaurado en %s.\\n\\nComprueba que el disco vuelve a desbloquearse con tu contraseña habitual." "LUKS header restored to %s.\\n\\nCheck that the disk can be unlocked again with your usual password."
add_exact "No se pudo crear una copia de recuperación del header actual. No se escribirá nada en %s.\\n\\nDetalle: %s" "Could not create a recovery copy of the current header. Nothing will be written to %s.\\n\\nDetails: %s"
add_exact "Se ha conservado una copia de recuperación del header actual en: %s" "A recovery copy of the current header has been kept at: %s"
add_exact "El header anterior se ha recuperado correctamente. No se ha aplicado la copia seleccionada." "The previous header was recovered successfully. The selected backup was not applied."
add_exact "La restauración no ha pasado la verificación posterior y no había copia de recuperación del header anterior, así que no se ha podido deshacer.\\n\\nComprueba si el disco se desbloquea con tu contraseña. Si no, restaura de nuevo la copia elegida u otra que tengas." "The restore did not pass the post-write verification and there was no recovery copy of the previous header, so it could not be undone.\\n\\nCheck whether the disk still unlocks with your password. If it does not, restore the chosen backup again or another one you have."
add_exact "No se pudo restaurar el header (permisos denegados, cancelado, o error de cryptsetup).\\n\\nDetalle: %s" "Could not restore the header (permission denied, cancelled, or cryptsetup error).\\n\\nDetails: %s"
add_exact "Restauración cancelada.\\n\\nSe completaron %s de %s módulo(s).%s" "Restore cancelled.\n\nCompleted modules: %s of %s.%s"
add_exact "La restauración ha terminado con errores.\\n\\nSe completaron %s de %s módulo(s), pero fallaron: %s." "The restore finished with errors.\n\nCompleted modules: %s of %s, but these failed: %s."
add_exact "• %s paquete(s) nuevo(s) instalado(s) desde el guardado" "• Packages installed since the backup: %s"
add_exact "• %s paquete(s) eliminado(s) desde el guardado" "• Packages removed since the backup: %s"
add_exact "Aplicaciones guardadas (%s paquetes APT)." "APT packages saved: %s."
add_exact "Aviso: no se pudo añadir el repositorio Flatpak %s." "Warning: the Flatpak repository %s could not be added."
add_exact "Aviso: alguna app de %s no se pudo instalar." "Warning: an application from %s could not be installed."
add_exact "Aviso: pkexec no está disponible; instala manualmente los paquetes listados en %s" "Warning: pkexec is not available; manually install the packages listed in %s"
add_exact "Aviso: pkexec no está disponible; copia manualmente %s/daemon.json a /etc/docker/daemon.json." "Warning: pkexec is not available; manually copy %s/daemon.json to /etc/docker/daemon.json."

add_exact "Aviso: %s paquete(s) ya no están disponibles en los repositorios actuales y se omitirán:" "Warning: %s APT package(s) are no longer available in the current repositories and will be skipped:"
add_exact "Instalando %s paquete(s) APT (se pedirá contraseña de administrador)..." "Installing APT packages: %s (you will be prompted for the administrator password)..."

add_exact "\n\n⚠️ Esta copia vive dentro de tu carpeta personal (%s). Si en algún momento reinstalas Mint formateando TODO el disco (no solo la partición del sistema, dejando /home aparte), esta copia desaparecerá también.\n\nSácala antes a un USB, disco externo o la nube. Puedes hacerlo desde Configuración avanzada → \"Exportar copia a...\"." "\n\n⚠️ This backup is stored inside your home folder (%s). If you ever reinstall Mint by formatting the ENTIRE disk (not just the system partition, while keeping /home separate), this backup will disappear too.\n\nMove it to a USB drive, external disk, or the cloud first. You can do this from Advanced settings → \"Export backup to...\"."
add_exact "Restaurando a la vez: %s" "Restoring simultaneously: %s"
add_exact " Estos módulos pudieron quedar a medias: «%s». Si en ese momento se estaba pidiendo la contraseña de administrador, esas operaciones pueden seguir en marcha en segundo plano aunque hayas cerrado la ventana: espera un momento antes de volver a intentarlo." " These modules may be incomplete: “%s”. If administrator authentication was being requested at that point, those operations may still be running in the background even though you closed the window. Wait a moment before trying again."
add_exact "No se pudo crear la carpeta para las copias del header LUKS:\n%s" "Could not create the LUKS header backup folder:\n%s"
add_exact "Ya existe una copia del header LUKS de %s:\n%s\n\n¿Hacer otra copia adicional? Se guardará aparte como copia n.º %s y la anterior no se tocará." "There is already a LUKS header backup of %s:\n%s\n\nMake an additional one? It will be saved separately as copy no. %s and the previous one will not be touched."
add_exact "Ya existen %s copias del header LUKS de %s. La más reciente:\n%s\n\n¿Hacer otra copia adicional? Se guardará aparte como copia n.º %s y las anteriores no se tocarán." "There are already %s LUKS header backups of %s. The most recent:\n%s\n\nMake an additional one? It will be saved separately as copy no. %s and the previous ones will not be touched."
add_exact "La copia generada no se puede leer como un header LUKS válido." "The generated copy cannot be read as a valid LUKS header."
add_exact "Copia del header LUKS creada correctamente:\n%s%s\n\n⚠️ Guarda también una copia FUERA de este equipo (USB, otro disco...): si el disco entero falla, este archivo se pierde con él. Cópiala con tu gestor de archivos: Configuración avanzada → «Abrir carpeta de configuraciones guardadas» → LuksHeaders (el asistente «Exportar copia a...» no sirve aquí: solo lista configuraciones guardadas, no esta carpeta).\n\n⚠️ Este archivo, junto con tu contraseña de cifrado, permite desbloquear el disco: protégelo igual de bien que la propia contraseña." "LUKS header backup created successfully:\n%s%s\n\n⚠️ Also keep a copy OUTSIDE this computer (USB drive, another disk...): if the entire disk fails, this file will be lost with it. Copy it with your file manager: Advanced settings → “Open saved configurations folder” → LuksHeaders (the “Export backup to...” option is not suitable here: it only lists saved configurations, not this folder).\n\n⚠️ This file, together with your encryption password, can unlock the disk: protect it as carefully as the password itself."
add_exact "¿Eliminar definitivamente estas %s configuración(es) guardada(s)?\n\n%s" "Permanently delete %s saved configurations?\n\n%s"

add_exact "No ejecutes %s completo como root ni con sudo.\n\nLos módulos que necesitan permisos de administrador (Red, Bluetooth, Aplicaciones) ya los piden puntualmente mediante pkexec cuando corresponde. Ejecutar todo el script como root haría que se guardase o restaurase la configuración de la cuenta de root en vez de la tuya.\n\nVuelve a ejecutarlo como tu usuario normal." "Do not run %s as root or with sudo.\n\nThe modules that require administrator privileges (Network, Bluetooth, Applications) request them through pkexec only when needed. Running the entire script as root would save or restore the root account's configuration instead of yours.\n\nRun it again as your normal user."
add_exact "HOME no está definida (o está vacía), así que %s no sabe cuál es tu carpeta personal.\n\nEjecútalo como tu usuario normal, desde una sesión en la que HOME apunte a tu carpeta personal." "HOME is not set (or is empty), so %s does not know which folder is your home.\n\nRun it as your normal user, from a session where HOME points to your home folder."
add_exact "HOME no es una ruta absoluta:\n%s\n\nEjecuta %s como tu usuario normal, desde una sesión en la que HOME apunte a tu carpeta personal." "HOME is not an absolute path:\n%s\n\nRun %s as your normal user, from a session where HOME points to your home folder."
add_exact "HOME no apunta a una carpeta existente:\n%s\n\nEjecuta %s como tu usuario normal, desde una sesión en la que HOME apunte a tu carpeta personal." "HOME does not point to an existing folder:\n%s\n\nRun %s as your normal user, from a session where HOME points to your home folder."
add_exact "No se pudo crear (o escribir en) la carpeta de copias de seguridad:\n%s\n\nComprueba la ruta y los permisos, o define otra carpeta en la variable de entorno MINT_SETUP_BACKUPS_DIR." "Could not create (or write to) the backup folder:\n%s\n\nCheck the path and permissions, or set a different folder with the MINT_SETUP_BACKUPS_DIR environment variable."
add_exact "Faltan herramientas necesarias para ejecutar %s:\n%s\n\nInstálalas con:\n%s" "Required tools are missing to run %s:\n%s\n\nInstall them with:\n%s"
add_exact "No se pudo abrir el menú: no hay sesión gráfica (DISPLAY y WAYLAND_DISPLAY no están definidas). Ejecútalo desde el escritorio." "Could not open the menu: there is no graphical session (DISPLAY and WAYLAND_DISPLAY are not set). Run it from the desktop."
add_exact "No se pudo guardar el idioma en:\n%s\n\nComprueba que puedas escribir en esa ruta." "Could not save the language setting in:\n%s\n\nCheck that you can write to that path."
add_exact "Instala con el gestor de paquetes de tu distribución: %s" "Install them with your distribution's package manager: %s"
add_exact "Escritorio detectado: %s (los módulos de Cinnamon y Nemo pueden no aplicarse aquí)" "Detected desktop: %s (the Cinnamon and Nemo modules may not apply here)"
add_exact "Guardando paquetes instalados manualmente con %s..." "Saving manually installed packages with %s..."
add_exact "Aplicaciones guardadas (%s paquetes de %s)." "Applications saved (%s packages from %s)."
add_exact "Aviso: esta configuración contiene datos APT (Debian, Ubuntu, Mint) pero este sistema no usa APT; se omiten. La lista guardada está en: %s" "Warning: this backup contains APT data (Debian, Ubuntu, Mint) but this system does not use APT; it is skipped. The saved list is in: %s"
add_exact "Restauración guiada de paquetes (%s): este programa no instala paquetes nativos de este gestor por su cuenta. Ejecuta tú mismo:\n  %s" "Guided package restore (%s): this program does not install native packages of this manager by itself. Run it yourself:\n  %s"
add_exact "Aviso: la lista de paquetes guardada es de %s, pero este sistema usa %s; no se aplica." "Warning: the saved package list comes from %s, but this system uses %s; it is not applied."
add_exact "\n\n⚠️ Esta configuración se guardó en «%s» y este sistema es «%s». Los módulos ligados a la distribución (Aplicaciones, Cinnamon, Nemo) pueden no aplicarse o hacerlo solo en parte." "\n\n⚠️ This backup was saved on “%s” and this system is “%s”. Distribution-specific modules (Applications, Cinnamon, Nemo) may not apply or may apply only partially."
add_exact "Exportando copia a:\n%s" "Exporting backup to:\n%s"
add_exact "Especificar ruta manualmente" "Enter path manually"
add_exact "Otro..." "Other..."
add_exact "Elige el dispositivo cifrado cuyo header quieres respaldar:" "Choose the encrypted device whose LUKS header you want to back up:"
add_exact "⚠️ Elige el dispositivo DESTINO sobre el que se va a escribir este header.\nElegir el dispositivo equivocado puede volver ilegibles TODOS sus datos." "⚠️ Choose the TARGET device to which this header will be written.\nChoosing the wrong device can make ALL of its data permanently inaccessible."
add_exact "\n\n⚠️ No se ha podido guardar el volcado de metadatos en texto (la copia binaria de arriba sí se completó y es la que hace falta para restaurar)." "\n\n⚠️ The metadata text dump could not be saved (the binary backup above was completed successfully and is the one required for restoration)."
add_exact "Vas a SOBRESCRIBIR el header de cifrado de:\n%s\n\ncon la copia:\n%s%s\n\nEsto es una medida de EMERGENCIA (header dañado) y no se puede deshacer. Si el header actual todavía funciona, no continúes.\n\nEscribe %s para confirmar:" "You are about to OVERWRITE the encryption header of:\n%s\n\nwith this backup:\n%s%s\n\nThis is an EMERGENCY measure (damaged header) and cannot be undone. If the current header still works, do not continue.\n\nType %s to confirm:"
add_exact "Copia exportada correctamente a:\n%s%s" "Backup exported successfully to:\n%s%s"
add_exact "Aviso: no se pudieron restaurar las conexiones de red (permisos denegados, espacio insuficiente o cancelado)." "Warning: the network connections could not be restored (permission denied, insufficient space or cancelled)."
add_exact "Aviso: no se pudo restaurar Bluetooth (permisos denegados, espacio insuficiente o cancelado)." "Warning: Bluetooth could not be restored (permission denied, insufficient space or cancelled)."
add_exact "El origen y el destino son la misma carpeta:\n%s\n\nElige otra carpeta de destino (por ejemplo, un USB o un disco externo)." "The source and the destination are the same folder:\n%s\n\nChoose a different destination folder (for example, a USB drive or an external disk)."
add_exact "No se pudo preparar el destino para la exportación:\n%s\n\nComprueba que tienes permiso de escritura y espacio suficiente." "Could not prepare the export destination:\n%s\n\nCheck that you have write permission and enough free space."
add_exact "No se pudo exportar la copia completa. No se ha sustituido el destino.\n\nDetalle: %s" "The complete backup could not be exported. The destination was not replaced.\n\nDetail: %s"
add_exact "No se pudo preparar la sustitución segura del destino:\n%s" "Could not prepare the destination replacement safely:\n%s"
add_exact "No se pudo apartar la copia existente para sustituirla:\n%s" "Could not move the existing backup out of the way:\n%s"
add_exact "No se pudo publicar la copia exportada. El destino anterior se ha conservado siempre que ha sido posible:\n%s" "Could not publish the exported backup. The previous destination was preserved whenever possible:\n%s"
add_exact "No se pudo publicar la copia exportada y la copia anterior no se pudo devolver a su sitio. No se ha borrado: sigue en la carpeta oculta:\n%s" "Could not publish the exported backup and the previous backup could not be put back in its place. It has not been deleted: it is still in the hidden folder:\n%s"
add_exact "No se pudo devolver la copia anterior a su sitio. No se ha borrado: sigue en la carpeta oculta:\n%s" "Could not put the previous backup back in its place. It has not been deleted: it is still in the hidden folder:\n%s"
add_exact "El contenido del destino temporal no coincide con la copia original." "The temporary destination content does not match the original backup."
add_exact "\n\n⚠️ No se pudo borrar la copia anterior del destino, que sigue ocupando espacio (carpeta oculta). Bórrala a mano:\n%s" "\n\n⚠️ The previous copy in the destination could not be deleted and still takes up space (hidden folder). Delete it by hand:\n%s"
add_exact "\n\n⚠️ El contenido se ha verificado y está completo, pero algunos atributos (permisos, propietario o fechas) no se pudieron preservar. Es habitual en FAT32/exFAT, que no soportan permisos Unix.\n\nDetalle: %s" "\n\n⚠️ The content was verified and is complete, but some attributes (permissions, owner or timestamps) could not be preserved. This is common on FAT32/exFAT, which do not support Unix permissions.\n\nDetail: %s"
add_exact "\n\n⚠️ Esta copia incluye el módulo %s (puede contener contraseñas Wi-Fi, claves de emparejamiento, contraseñas de correo, contraseñas guardadas en el navegador y/o credenciales de registros Docker). En destinos sin permisos de tipo Unix (por ejemplo, un USB en FAT32/exFAT) no se puede restringir el acceso a esos archivos: cualquiera con el USB en la mano podría leerlas." "\n\n⚠️ This backup includes the following security-sensitive modules: %s. They may contain Wi-Fi passwords, pairing keys, email passwords, saved browser passwords, and/or Docker registry credentials. On destinations without Unix-style permissions (for example, a FAT32/exFAT USB drive), access to those files cannot be restricted: anyone holding the USB drive could read them."

add_exact "\n\nTambién se ha guardado un volcado de texto con los metadatos del header (UUID, cifrado, keyslots...) en:\n%s\n\nEste archivo por sí solo NO permite desbloquear el disco: es solo referencia adicional por si la copia binaria se corrompiera." "\n\nA text dump of the LUKS header metadata (UUID, encryption, keyslots...) was also saved to:\n%s\n\nThis file alone CANNOT unlock the disk: it is only an additional reference in case the binary backup becomes corrupted."
add_exact "\n\n⚠️ No se ha podido leer «%s» como una copia de header LUKS válida. Comprueba que has elegido el archivo correcto." "\n\n⚠️ The file “%s” could not be read as a valid LUKS header backup. Check that you selected the correct file."
add_exact "\n\n⚠️ No se ha podido leer el UUID actual de %s (puede ser normal si su header está dañado, que es justo el caso que resuelve esta función). No se puede verificar automáticamente que esta copia pertenezca a este disco: continúa solo si estás seguro." "\n\n⚠️ The current UUID of %s could not be read (this can be normal if its header is damaged, which is exactly the case this function is intended to handle). The backup cannot be automatically verified as belonging to this disk: continue only if you are certain."
add_exact "\n\n🛑 AVISO: el UUID de la copia (%s) NO coincide con el de %s (%s). Restaurar el header de OTRO disco puede volver ilegibles TODOS los datos de este de forma permanente. Solo continúa si sabes exactamente lo que haces." "\n\n🛑 WARNING: the backup UUID (%s) does NOT match %s (%s). Restoring a header from ANOTHER disk can make ALL data on this disk permanently inaccessible. Continue only if you know exactly what you are doing."
add_exact "\n\n✅ El UUID de la copia coincide con %s." "\n\n✅ The backup UUID matches %s."
add_exact "\n\n⚠️ %s parece estar actualmente montado o en uso. Desmóntalo antes de restaurar para evitar dejar el sistema de archivos a medias." "\n\n⚠️ %s appears to be currently mounted or in use. Unmount it before restoring to avoid leaving the filesystem in an inconsistent state."
add_exact "La copia de recuperación no coincide con el UUID esperado (%s); no se escribirá nada en el dispositivo." "The recovery copy does not match the expected UUID (%s); nothing will be written to the device."
add_exact "No se pudo determinar el detalle del error." "The error details could not be determined."

add_exact "Aviso: no se pudo guardar «%s» de forma íntegra (¿disco lleno o permisos?); se omite." "Warning: “%s” could not be saved intact (disk full or permissions?); skipped."
add_exact "Aviso: el archivo «%s» está dañado, incompleto o no es seguro; se omite sin tocar tu configuración actual." "Warning: the file “%s” is damaged, incomplete or unsafe; skipped without touching your current configuration."
add_exact "Aviso: no se pudo devolver la configuración anterior de «%s»; puede haber quedado incompleta." "Warning: the previous settings of “%s” could not be put back; they may be left incomplete."
add_exact "Aviso: este módulo se restauró solo en parte; revisa los avisos anteriores." "Warning: this module was only partly restored; see the warnings above."
add_exact "Aviso: «%s» no se pudo aplicar por completo (un archivo donde va una carpeta o al revés, un enlace a una carpeta o un destino sin permiso de escritura). Lo demás sí se aplicó." "Warning: “%s” could not be applied in full (a file where a folder goes or the reverse, a link to a folder, or a destination without write permission). The rest was applied."
add_exact "\n\n⚠️ Vas a restaurar TODOS los módulos: puede tardar bastante (Aplicaciones, VS Code o perfiles grandes de navegador/correo son los que más) y es posible que se te pida la contraseña de administrador más de una vez durante el proceso." "\n\n⚠️ You are about to restore ALL modules: it may take a long time (Applications, VS Code and large browser/mail profiles take the longest) and you may be asked for the administrator password more than once."
add_exact "Copias de header LUKS" "LUKS header backups"
add_exact "Error: no se pudo instalar %s. Se ha deshecho lo creado hasta ahora." "Error: %s could not be installed. Everything created so far was rolled back."
add_exact "No se puede instalar: el script no es un archivo (¿se está ejecutando desde una tubería?). Descárgalo y ejecútalo desde el archivo." "Cannot install: the script is not a file (is it running from a pipe?). Download it and run it from the file."
add_exact "No se puede instalar: la ruta %s contiene caracteres no admitidos en un lanzador." "Cannot install: the path %s contains characters a launcher does not support."
add_exact "No se instala: %s ya existe y no es de este programa; no se sobrescribe." "Not installing: %s already exists and does not belong to this program; it is not overwritten."
add_exact "Instalando %s para tu usuario..." "Installing %s for your user..."
add_exact "Programa: %s" "Program: %s"
add_exact "Lanzador: %s" "Launcher: %s"
add_exact "Icono: %s" "Icon: %s"
add_exact "Instalación completada. Búscalo en el menú de aplicaciones como «%s» o ejecuta: %s" "Installation complete. Find it in the applications menu as “%s” or run: %s"
add_exact "Aviso: %s no está en tu PATH. Cierra la sesión y vuelve a entrar (o añádelo a tu PATH) para usar el comando; el lanzador del menú ya funciona." "Note: %s is not in your PATH. Log out and back in (or add it to your PATH) to use the command; the menu launcher already works."
add_exact "Conservado (lo has modificado tú): %s" "Kept (you modified it): %s"
add_exact "Eliminado: %s" "Removed: %s"
add_exact "No se pudo eliminar: %s" "Could not remove: %s"
add_exact "No hay nada que desinstalar: %s no está instalado." "Nothing to uninstall: %s is not installed."
add_exact "Esta acción es interactiva. Añade --yes para ejecutarla sin preguntas." "This action is interactive. Add --yes to run it without prompts."
add_exact "¿Desinstalar %s de tu usuario? [s/N] " "Uninstall %s for your user? [y/N] "
add_exact "Tus configuraciones: preferencias en %s y %s copia(s) guardada(s) en %s (%s)." "Your settings: preferences in %s and %s saved backup(s) in %s (%s)."
add_exact "¿Conservar tus preferencias y copias guardadas? [S/n] " "Keep your preferences and saved backups? [Y/n] "
add_exact "Se borrarán para siempre %s copia(s) y tus preferencias. ¿Seguro? [s/N] " "%s backup(s) and your preferences will be deleted forever. Are you sure? [y/N] "
add_exact "Desinstalando %s..." "Uninstalling %s..."
add_exact "Desinstalación completada. No queda ningún archivo de %s." "Uninstall complete. No %s files are left."
add_exact "Desinstalación incompleta: no se pudieron eliminar algunos archivos (sin permiso de escritura o disco de solo lectura). Bórralos a mano." "Uninstall incomplete: some files could not be removed (no write permission or read-only disk). Delete them manually."
add_exact "Desinstalación incompleta: no se pudieron eliminar algunas copias guardadas (sin permiso de escritura o disco de solo lectura). Bórralas a mano." "Uninstall incomplete: some saved backups could not be removed (no write permission or read-only disk). Delete them manually."
add_exact "Desinstalación completada. Se han conservado tus copias del header LUKS (--purge no las borra):" "Uninstall complete. Your LUKS header backups were kept (--purge does not delete them):"
add_exact "Desinstalación completada. Se han conservado tus configuraciones:" "Uninstall complete. Your settings were kept:"
add_exact "Conservado: %s" "Kept: %s"
add_exact "Uso: mint-setup.sh [opciones]" "Usage: mint-setup.sh [options]"
add_exact "(sin opciones)" "(no options)"
add_exact "abre el programa" "opens the program"
add_exact "instala para tu usuario: menú, icono y comando" "installs for your user: menu, icon and command"
add_exact "desinstala; pregunta si conservar tus configuraciones" "uninstalls; asks whether to keep your settings"
add_exact "no pregunta (con --uninstall conserva tus configuraciones)" "does not ask (with --uninstall your settings are kept)"
add_exact "con --uninstall: conserva preferencias y copias" "with --uninstall: keeps preferences and backups"
add_exact "con --uninstall: borra también preferencias y copias" "with --uninstall: also deletes preferences and backups"
add_exact "cambia el idioma" "switches the language"
add_exact "muestra la versión" "shows the version"
add_exact "muestra esta ayuda" "shows this help"
add_exact "Opción desconocida: %s" "Unknown option: %s"
add_exact "--install y --uninstall no se pueden usar juntos." "--install and --uninstall cannot be used together."
add_exact "--purge y --keep-config no se pueden usar juntos." "--purge and --keep-config cannot be used together."
add_exact "Estas opciones solo se usan con --uninstall." "These options only work with --uninstall."
add_exact "Aviso: no se pudo restaurar la preferencia de modo claro/oscuro de GNOME." "Warning: could not restore the GNOME light/dark mode preference."
add_exact "Aviso: al menos un archivo de repositorios guardado está dañado, incompleto o no es seguro; no se restaurarán esos repositorios." "Warning: at least one saved repository file is damaged, incomplete or unsafe; those repositories will not be restored."
add_exact "Aviso: no se pudo actualizar la caché APT antes de instalar los paquetes." "Warning: could not update the APT cache before installing the packages."
add_exact "Aviso: no se pudo consultar la caché APT; no se puede determinar con seguridad qué paquetes se pueden restaurar." "Warning: could not query the APT cache; it cannot be determined safely which packages can be restored."
add_exact "Aviso: hay datos Flatpak guardados, pero flatpak no está instalado en este equipo." "Warning: saved Flatpak data exists, but flatpak is not installed on this computer."
add_exact "Aviso: Aplicaciones se restauró parcialmente; revisa los avisos anteriores." "Warning: Applications was only partially restored; review the previous warnings."
add_exact "Aviso: el archivo de conexiones de red contiene rutas no seguras; no se pudo restaurar." "Warning: the network connections archive contains unsafe paths; it could not be restored."
add_exact "Aviso: el archivo de Bluetooth contiene rutas no seguras; no se pudo restaurar." "Warning: the Bluetooth archive contains unsafe paths; it could not be restored."
add_exact "Aviso: Docker no se pudo guardar íntegramente; revisa los avisos anteriores." "Warning: Docker could not be saved completely; review the previous warnings."
add_exact "Aviso: Docker se restauró parcialmente; revisa los avisos anteriores." "Warning: Docker was only partially restored; review the previous warnings."
add_exact "No se pudo asegurar que la copia de seguridad tenga permisos privados. Ninguna configuración incompleta se ha publicado." "Could not ensure that the backup has private permissions. No incomplete configuration was published."
add_exact "La restauración no ha pasado la verificación posterior. Se intentará recuperar automáticamente el header anterior." "The restoration did not pass the post-write verification. An attempt will be made to automatically recover the previous header."
add_exact "ℹ️  Acerca de Mint-Setup" "ℹ️  About Mint-Setup"
add_exact "Mint-Setup - Comparar" "Mint-Setup - Compare"
add_exact "sin-UUID" "no UUID"

T() {
    local s="$1"
    # Empty text has no translation. It must not reach the table: bash 5.2
    # rejects an empty associative subscript ("bad array subscript") instead
    # of finding nothing, and prints that error on every call.
    [ -z "$s" ] && return 0
    [ "$APP_LANG" = "es" ] && { printf "%s" "$s"; return 0; }
    if [ -n "${T_EXACT[$s]+x}" ]; then
        printf "%s" "${T_EXACT[$s]}"
    else
        printf "%s" "$s"
    fi
}

# Formats with %s (that placeholder only). Each argument is inserted as DATA:
# it is not interpreted again, so an "&" (which in bash 5.2 would mean "what
# was matched" inside ${var/pat/rep}) or a "%s" inside a path or a name does
# not alter the result. Extra arguments are ignored; missing ones leave the %s.
# It also expands the \n of the template (not of the data), so a text with line
# breaks and no %s goes through it too: msg_*() and confirm() use --no-markup,
# and with it zenity 4.0.1 shows "\n" literally instead of breaking the line.
T_FMT() {
    local fmt out="" arg
    fmt=$(T "$1")
    shift
    printf -v fmt '%b' "$fmt"
    for arg in "$@"; do
        case "$fmt" in
            *'%s'*) out+="${fmt%%'%s'*}$arg"; fmt="${fmt#*'%s'}" ;;
            *) break ;;
        esac
    done
    printf '%s' "$out$fmt"
}

# Escapes &, < and > in text that zenity interprets as Pango markup. Message
# dialogs use --no-markup; --list and --progress ignore it (zenity 4.0.1), so
# any dynamic text they carry must go through here.
markup_escape() {
    local s="$1"
    s="${s//&/"&amp;"}"
    s="${s//</"&lt;"}"
    s="${s//>/"&gt;"}"
    printf '%s' "$s"
}

init_language() {
    local detected first saved=""
    if [ -f "$LANGUAGE_CONFIG_FILE" ]; then
        # read returns 1 on a last line with no newline but still sets it, so that
        # case is kept. 2>/dev/null goes first so an unreadable file is silent too.
        { read -r saved || [ -n "$saved" ]; } 2>/dev/null < "$LANGUAGE_CONFIG_FILE" || saved=""
        case "$saved" in
            es|en) APP_LANG="$saved"; return 0 ;;
        esac
    fi

    detected="${LC_ALL:-${LC_MESSAGES:-${LANGUAGE:-${LANG:-}}}}"
    first="${detected%%:*}"
    case "$first" in
        es|es_*|es-*|es.*) APP_LANG="es" ;;
        *)                   APP_LANG="en" ;;
    esac
}

set_language() {
    case "$1" in
        es|en) APP_LANG="$1" ;;
        *) return 1 ;;
    esac
    mkdir -p "$LANGUAGE_CONFIG_DIR" 2>/dev/null || return 1
    chmod 700 "$LANGUAGE_CONFIG_DIR" 2>/dev/null || true
    # Atomic write: a cut halfway never leaves the file empty or truncated
    # (init_language would read it as "no preference").
    printf '%s\n' "$APP_LANG" | atomic_write "$LANGUAGE_CONFIG_FILE" 2>/dev/null || return 1
    chmod 600 "$LANGUAGE_CONFIG_FILE" 2>/dev/null || true
}

# Toggles the language, all or nothing: set_language changes APP_LANG before
# writing, so if it cannot be saved the previous language is restored and it
# returns 1.
toggle_language() {
    local previous="$APP_LANG" target="es"
    [ "$APP_LANG" = "es" ] && target="en"
    set_language "$target" && return 0
    APP_LANG="$previous"
    return 1
}

init_language

# Startup error or warning that must not be lost: a dialog if Zenity exists and
# can open; if it is missing or fails (no display, e.g. over SSH), the same text
# goes to stderr.
startup_error() {
    if command -v zenity >/dev/null 2>&1 \
        && LANGUAGE="$APP_LANG" zenity --error --no-markup --title="$APP_NAME" --text="$1" --width=420 2>/dev/null; then
        return 0
    fi
    printf '%s\n' "$1" >&2
}

if [ "${MINT_SETUP_TEST:-0}" != "1" ] && [ "$(id -u)" -eq 0 ]; then
    root_guard_msg='No ejecutes %s completo como root ni con sudo.\n\nLos módulos que necesitan permisos de administrador (Red, Bluetooth, Aplicaciones) ya los piden puntualmente mediante pkexec cuando corresponde. Ejecutar todo el script como root haría que se guardase o restaurase la configuración de la cuenta de root en vez de la tuya.\n\nVuelve a ejecutarlo como tu usuario normal.'
    root_guard_text="$(T_FMT "$root_guard_msg" "$APP_NAME")"
    startup_error "$root_guard_text"
    exit 1
fi

# Warning that the language was not saved. toggle_language already restored the
# previous one, so the text comes out in the language still in effect.
warn_language_not_saved() {
    startup_error "$(T_FMT 'No se pudo guardar el idioma en:\n%s\n\nComprueba que puedas escribir en esa ruta.' "$LANGUAGE_CONFIG_DIR")"
}

# Parses the command line without side effects. Fills CLI_ACTION, CLI_YES,
# CLI_KEEP, CLI_PURGE, CLI_HELP and CLI_TOGGLE (how many -l it carries) and, if
# the line is not valid, CLI_ERR (unknown | both_actions | keep_purge |
# only_uninstall) and CLI_ERR_ARG. It is the only source of the rules:
# run_cli_action and cli_apply_toggles use it, and the latter must change
# nothing if the line is rejected. -h/--help exits at its position: whatever
# follows it is no longer validated (only the -l are still counted).
cli_parse_args() {
    local arg both=0
    CLI_ACTION="" CLI_YES=0 CLI_KEEP=0 CLI_PURGE=0 CLI_HELP=0 CLI_TOGGLE=0
    CLI_ERR="" CLI_ERR_ARG=""
    for arg in "$@"; do
        if [ "$CLI_HELP" -eq 1 ]; then
            case "$arg" in -l|--toggle-language) CLI_TOGGLE=$((CLI_TOGGLE + 1)) ;; esac
            continue
        fi
        case "$arg" in
            --install) [ "$CLI_ACTION" = uninstall ] && both=1; CLI_ACTION=install ;;
            --uninstall) [ "$CLI_ACTION" = install ] && both=1; CLI_ACTION=uninstall ;;
            --yes|-y) CLI_YES=1 ;;
            --keep-config) CLI_KEEP=1 ;;
            --purge) CLI_PURGE=1 ;;
            -l|--toggle-language) CLI_TOGGLE=$((CLI_TOGGLE + 1)) ;;
            -h|--help) CLI_HELP=1 ;;
            --version) ;;
            *) CLI_ERR=unknown; CLI_ERR_ARG="$arg"; return 1 ;;
        esac
    done
    [ "$CLI_HELP" -eq 1 ] && return 0
    if [ "$both" -eq 1 ]; then
        CLI_ERR=both_actions
        return 1
    fi
    if [ "$CLI_KEEP" -eq 1 ] && [ "$CLI_PURGE" -eq 1 ]; then
        CLI_ERR=keep_purge
        return 1
    fi
    if [ "$CLI_ACTION" != uninstall ] && { [ "$CLI_KEEP" -eq 1 ] || [ "$CLI_PURGE" -eq 1 ]; }; then
        CLI_ERR=only_uninstall
        return 1
    fi
    return 0
}

# -l / --toggle-language changes the language and continues with the program.
# If it cannot be saved, it warns and exits with 1.
cli_toggle_language() {
    toggle_language && return 0
    warn_language_not_saved
    exit 1
}

# Applies the -l of the line, one per occurrence (-l -l goes back to the
# starting language). A rejected line changes and saves nothing: run_cli_action
# will reject it later, with the warning in the language still in effect.
cli_apply_toggles() {
    local n
    [ -z "$CLI_ERR" ] || return 0
    for ((n = 0; n < CLI_TOGGLE; n++)); do
        cli_toggle_language
    done
}

# Succeeds if $HOME is an absolute path to an existing directory. Otherwise it
# sets HOME_ERR (empty | relative | not_dir: missing or not a directory) and
# returns 1. Every path the program reads or writes hangs from $HOME: empty, it
# would work on "/" without saying so; relative, on a folder that depends on
# the current directory.
home_check() {
    HOME_ERR=""
    case "${HOME-}" in
        "") HOME_ERR=empty ;;
        /*) [ -d "$HOME" ] || HOME_ERR=not_dir ;;
        *)  HOME_ERR=relative ;;
    esac
    [ -z "$HOME_ERR" ]
}

# Succeeds if the parsed command line goes on to touch paths under $HOME. Only
# printing the usage and rejecting a line do not: they just write to the
# terminal, so --help must keep working whatever HOME holds (like --version).
cli_needs_home() {
    [ -z "$CLI_ERR" ] && { [ "$CLI_HELP" -eq 0 ] || [ "$CLI_TOGGLE" -gt 0 ]; }
}

# Stops with a warning if $HOME is not usable (see home_check). It runs before
# cli_apply_toggles: -l writes the language under $HOME when XDG_CONFIG_HOME is
# not set. The dialog is shown without HOME: Zenity (GTK) keeps its cache under
# it and, with an empty or relative one, would create ".cache" in the current
# directory, so the guard would not be writing nothing after all.
require_home() {
    local home_guard_msg bad_home="${HOME-}"
    home_check && return 0
    unset HOME
    case "$HOME_ERR" in
        empty)
            home_guard_msg='HOME no está definida (o está vacía), así que %s no sabe cuál es tu carpeta personal.\n\nEjecútalo como tu usuario normal, desde una sesión en la que HOME apunte a tu carpeta personal.'
            startup_error "$(T_FMT "$home_guard_msg" "$APP_NAME")" ;;
        relative)
            home_guard_msg='HOME no es una ruta absoluta:\n%s\n\nEjecuta %s como tu usuario normal, desde una sesión en la que HOME apunte a tu carpeta personal.'
            startup_error "$(T_FMT "$home_guard_msg" "$bad_home" "$APP_NAME")" ;;
        not_dir)
            home_guard_msg='HOME no apunta a una carpeta existente:\n%s\n\nEjecuta %s como tu usuario normal, desde una sesión en la que HOME apunte a tu carpeta personal.'
            startup_error "$(T_FMT "$home_guard_msg" "$bad_home" "$APP_NAME")" ;;
    esac
    exit 1
}

cli_parse_args "$@"
if [ "${MINT_SETUP_TEST:-0}" != "1" ] && cli_needs_home; then
    require_home
fi
cli_apply_toggles

# =============================================================================
# VARIABLES
# =============================================================================

BACKUPS_ROOT="${MINT_SETUP_BACKUPS_DIR:-$HOME/MintSetupBackups}"

# Creates the backup folder if it is missing and checks that it can be written
# to and that it is private; if not, it warns and returns 1. It is called from
# the main program, after run_cli_action and check_dependencies: --help,
# rejected lines, --install and --uninstall neither need it nor should create it
# (--uninstall would report as "kept" an empty folder the program itself had
# just created, and a file at that path would keep them from running), and a
# run that stops for missing tools must not leave it behind.
ensure_backups_root() {
    local backups_root_err backups_root_text
    if ! mkdir -p "$BACKUPS_ROOT" 2>/dev/null || [ ! -w "$BACKUPS_ROOT" ]; then
        backups_root_err='No se pudo crear (o escribir en) la carpeta de copias de seguridad:\n%s\n\nComprueba la ruta y los permisos, o define otra carpeta en la variable de entorno MINT_SETUP_BACKUPS_DIR.'
        backups_root_text="$(T_FMT "$backups_root_err" "$BACKUPS_ROOT")"
        startup_error "$backups_root_text"
        return 1
    fi
    # Restricted in case the user already had this folder from an earlier
    # version of the script (with default permissions); umask 077 already
    # covers the case of it being created now for the first time. We do not go
    # on if we cannot make sure the directory holding the backups is private.
    if ! chmod 700 "$BACKUPS_ROOT" 2>/dev/null; then
        backups_root_err='No se pudo asegurar que la carpeta de copias de seguridad tenga permisos privados (700):\n%s\n\nComprueba los permisos o el tipo de sistema de archivos, o define otra carpeta en MINT_SETUP_BACKUPS_DIR.'
        backups_root_text="$(T_FMT "$backups_root_err" "$BACKUPS_ROOT")"
        startup_error "$backups_root_text"
        return 1
    fi
}

# Folder for the LUKS header backups (see the corresponding section further
# down). It is not created here, only when the user uses that feature for the
# first time, so nobody who encrypts no disk gets an empty folder.
LUKS_HEADERS_DIR="$BACKUPS_ROOT/LuksHeaders"

# Single list of available modules (key -> description). It is used both for
# the "Save" checklist (all of them) and the "Restore" one (only those that
# exist in the chosen configuration), so adding a new module only means adding
# its save_/restore_ functions and one line here, without having to remember to
# touch each checklist separately.
MODULE_KEYS=(desktop appearance nemo software startup displays sound network bluetooth keyboard mouse touchpad firefox librewolf thunderbird libreoffice onlyoffice vscode docker terminal)
declare -A MODULE_LABELS=(
    [desktop]="Escritorio Cinnamon (posición/tamaño de paneles y barra de tareas, applets —incl. icono del menú—, desklets, extensiones, workspaces...)"
    [appearance]="Apariencia (tema de Cinnamon y de ventanas, iconos, cursor y fuentes completos, modo claro/oscuro, fondo, protector de pantalla)"
    [nemo]="Nemo (accesos directos de escritorio y menú, marcadores, scripts, acciones, preferencias)"
    [software]="Aplicaciones (paquetes APT, Flatpak, repositorios adicionales)"
    [startup]="Aplicaciones de inicio (programas que se lanzan automáticamente al iniciar sesión)"
    [displays]="Pantallas (resolución y disposición de monitores)"
    [sound]="Sonido (tema de sonido, dispositivo de salida/entrada)"
    [network]="Red (conexiones NetworkManager — incluye contraseñas Wi-Fi en texto plano) ⚠️ requiere administrador"
    [bluetooth]="Bluetooth (dispositivos emparejados) ⚠️ requiere administrador"
    [keyboard]="Teclado (distribución, opciones XKB, repetición/retardo)"
    [mouse]="Ratón (velocidad, aceleración, botones)"
    [touchpad]="Touchpad (toque para pulsar, scroll, gestos)"
    [firefox]="Firefox (perfil completo: marcadores, extensiones, preferencias) ⚠️ incluye contraseñas guardadas"
    [librewolf]="LibreWolf (perfil completo: marcadores, extensiones, preferencias) ⚠️ incluye contraseñas guardadas"
    [thunderbird]="Thunderbird (cuentas, filtros, libreta de direcciones, extensiones) ⚠️ incluye contraseñas de correo"
    [libreoffice]="LibreOffice (plantillas, autocorrección, extensiones, barras de herramientas)"
    [onlyoffice]="ONLYOFFICE (configuración de usuario y plugins de Desktop Editors)"
    [vscode]="VS Code (extensiones instaladas, settings.json, keybindings, snippets, perfiles)"
    [docker]="Docker (config. de usuario y del daemon, grupo docker) ⚠️ parte requiere administrador"
    [terminal]="Terminal (perfiles de GNOME Terminal, .bashrc/.zshrc y archivos de shell)"
)

# Short version of each label (without the description in parentheses), to
# show compact lists such as the Restore confirmation summary.
declare -A MODULE_SHORT_LABELS=(
    [desktop]="Escritorio Cinnamon"
    [appearance]="Apariencia"
    [nemo]="Nemo"
    [software]="Aplicaciones"
    [startup]="Aplicaciones de inicio"
    [displays]="Pantallas"
    [sound]="Sonido"
    [network]="Red"
    [bluetooth]="Bluetooth"
    [keyboard]="Teclado"
    [mouse]="Ratón"
    [touchpad]="Touchpad"
    [firefox]="Firefox"
    [librewolf]="LibreWolf"
    [thunderbird]="Thunderbird"
    [libreoffice]="LibreOffice"
    [onlyoffice]="ONLYOFFICE"
    [vscode]="VS Code"
    [docker]="Docker"
    [terminal]="Terminal"
)

# =============================================================================
# COMMON FUNCTIONS
# =============================================================================

# Every zenity call starts with LANGUAGE="$APP_LANG": the buttons (Cancel/OK,
# Yes/No...) and the file chooser texts come from the system catalogs, so without
# it they follow the session language instead of the program's. The variable lives
# only in that command's environment; tests/test-localization.sh enforces it.
msg_info()  { LANGUAGE="$APP_LANG" zenity --info --no-markup --title="$APP_NAME" --text="$(T "$1")" --width=380 2>/dev/null; }
msg_error() { LANGUAGE="$APP_LANG" zenity --error --no-markup --title="$APP_NAME" --text="$(T "$1")" --width=380 2>/dev/null; }
msg_warn()  { LANGUAGE="$APP_LANG" zenity --warning --no-markup --title="$APP_NAME" --text="$(T "$1")" --width=420 2>/dev/null; }
log_msg()   { printf '%s\n' "$(T "$*")"; }

# Returns 0 if the user confirms, 1 if they cancel
confirm() {
    LANGUAGE="$APP_LANG" zenity --question --no-markup --title="$APP_NAME" --text="$(T "$1")" --width=380 2>/dev/null
}

# Short format for a number of seconds ("~45 s", "~3 min",
# "~1 h 5 min"). Used by the Restore progress bar for the estimated
# remaining time. The minutes are rounded once, to the nearest whole one,
# and the hours come from that figure: rounding only below the hour showed
# "~60 min" for 3570-3599 s.
fmt_eta() {
    local s="$1" m
    if [ "$s" -lt 60 ]; then printf '~%d s' "$s"; return 0; fi
    m=$(( (s + 30) / 60 ))
    if [ "$m" -lt 60 ]; then printf '~%d min' "$m"
    else                     printf '~%d h %d min' "$(( m / 60 ))" "$(( m % 60 ))"
    fi
}

# Formats the " · N left" suffix of the Restore bar from the seconds
# remaining according to the latest estimate ($1, may be negative if that
# estimate has already been exceeded). Separately, it moves on its own in
# real time (see do_restore) instead of staying stuck at the value computed
# the last time a module finished.
fmt_eta_txt() {
    local remaining="$1"
    if   [ "$remaining" -ge 1 ];  then T_FMT ' · quedan %s' "$(fmt_eta "$remaining")"
    elif [ "$remaining" -ge -3 ]; then T ' · terminando...'
    else                                T_FMT ' · tardando más de lo previsto (+%s)' "$(fmt_eta $(( -remaining )))"
    fi
}

# =============================================================================
# PLATFORM (distribution, package manager and desktop)
# =============================================================================
# System information is only READ: the content of /etc/os-release is never
# executed. MINT_SETUP_OS_RELEASE points to another file (tests).
PLATFORM_OS_ID=""; PLATFORM_OS_LIKE=""; PLATFORM_NAME=""; PLATFORM_PKG=""; PLATFORM_DESKTOP=""

# Value of key $2 in the os-release-style file $1, without quotes.
os_release_value() {
    local file="$1" key="$2" line value
    [ -r "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$key="*) value="${line#*=}" ;;
            *) continue ;;
        esac
        value="${value#\"}"; value="${value%\"}"; value="${value#\'}"; value="${value%\'}"
        printf '%s' "$value"
        return 0
    done < "$file"
    return 1
}

# Fills in PLATFORM_*: distribution, package manager (apt, dnf, pacman,
# zypper or empty) and desktop. Called on load and may be repeated.
detect_platform() {
    local f="${MINT_SETUP_OS_RELEASE:-/etc/os-release}" pair
    PLATFORM_OS_ID=$(os_release_value "$f" ID 2>/dev/null) || PLATFORM_OS_ID=""
    PLATFORM_OS_LIKE=$(os_release_value "$f" ID_LIKE 2>/dev/null) || PLATFORM_OS_LIKE=""
    PLATFORM_NAME=$(os_release_value "$f" PRETTY_NAME 2>/dev/null) || PLATFORM_NAME=""
    if [ -z "$PLATFORM_NAME" ] && command -v lsb_release >/dev/null 2>&1; then
        PLATFORM_NAME=$(lsb_release -ds 2>/dev/null || true)
    fi
    [ -n "$PLATFORM_NAME" ] || PLATFORM_NAME="Linux"
    PLATFORM_PKG=""
    # 1) the family the distribution declares; 2) the first manager found
    case " $PLATFORM_OS_ID $PLATFORM_OS_LIKE " in
        *" debian "*|*" ubuntu "*|*" linuxmint "*) command -v apt-get >/dev/null 2>&1 && PLATFORM_PKG=apt ;;
        *" fedora "*|*" rhel "*|*" centos "*)      command -v dnf >/dev/null 2>&1 && PLATFORM_PKG=dnf ;;
        *" arch "*)                                command -v pacman >/dev/null 2>&1 && PLATFORM_PKG=pacman ;;
        *" suse "*|*" opensuse "*)                 command -v zypper >/dev/null 2>&1 && PLATFORM_PKG=zypper ;;
    esac
    if [ -z "$PLATFORM_PKG" ]; then
        for pair in apt-get:apt dnf:dnf pacman:pacman zypper:zypper; do
            if command -v "${pair%%:*}" >/dev/null 2>&1; then PLATFORM_PKG="${pair##*:}"; break; fi
        done
    fi
    PLATFORM_DESKTOP=$(printf '%s' "${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-}}" | tr '[:upper:]' '[:lower:]')
}

# Succeeds if the session is Cinnamon (or cannot be told: no needless warning).
is_cinnamon_desktop() {
    [ -z "$PLATFORM_DESKTOP" ] && return 0
    case "$PLATFORM_DESKTOP" in *cinnamon*) return 0 ;; esac
    return 1
}

# Package that provides command $2 for package manager $1.
pkg_for_command() {
    case "$1:$2" in
        apt:dconf) echo dconf-cli ;;
        apt:gsettings) echo libglib2.0-bin ;;
        dnf:gsettings|pacman:gsettings) echo glib2 ;;
        zypper:gsettings) echo glib2-tools ;;
        *) echo "$2" ;;
    esac
}

# Suggested install command for the missing commands ($@).
install_hint() {
    local cmd pkgs=() list verb
    for cmd in "$@"; do pkgs+=("$(pkg_for_command "$PLATFORM_PKG" "$cmd")"); done
    list="${pkgs[*]}"
    case "$PLATFORM_PKG" in
        apt)    verb="sudo apt install" ;;
        dnf)    verb="sudo dnf install" ;;
        pacman) verb="sudo pacman -S" ;;
        zypper) verb="sudo zypper install" ;;
        *)      T_FMT 'Instala con el gestor de paquetes de tu distribución: %s' "$*"; return 0 ;;
    esac
    printf '%s %s' "$verb" "$list"
}

detect_platform

check_dependencies() {
    local missing=() cmd
    for cmd in zenity dconf gsettings tar; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        local text
        text="$(T_FMT 'Faltan herramientas necesarias para ejecutar %s:\n%s\n\nInstálalas con:\n%s' "$APP_NAME" "${missing[*]}" "$(install_hint "${missing[@]}")")"
        startup_error "$text"
        exit 1
    fi
    # The other tools the program uses are optional; each module checks
    # for its own presence separately (see header).
}

# Checks whether a process with that exact name is running. It is used
# before saving/restoring file-based application profiles (Firefox,
# LibreWolf, Thunderbird, LibreOffice, ONLYOFFICE): touching those files
# while the application is open can leave the profile inconsistent or
# corrupt (half-written SQLite databases, etc.). Save warns and carries on;
# Restore skips the module and returns 1, because nothing was restored and
# do_restore must list it as failed instead of announcing success.
is_running() {
    # If pgrep is not installed we cannot check this safely. We return
    # "it might be running" (instead of "it is not") so that the modules
    # calling this function err on the side of caution and do not risk
    # corrupting a profile through a false sense of security. pgrep ships
    # with procps, which is present out of the box on Mint, so this only
    # comes into play on very stripped-down installations.
    if ! command -v pgrep >/dev/null 2>&1; then
        return 0
    fi
    pgrep -x "$1" >/dev/null 2>&1
}

# Returns the real path of a standard user folder ($1: DESKTOP,
# PICTURES...) using xdg-user-dir, which works whatever the system language
# is (Escritorio, Desktop, Bureau, Schreibtisch...). If xdg-user-dir is
# not installed, or that folder is not defined (xdg-user-dir returns
# $HOME in that case), $2 is used as the fallback value.
xdg_dir() {
    local kind="$1" fallback="$2" out
    if command -v xdg-user-dir >/dev/null 2>&1; then
        out=$(xdg-user-dir "$kind" 2>/dev/null)
        [ -n "$out" ] && [ "$out" != "$HOME" ] && { printf '%s' "$out"; return 0; }
    fi
    printf '%s' "$fallback"
}

# Name to give tar (after -C <parent>) for the folder at path $1: its base name,
# or "name/." if it is a symbolic link to a folder, so that tar archives the
# folder's content and not just the link (see pack_dir).
tar_root_member() {
    local name
    name=$(basename "$1")
    [ -L "$1" ] && name="$name/."
    printf '%s' "$name"
}

# Packs folder $1 (absolute path) into file $2 (.tar.gz), only if $1
# exists and contains something. Used for the "optional" folders (themes,
# icons, fonts, launchers...) that may not exist on every machine.
# If $1 is a symbolic link to a folder (stow, a folder on another partition),
# its CONTENT is packed under the link's own name: without -H, find does not
# enter it (the folder was skipped without a warning) and tar would store just
# the link, dangling on another machine. The "/." makes tar follow only that
# top-level link; links inside the folder are stored as links.
pack_dir() {
    local src="$1" dest="$2" entries find_rc name
    [ -d "$src" ] || return 0
    entries=$(find -H "$src" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)
    find_rc=$?
    if [ "$find_rc" -ne 0 ]; then
        save_problem "$src"
        return 1
    fi
    [ -n "$entries" ] || return 0
    name=$(tar_root_member "$src")
    if ! atomic_tar "$dest" -C "$(dirname "$src")" "$name"; then
        save_problem "$src"
        return 1
    fi
}

# Dumps a dconf path only if the command finishes successfully. If it fails,
# the temporary dump is discarded so a truncated copy is not published.
dconf_dump_atomic() {
    local target="$1" dest="$2"
    atomic_capture "$dest" dconf dump "$target" 2>/dev/null || save_problem "$dest"
}

# Copies a file into a copy in progress without exposing a truncated one if
# the source fails or space runs out.
save_copy() {
    local src="$1" dest="$2"
    [ -f "$src" ] || return 0
    atomic_copy "$src" "$dest" || save_problem "$src"
}

# Filters the Cinnamon dump and preserves the exit status of both pipeline
# steps so a dconf failure is not taken for a valid save.
dconf_dump_desktop() {
    local list="$1"
    local -a pipeline_status
    dconf dump /org/cinnamon/ 2>/dev/null | awk -v list="$list" '
        BEGIN { n = split(list, excl, " ") }
        /^\[.*\]$/ {
            sect = substr($0, 2, length($0) - 2)
            skip = 0
            for (i = 1; i <= n; i++) if (sect == excl[i] || index(sect, excl[i] "/") == 1) { skip = 1; break }
        }
        !skip
    '
    pipeline_status=("${PIPESTATUS[@]}")
    [ "${pipeline_status[0]}" -eq 0 ] || return "${pipeline_status[0]}"
    [ "${pipeline_status[1]}" -eq 0 ] || return "${pipeline_status[1]}"
}

# Flags that the Save module had a recoverable failure. It is kept separate
# from the immediate return code because the module may keep saving other
# data and return the result at the end.
save_mark_failed() {
    if [ "${SAVE_CONTEXT:-0}" -eq 1 ]; then
        SAVE_MODULE_FAILED=1
    fi
}

# Runs a Save module with an error channel independent of its exit code.
# That way, helpers that record a problem and carry on cannot turn an
# incomplete copy into a false success.
run_save_module() {
    local mod="$1" stage_dir="$2" SAVE_CONTEXT=1 SAVE_MODULE_FAILED=0 rc=0
    "save_${mod}" "$stage_dir" || rc=$?
    [ "$SAVE_MODULE_FAILED" -eq 0 ] || rc=1
    return "$rc"
}

# Warns that "$1" could not be saved intact (the incomplete file is
# discarded instead of being left in the copy) and records it in
# SAVE_PROBLEMS_FILE, which do_save lists in its error dialog. The module
# carries on with the rest of the data, but the execution wrapper turns it
# into a module failure.
save_problem() {
    log_msg "$(T_FMT 'Aviso: no se pudo guardar «%s» de forma íntegra (¿disco lleno o permisos?); se omite.' "$1")"
    [ -n "${SAVE_PROBLEMS_FILE:-}" ] && printf '%s\n' "$1" >> "$SAVE_PROBLEMS_FILE"
    save_mark_failed
    return 0
}

# Warns that a file in the copy could not be restored. Normally it is damaged,
# incomplete or has unsafe paths, and the current configuration is not touched.
# If safe_extract merged it only in part (SAFE_EXTRACT_PARTIAL), it says so.
restore_problem() {
    if [ "${SAFE_EXTRACT_PARTIAL:-0}" -eq 1 ]; then
        SAFE_EXTRACT_PARTIAL=0
        log_msg "$(T_FMT 'Aviso: «%s» no se pudo aplicar por completo (un archivo donde va una carpeta o al revés, un enlace a una carpeta o un destino sin permiso de escritura). Lo demás sí se aplicó.' "$1")"
    else
        log_msg "$(T_FMT 'Aviso: el archivo «%s» está dañado, incompleto o no es seguro; se omite sin tocar tu configuración actual.' "$1")"
    fi
    restore_mark_failed
    return 0
}

# Asked at the end of a restore module before it says "restored": true if nothing in it
# was flagged as failed (the flag that makes run_restore_module report the module as
# failed). Otherwise it warns that the module was restored only in part and returns 1,
# because "restored" would contradict the warnings just above it.
restore_clean_end() {
    [ "${RESTORE_MODULE_FAILED:-0}" -eq 0 ] && return 0
    log_msg "$(T 'Aviso: este módulo se restauró solo en parte; revisa los avisos anteriores.')"
    return 1
}

# Extracts file $1 (.tar.gz) inside parent folder $2, if $1 exists.
# $2 must be the folder that CONTAINS the original folder (e.g. if ~/.themes
# was packed, "$HOME" is passed here so that ~/.themes is recreated).
unpack_dir() {
    local archive="$1" parent="$2"
    [ -f "$archive" ] || return 0
    if safe_extract "$archive" "$parent"; then
        return 0
    fi
    restore_problem "$archive"
    return 1
}

# Value of the GVariant string literal $1, as printed by gsettings: 'text', or
# "text" when it contains a single quote (a wallpaper called "Rob's pic.jpg").
# Only \\, \" and \' are unescaped. Prints nothing and returns 1 if $1 is not
# a quoted string.
gvariant_string_value() {
    local s="$1" q="${1:0:1}"
    case "$q" in "'"|'"') ;; *) return 1 ;; esac
    [ "${#s}" -ge 2 ] && [ "${s: -1}" = "$q" ] || return 1
    printf '%s' "${s:1:${#s}-2}" | sed -E "s/\\\\([\"\\\\'])/\\1/g"
}

# Saves into $1 the real image file the screen wallpaper key $2 points to
# (picture-uri or picture-uri-dark), named "wallpaper$3-*", so that it
# survives a clean install even if the original path no longer exists. $3 is
# a suffix ("" for light, "-dark" for dark) that keeps both wallpapers from
# colliding if they are different images.
save_wallpaper_uri() {
    local dir="$1" key="$2" suffix="$3" uri path
    uri=$(gvariant_string_value "$(gsettings get org.cinnamon.desktop.background "$key" 2>/dev/null)") || return 0
    [[ "$uri" == file://* ]] || return 0
    path="${uri#file://}"
    # A literal backslash is a path character: protect it from printf %b.
    path="${path//\\/%5C}"
    path=$(printf '%b' "${path//%/\\x}")
    if [ -f "$path" ]; then
        # The .filename marker is only written if the image was copied whole:
        # otherwise Restore would point to a missing or truncated image.
        if atomic_copy "$path" "$dir/wallpaper${suffix}-$(basename "$path")" 2>/dev/null; then
            basename "$path" | atomic_write "$dir/wallpaper${suffix}.filename" 2>/dev/null \
                || save_problem "$dir/wallpaper${suffix}.filename"
        else
            save_problem "$path"
        fi
    fi
}

# Percent-encodes a path so it can be used as a file:// URI (RFC 3986).
# LC_ALL=C forces bash to iterate byte by byte (not UTF-8 character), which
# is exactly what is needed to encode every byte of a name with accents.
uri_encode_path() {
    local LC_ALL=C s="$1" out="" i c
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9./_-]) out+="$c" ;;
            *) out+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    printf '%s' "$out"
}

# Where restore_wallpaper_uri puts the wallpaper saved in copy folder $1 (suffix $2: "" or
# "-dark"): <Pictures>/MintSetupWallpapers/<name>. Prints nothing and returns 1 if the copy has
# no usable image. The name comes from the saved copy: it is reduced to a plain name so that a
# tampered copy cannot write outside the destination folder.
wallpaper_restore_dest() {
    local dir="$1" suffix="$2" fname
    [ -f "$dir/wallpaper${suffix}.filename" ] || return 1
    fname=$(cat "$dir/wallpaper${suffix}.filename")
    fname="${fname##*/}"
    case "$fname" in ""|.|..) return 1 ;; esac
    [ -f "$dir/wallpaper${suffix}-$fname" ] || return 1
    printf '%s/MintSetupWallpapers/%s' "$(xdg_dir PICTURES "$HOME/Pictures")" "$fname"
}

# Inverse of save_wallpaper_uri(): if $1/wallpaper$3.filename exists, copies
# the saved image to <Pictures>/MintSetupWallpapers and points key $2 there.
# The name is percent-encoded when building the URI (spaces, accents...);
# without this, a wallpaper with spaces in its name left an invalid file://.
restore_wallpaper_uri() {
    local dir="$1" key="$2" suffix="$3" dest
    dest=$(wallpaper_restore_dest "$dir" "$suffix") || return 0
    mkdir -p "${dest%/*}"
    # If the copy fails the wallpaper is not changed: never point to a half-written file.
    atomic_copy "$dir/wallpaper${suffix}-${dest##*/}" "$dest" 2>/dev/null || return 1
    if ! gsettings set org.cinnamon.desktop.background "$key" "file://$(uri_encode_path "$dest")" 2>/dev/null; then
        restore_mark_failed
        return 1
    fi
}

# "dconf load" is ADDITIVE: it only writes the keys present in the dump and
# leaves intact whatever is already on the system. If a key (e.g. the color
# of a terminal profile) was changed AFTER saving, restoring does not revert
# it, because the old value never appears in the file. That is why the path
# is reset before loading, so the restore is exact.
# Only used with paths EXCLUSIVELY owned by one module.
dconf_rollback_clean() {
    local target="$1" snapshot="$2" verify reset_rc=0 load_rc=0
    dconf reset -f "$target" 2>/dev/null || reset_rc=$?
    printf '%s\n' "$snapshot" | dconf load "$target" 2>/dev/null || load_rc=$?
    verify=$(dconf dump "$target" 2>/dev/null) || return 1
    [ "$reset_rc" -eq 0 ] && [ "$load_rc" -eq 0 ] && [ "$verify" = "$snapshot" ]
}

# The rollback itself failed (dconf is probably gone too): the path may be left
# reset or only partly restored, and nothing else says so.
dconf_rollback_failed() {
    log_msg "$(T_FMT 'Aviso: no se pudo devolver la configuración anterior de «%s»; puede haber quedado incompleta.' "$1")"
}

dconf_load_clean() {
    local target="$1" file="$2" snapshot
    [ -f "$file" ] || return 0
    # The load semantically replaces the whole path, so we first need a
    # reliable snapshot to be able to undo the reset if the load fails. We do
    # not destroy the current configuration if that snapshot could not even
    # be obtained.
    if ! snapshot=$(dconf dump "$target" 2>/dev/null); then
        restore_mark_failed
        return 1
    fi
    if ! dconf reset -f "$target" 2>/dev/null; then
        restore_mark_failed
        return 1
    fi
    if ! dconf load "$target" < "$file"; then
        dconf_rollback_clean "$target" "$snapshot" || dconf_rollback_failed "$target"
        restore_mark_failed
        return 1
    fi
    return 0
}

# Subpaths of /org/cinnamon/ that another module already saves on its own
# (Appearance, Sound, Keyboard, Mouse, Touchpad, Displays). dconf load only
# touches the sections present in the file it loads and leaves the others
# intact (at any depth), so it is enough not to include them when saving
# Desktop so that restoring it without those other modules does not
# overwrite them with whatever they held at that moment.
CINNAMON_DESKTOP_EXCLUDE_PATHS=(
    desktop/interface desktop/wm/preferences desktop/screensaver
    desktop/background desktop/sound settings-daemon/peripherals/keyboard
    settings-daemon/peripherals/mouse settings-daemon/peripherals/touchpad
    settings-daemon/plugins/xrandr
)

# Rejects a Desktop dump that tries to touch another module. Normal backups are
# already filtered on save, but the file may have been tampered with between Save
# and Restore; we do not trust that precondition and fail before any destructive
# reset. "dconf load" reads the file with GKeyFile and the loops that reset first
# do not, and "dconf reset -f" on a section also wipes everything under it, so
# the file must look exactly like a "dconf dump": only [section] headers and
# key=value lines, no blanks around a header (GKeyFile ignores them, the loops do
# not see the header), no key with a "/" (it would land in another module's
# folder: "desktop/interface/font-name" under [/]) and no section that is, lies
# under or CONTAINS an excluded path. The last line is read even without a newline.
dconf_desktop_file_is_safe() {
    local file="$1" line section excl
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "") ;;
            \[*\])
                section="${line#[}"; section="${section%]}"
                for excl in "${CINNAMON_DESKTOP_EXCLUDE_PATHS[@]}"; do
                    if [ "$section" = "$excl" ] || [[ "$section" == "$excl/"* ]] || [[ "$excl" == "$section/"* ]]; then
                        return 1
                    fi
                done
                ;;
            \[*|"#"*|=*) return 1 ;;
            *=*) case "${line%%=*}" in */*) return 1 ;; esac ;;
            *) return 1 ;;
        esac
    done < "$file"
    return 0
}

# Like dconf_load_clean(), but for /org/cinnamon/ (Desktop), which shares a
# root with the modules above. A "dconf reset -f" of the whole path would
# also wipe their configuration even if they are not being restored now, so
# instead it resets only what the dump itself is going to overwrite: each
# subfolder it contains (never the excluded ones, because the file is
# validated before use) and, key by key, the loose ones at the root (panels,
# applets, shortcuts...), without touching the rest of the tree.
dconf_rollback_desktop() {
    local target="$1" snapshot="$2" scope_file="$3" line section verify reset_rc=0 load_rc=0
    section=""
    while IFS= read -r line; do
        case "$line" in
            \[*\])
                section="${line#[}"; section="${section%]}"
                [ "$section" = "/" ] && section=""
                if [ -n "$section" ] && ! dconf reset -f "${target}${section}/" 2>/dev/null; then
                    reset_rc=1
                fi
                ;;
            *=*)
                if [ -z "$section" ] && ! dconf reset "${target}${line%%=*}" 2>/dev/null; then
                    reset_rc=1
                fi
                ;;
        esac
    done < "$scope_file"
    printf '%s\n' "$snapshot" | dconf load "$target" 2>/dev/null || load_rc=$?
    verify=$(dconf_dump_desktop "${CINNAMON_DESKTOP_EXCLUDE_PATHS[*]}" 2>/dev/null) || return 1
    [ "$reset_rc" -eq 0 ] && [ "$load_rc" -eq 0 ] && [ "$verify" = "$snapshot" ]
}

dconf_load_desktop_clean() {
    local target="$1" file="$2" line section snapshot
    [ -f "$file" ] || return 0
    if ! dconf_desktop_file_is_safe "$file"; then
        restore_problem "$file"
        return 1
    fi
    if ! snapshot=$(dconf_dump_desktop "${CINNAMON_DESKTOP_EXCLUDE_PATHS[*]}" 2>/dev/null); then
        restore_mark_failed
        return 1
    fi
    section=""
    # shellcheck disable=SC2094  # "$file" is only read (the rollback too)
    while IFS= read -r line; do
        case "$line" in
            \[*\])
                section="${line#[}"; section="${section%]}"
                [ "$section" = "/" ] && section=""
                if [ -n "$section" ] && ! dconf reset -f "${target}${section}/" 2>/dev/null; then
                    dconf_rollback_desktop "$target" "$snapshot" "$file" || dconf_rollback_failed "$target"
                    restore_mark_failed
                    return 1
                fi
                ;;
            *=*)
                if [ -z "$section" ] && ! dconf reset "${target}${line%%=*}" 2>/dev/null; then
                    dconf_rollback_desktop "$target" "$snapshot" "$file" || dconf_rollback_failed "$target"
                    restore_mark_failed
                    return 1
                fi
                ;;
        esac
    done < "$file"
    # shellcheck disable=SC2094  # "$file" is only read
    if ! dconf load "$target" < "$file"; then
        dconf_rollback_desktop "$target" "$snapshot" "$file" || dconf_rollback_failed "$target"
        restore_mark_failed
        return 1
    fi
    return 0
}

# What is left out when packing a Mozilla-based application profile (Firefox,
# LibreWolf, Thunderbird): caches and regenerable data that only increase the
# size of the copy without adding real configuration, and lock files that must
# not be restored (the profile is saved with the application closed, so they
# should not exist, but if they were left over from a previous session we do
# not want to carry them along). These names exist only at the top of each
# profile (<root>/<profile>/NAME), so they are matched at that depth and no
# deeper: anywhere else the same name is user data, e.g. a Thunderbird mail
# folder called "crashes" or "lock" (its mbox file is named after the folder).
MOZILLA_PROFILE_SKIP=(
    cache2 startupCache shader-cache thumbnails crashes minidumps
    saved-telemetry-pings lock .parentlock
)

# Sets MOZILLA_EXCLUDES to the tar arguments for packing the profile root "$1",
# written as it is given to tar (tar_root_member: "firefox", or "firefox/." for
# a symbolic link). The *.sqlite-wal/-shm patterns, valid at any depth, go
# first: --anchored and --no-wildcards-match-slash only affect the --exclude
# options that follow them.
mozilla_excludes() {
    local root="$1" name
    MOZILLA_EXCLUDES=(--exclude='*.sqlite-wal' --exclude='*.sqlite-shm' --no-wildcards-match-slash --anchored)
    for name in "${MOZILLA_PROFILE_SKIP[@]}"; do
        MOZILLA_EXCLUDES+=(--exclude="$root/*/$name")
    done
}

# Prints the folder that holds the Firefox profiles (profiles.ini and one folder
# per profile), or returns 1 if there is none. Firefox 147+ installed on a
# machine without ~/.mozilla keeps it in ~/.config/mozilla/firefox, and keeps
# using ~/.mozilla/firefox where that already exists, so the old location is
# looked at first. A relative XDG_CONFIG_HOME is ignored, as the XDG
# specification says.
firefox_profiles_root() {
    local xdg="${XDG_CONFIG_HOME:-}"
    if [ -d "$HOME/.mozilla/firefox" ]; then
        printf '%s' "$HOME/.mozilla/firefox"
        return 0
    fi
    case "$xdg" in /*) ;; *) xdg="$HOME/.config" ;; esac
    [ -d "$xdg/mozilla/firefox" ] || return 1
    printf '%s' "$xdg/mozilla/firefox"
}

# Decodes a value generated with printf %q without evaluating it as shell.
manifest_decode_q() {
    local __out="$1" q="$2" out='' i c n inner fixed oct
    case "$q" in
        "''") out="" ;;
        \$\'*)
            [ "${q: -1}" = "'" ] || return 1
            inner="${q:2:${#q}-3}"
            # %b does not read two printf %q escapes the way $'...' does: \'
            # (it leaves it as backslash + quote) and \nnn (%b expects \0nnn:
            # \0010 would be \010 and not \001 followed by "0"). They are
            # normalized here, escape by escape, and %b does the rest.
            fixed=""
            for (( i = 0; i < ${#inner}; i++ )); do
                c="${inner:i:1}"
                if [ "$c" != "\\" ]; then
                    fixed+="$c"
                    continue
                fi
                n="${inner:i+1:1}"
                case "$n" in
                    "'") fixed+="'"; i=$((i + 1)) ;;
                    [0-7])
                        oct="$n"
                        while [ "${#oct}" -lt 3 ] && [[ "${inner:i+1+${#oct}:1}" == [0-7] ]]; do
                            oct+="${inner:i+1+${#oct}:1}"
                        done
                        i=$((i + ${#oct}))
                        oct="00$oct"
                        fixed+="\\0${oct: -3}" ;;
                    *) fixed+="$c$n"; i=$((i + 1)) ;;
                esac
            done
            printf -v out '%b' "$fixed"
            ;;
        *)
            for (( i = 0; i < ${#q}; i++ )); do
                c="${q:i:1}"
                if [ "$c" = "\\" ]; then
                    (( i++ )) || true
                    [ "$i" -lt "${#q}" ] || return 1
                    n="${q:i:1}"
                    out+="$n"
                else
                    out+="$c"
                fi
            done
            ;;
    esac
    printf -v "$__out" '%s' "$out"
}

# Reads only the known manifest fields; never runs its content.
manifest_read() {
    local file="$1" line key raw value
    NAME=""; DATE=""; MODULES=""
    # shellcheck disable=SC2034  # filled in with printf -v and read by the callers
    MINT_RELEASE=""; OS_ID=""; PKG_MANAGER=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            NAME=*|DATE=*|MODULES=*|MINT_RELEASE=*|OS_ID=*|PKG_MANAGER=*) ;;
            *) continue ;;
        esac
        key="${line%%=*}"
        raw="${line#*=}"
        manifest_decode_q value "$raw" || return 1
        printf -v "$key" '%s' "$value"
    done < "$file"
}

# Row text of the copy pickers: "name — date (size)". zenity takes the rows as
# positional arguments and rejects the WHOLE list ("This option is not
# available", nothing shown) if one starts with "-", as a copy named "-pc" does.
# A leading space keeps it a row and is not noticeable.
backup_row_label() {
    local label="$1 — $2 ($3)"
    case "$label" in -*) label=" $label" ;; esac
    printf '%s' "$label"
}

# Shows a picker with the saved configurations (most recent first) and
# returns the chosen path on stdout, or nothing if cancelled.
pick_backup_dir() {
    local title="$1" options=() d size NAME DATE
    while IFS= read -r d; do
        [ -f "$d/manifest.conf" ] || continue
        NAME=""; DATE=""
        manifest_read "$d/manifest.conf" || continue
        size=$(du -sh "$d" 2>/dev/null | cut -f1)
        [ -z "$size" ] && size="$(T "tamaño desconocido")"
        options+=("$d" "$(backup_row_label "$NAME" "$DATE" "$size")")
    done < <(find "$BACKUPS_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)

    if [ ${#options[@]} -eq 0 ]; then
        msg_error "$(T "Todavía no hay ninguna configuración guardada.")"
        return 1
    fi

    LANGUAGE="$APP_LANG" zenity --list --title="$(T "$title")" \
        --text="$(T "Selecciona una configuración guardada:")" \
        --width=520 --height=360 \
        --column="$(T "Ruta")" --column="$(T "Configuración")" \
        --hide-column=1 --print-column=1 \
        "${options[@]}" 2>/dev/null
}

# Same as pick_backup_dir, but with a checklist to choose several copies at
# once (used by "Delete saved configurations"). Each output line is a
# path.
pick_backup_dirs_multi() {
    local title="$1" options=() d size NAME DATE
    while IFS= read -r d; do
        [ -f "$d/manifest.conf" ] || continue
        NAME=""; DATE=""
        manifest_read "$d/manifest.conf" || continue
        size=$(du -sh "$d" 2>/dev/null | cut -f1)
        [ -z "$size" ] && size="$(T "tamaño desconocido")"
        options+=(FALSE "$d" "$(backup_row_label "$NAME" "$DATE" "$size")")
    done < <(find "$BACKUPS_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)

    if [ ${#options[@]} -eq 0 ]; then
        msg_error "$(T "Todavía no hay ninguna configuración guardada.")"
        return 1
    fi

    LANGUAGE="$APP_LANG" zenity --list --title="$(T "$title")" \
        --text="$(T "Marca una o varias configuraciones guardadas:")" \
        --checklist --width=560 --height=380 \
        --column="$(T "Sel")" --column="$(T "Ruta")" --column="$(T "Configuración")" \
        --hide-column=2 --print-column=2 --separator=$'\n' \
        "${options[@]}" 2>/dev/null
}

# Succeeds if any module of "$2..." appears in list $1 (space-separated).
# Used both by the warnings/confirmations and by root_preauth() to know
# whether an administrator password is needed.
modules_need_root() {
    local root_keys="$1"; shift
    local rk m
    for m in "$@"; do
        for rk in $root_keys; do
            [ "$m" = "$rk" ] && return 0
        done
    done
    return 1
}

# Privileged operations go through prun. flock serializes simultaneous calls
# (do_restore launches several privileged modules at once), so only one
# polkit dialog is open at a time. Every call asks for the administrator
# password on its own: the action pkexec checks (org.freedesktop.policykit.exec)
# is auth_admin, with no retained authorization, and pkexec ties the check to
# its parent process (here a new flock each time), so nothing is shared between
# calls. If there is no XDG_RUNTIME_DIR, a private folder in ~/.cache is used,
# never a predictable /tmp path (symlink risk).
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ -w "$XDG_RUNTIME_DIR" ]; then
    PKEXEC_LOCK_DIR="$XDG_RUNTIME_DIR"
else
    PKEXEC_LOCK_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/mint-setup"
fi
PKEXEC_LOCK="$PKEXEC_LOCK_DIR/.${APP_NAME}-pkexec.lock"

# When polkit finds no graphical agent, pkexec falls back to its own text
# prompt on the controlling terminal (</dev/null does not stop it) and that
# prompt never validates here. --disable-internal-agent (polkit >= 0.105) makes
# it fail instead ("No authentication agent found.", exit 127). Once an agent
# has answered in this run (PKEXEC_AGENT_SEEN), that failure is transient (the
# session restarting its agent): the call is retried up to PKEXEC_AGENT_RETRIES
# times, PKEXEC_AGENT_WAIT seconds apart.
# "Not authorized" (also 127) is the other transient failure, seen in a real
# restore on Mint 22.3 in a VM (Network failed, the next calls worked): the agent
# closed the request without authenticating and without a cancel, which polkitd
# reports as not authorized. After an agent has answered it is retried up to
# PKEXEC_DENIED_RETRIES times, PKEXEC_DENIED_WAIT seconds apart. A cancelled
# dialog (126) is never retried.
PKEXEC_AGENT_SEEN=0
PKEXEC_AGENT_RETRIES=20
PKEXEC_AGENT_WAIT=1
PKEXEC_DENIED_RETRIES=2
PKEXEC_DENIED_WAIT=2
# The lock folder is created the first time it is needed (so --install,
# --help or a save without privileged modules leave nothing in ~/.cache).
prun() {
    local err rc tries=0 denied=0
    if [ ! -d "$PKEXEC_LOCK_DIR" ]; then
        mkdir -p "$PKEXEC_LOCK_DIR" 2>/dev/null && chmod 700 "$PKEXEC_LOCK_DIR" 2>/dev/null
    fi
    # pkexec's stderr goes to a file to recognize the "no agent" failure, and
    # is replayed on stderr afterwards. Without a file there is no retry.
    if ! err=$(mktemp "$PKEXEC_LOCK_DIR/.${APP_NAME}-pkexec-err.XXXXXX" 2>/dev/null); then
        flock "$PKEXEC_LOCK" pkexec --disable-internal-agent "$@" </dev/null
        return
    fi
    # Registered so a TERM/HUP/INT while pkexec waits does not leave it behind.
    ms_tmp_track "$err"
    while :; do
        rc=0
        flock "$PKEXEC_LOCK" pkexec --disable-internal-agent "$@" </dev/null 2>"$err" || rc=$?
        if [ "$rc" -eq 127 ] && [ "$PKEXEC_AGENT_SEEN" -eq 1 ]; then
            if [ "$tries" -lt "$PKEXEC_AGENT_RETRIES" ] \
                && grep -q 'No authentication agent found' "$err" 2>/dev/null; then
                tries=$((tries + 1))
                sleep "$PKEXEC_AGENT_WAIT"
                continue
            fi
            if [ "$denied" -lt "$PKEXEC_DENIED_RETRIES" ] \
                && grep -q '^Error executing command as another user: Not authorized' "$err" 2>/dev/null; then
                denied=$((denied + 1))
                sleep "$PKEXEC_DENIED_WAIT"
                continue
            fi
        fi
        break
    done
    cat "$err" >&2
    ms_tmp_discard "$err"
    [ "$rc" -ne 0 ] || PKEXEC_AGENT_SEEN=1
    return "$rc"
}

# Cleanup on exit by any route. If an export was replacing an existing
# folder, it tries to put the previous copy back first; one that cannot be put
# back is kept, and its place is reported on stderr.
on_exit() {
    if ! ms_dir_swap_restore; then
        printf '%s\n' "$(T_FMT 'No se pudo devolver la copia anterior a su sitio. No se ha borrado: sigue en la carpeta oculta:\n%s' "$MS_DIR_SWAP_STUCK")" >&2
    fi
    ms_tmp_cleanup
}
trap 'on_exit' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Probe run before the progress bar opens, only if a module of "$2..." needs
# root (root_keys in "$1"). It does NOT spare any later password prompt: the
# authorization is not kept (see prun), so every privileged operation asks for
# it again. What it gives: the first dialog is not hidden behind the progress
# bar, and a successful call sets PKEXEC_AGENT_SEEN, which the modules inherit,
# so that prun retries while the session's agent is briefly gone. Returns 1
# only if it was needed and the user denied/cancelled it, or pkexec is missing.
root_preauth() {
    local root_keys="$1"; shift
    modules_need_root "$root_keys" "$@" || return 0
    command -v pkexec >/dev/null 2>&1 || return 1
    prun true 2>/dev/null || return 1
    # Margin before the modules launch their own pkexec: started right after
    # this call, the graphical agent may show a ghost dialog (it appears and
    # closes by itself). Observed, not explained.
    sleep 1.5
}

# =============================================================================
# MODULE: CINNAMON DESKTOP
# (panels, menu, applets, desklets, extensions, workspaces, hot corners,
# window behavior)
# =============================================================================

save_desktop() {
    local dir="$1/desktop"
    mkdir -p "$dir"

    log_msg "$(T "Guardando árbol de configuración de Cinnamon...")"
    # The sections that Appearance, Sound, Keyboard, Mouse, Touchpad and
    # Displays already save on their own are excluded (see
    # CINNAMON_DESKTOP_EXCLUDE_PATHS) so that Desktop is truly independent
    # of those modules. favorite-apps (the panel's favorite launchers) is
    # kept: it lives at the root.
    atomic_capture "$dir/cinnamon.dconf" dconf_dump_desktop "${CINNAMON_DESKTOP_EXCLUDE_PATHS[*]}" 2>/dev/null || save_problem "$dir/cinnamon.dconf"

    log_msg "$(T "Guardando applets/desklets/extensiones instalados por el usuario...")"
    pack_dir "$HOME/.local/share/cinnamon/applets"    "$dir/user-applets.tar.gz"
    pack_dir "$HOME/.local/share/cinnamon/desklets"   "$dir/user-desklets.tar.gz"
    pack_dir "$HOME/.local/share/cinnamon/extensions" "$dir/user-extensions.tar.gz"

    # The own settings of each applet/desklet instance (e.g. the menu icon,
    # an applet's text, or a weather applet's location) do not live in dconf:
    # Cinnamon stores them as JSON in ~/.config/cinnamon/spices/<uuid>/<n>.json
    # (Cinnamon 5 onwards) or in ~/.cinnamon/configs/ (older versions). Both
    # are saved.
    log_msg "$(T "Guardando ajustes de applets/desklets (icono del menú y demás)...")"
    pack_dir "$HOME/.config/cinnamon/spices" "$dir/spices.tar.gz"
    pack_dir "$HOME/.cinnamon/configs" "$dir/configs.tar.gz"

    # When the menu icon is chosen as a "custom file" (instead of a theme
    # icon), Cinnamon copies it loose into the root of ~/.cinnamon/ (e.g.
    # .menu.svg), outside configs/. Without this that icon is lost on restore
    # even though the JSON above still points to it.
    log_msg "$(T "Guardando icono de menú personalizado (si lo hay)...")"
    if [ -d "$HOME/.cinnamon" ] && [ -n "$(find "$HOME/.cinnamon" -maxdepth 1 -type f -print -quit 2>/dev/null)" ]; then
        find "$HOME/.cinnamon" -maxdepth 1 -type f -printf '%f\0' 2>/dev/null \
            | atomic_tar "$dir/cinnamon-root-files.tar.gz" -C "$HOME/.cinnamon" --null -T - || save_problem "$HOME/.cinnamon"
    fi

    log_msg "$(T "Escritorio Cinnamon guardado.")"
}

restore_desktop() {
    local dir="$1/desktop"
    if [ ! -d "$dir" ]; then
        log_msg "$(T "No hay datos de escritorio en esta configuración guardada.")"
        return 0
    fi

    mkdir -p "$HOME/.local/share/cinnamon"
    [ -f "$dir/user-applets.tar.gz" ]    && { log_msg "$(T "Restaurando applets...")"; safe_extract "$dir/user-applets.tar.gz" "$HOME/.local/share/cinnamon" || restore_problem "$dir/user-applets.tar.gz"; }
    [ -f "$dir/user-desklets.tar.gz" ]   && { log_msg "$(T "Restaurando desklets...")"; safe_extract "$dir/user-desklets.tar.gz" "$HOME/.local/share/cinnamon" || restore_problem "$dir/user-desklets.tar.gz"; }
    [ -f "$dir/user-extensions.tar.gz" ] && { log_msg "$(T "Restaurando extensiones...")"; safe_extract "$dir/user-extensions.tar.gz" "$HOME/.local/share/cinnamon" || restore_problem "$dir/user-extensions.tar.gz"; }
    if [ -f "$dir/spices.tar.gz" ] || [ -f "$dir/configs.tar.gz" ]; then
        log_msg "$(T "Restaurando ajustes de applets/desklets (icono del menú y demás)...")"
        unpack_dir "$dir/spices.tar.gz" "$HOME/.config/cinnamon"
        unpack_dir "$dir/configs.tar.gz" "$HOME/.cinnamon"
    fi
    [ -f "$dir/cinnamon-root-files.tar.gz" ] && { log_msg "$(T "Restaurando icono de menú personalizado...")"; unpack_dir "$dir/cinnamon-root-files.tar.gz" "$HOME/.cinnamon"; }

    if [ -f "$dir/cinnamon.dconf" ]; then
        log_msg "$(T "Restaurando árbol de configuración de Cinnamon...")"
        dconf_load_desktop_clean /org/cinnamon/ "$dir/cinnamon.dconf"
    fi

    if restore_clean_end; then log_msg "$(T "Escritorio Cinnamon restaurado. Puede que necesites reiniciar Cinnamon (Ctrl+Alt+Esc) o cerrar sesión.")"; fi
}

# =============================================================================
# MODULE: APPEARANCE
# (theme, light/dark, icons, cursor, fonts, wallpaper, screensaver)
# =============================================================================

save_appearance() {
    local dir="$1/appearance"
    mkdir -p "$dir"

    log_msg "$(T "Guardando tema, iconos, cursor y fuentes...")"
    dconf_dump_atomic /org/cinnamon/desktop/interface/ "$dir/interface.dconf"

    # "Prefer dark mode" (Themes) does NOT live under /org/cinnamon/: it is
    # stored in org.x.apps.portal (used by Nemo, Xed and the rest of the
    # X-Apps) and must also be mirrored in org.gnome.desktop.interface so
    # GTK4/libadwaita and Flatpak apps (Firefox included) follow the same mode.
    log_msg "$(T "Guardando preferencia de modo claro/oscuro...")"
    dconf_dump_atomic /org/x/apps/portal/ "$dir/xapps-portal.dconf"
    atomic_capture "$dir/gnome-color-scheme.value" gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null || save_problem "$dir/gnome-color-scheme.value"

    # The "Desktop" theme (panels, menu, applets) is a different setting from
    # the one above: a copy is saved here in case Appearance is restored
    # without Desktop. The Desktop module also includes it (it is part of its
    # full /org/cinnamon/ dump), so restoring either one already applies it;
    # saving it here just avoids having to tick both modules at once to get
    # the complete look back.
    log_msg "$(T "Guardando tema de Cinnamon (Escritorio)...")"
    dconf_dump_atomic /org/cinnamon/theme/ "$dir/cinnamon-theme.dconf"

    log_msg "$(T "Guardando tema de ventanas...")"
    dconf_dump_atomic /org/cinnamon/desktop/wm/preferences/ "$dir/wm-preferences.dconf"

    log_msg "$(T "Guardando protector de pantalla...")"
    dconf_dump_atomic /org/cinnamon/desktop/screensaver/ "$dir/screensaver.dconf"

    log_msg "$(T "Guardando configuración del fondo de pantalla...")"
    dconf_dump_atomic /org/cinnamon/desktop/background/ "$dir/background.dconf"

    # We also copy the real image file (light and dark): after a clean
    # install the saved path may not exist yet.
    save_wallpaper_uri "$dir" picture-uri ""
    save_wallpaper_uri "$dir" picture-uri-dark "-dark"

    log_msg "$(T "Guardando configuración GTK3...")"
    save_copy "$HOME/.config/gtk-3.0/settings.ini" "$dir/gtk3-settings.ini"

    # The previous steps only save the NAME of the theme/icons/cursor (the
    # dconf key). If it is a theme the user downloaded (not shipped with Mint
    # by default), that name is useless after a clean install unless the
    # theme folder also exists. We pack the folders where that content
    # lives, only if they exist.
    log_msg "$(T "Guardando archivos de temas GTK/Cinnamon instalados por el usuario...")"
    pack_dir "$HOME/.themes"             "$dir/themes.tar.gz"
    pack_dir "$HOME/.local/share/themes" "$dir/themes-local.tar.gz"

    log_msg "$(T "Guardando archivos de temas de iconos y cursor instalados por el usuario...")"
    pack_dir "$HOME/.icons"              "$dir/icons.tar.gz"
    pack_dir "$HOME/.local/share/icons"  "$dir/icons-local.tar.gz"

    log_msg "$(T "Guardando fuentes instaladas por el usuario...")"
    pack_dir "$HOME/.fonts"              "$dir/fonts.tar.gz"
    pack_dir "$HOME/.local/share/fonts"  "$dir/fonts-local.tar.gz"

    log_msg "$(T "Apariencia guardada.")"
}

restore_appearance() {
    local dir="$1/appearance"
    if [ ! -d "$dir" ]; then
        log_msg "$(T "No hay datos de apariencia en esta configuración guardada.")"
        return 0
    fi

    # We restore the theme/icon/cursor/font FILES first, and only then the
    # dconf settings that name them by key. If it were done the other way
    # round, the theme name would be set a moment before its files actually
    # exist (although in practice Cinnamon does not reread the theme until
    # you log out and back in, so this order is mostly for clarity and
    # to cover the case of scripts that restart Cinnamon right after
    # restoring).
    log_msg "$(T "Restaurando archivos de temas GTK/Cinnamon...")"
    unpack_dir "$dir/themes.tar.gz"       "$HOME"
    unpack_dir "$dir/themes-local.tar.gz" "$HOME/.local/share"

    log_msg "$(T "Restaurando archivos de temas de iconos y cursor...")"
    unpack_dir "$dir/icons.tar.gz"        "$HOME"
    unpack_dir "$dir/icons-local.tar.gz"  "$HOME/.local/share"

    if [ -f "$dir/fonts.tar.gz" ] || [ -f "$dir/fonts-local.tar.gz" ]; then
        log_msg "$(T "Restaurando fuentes instaladas por el usuario...")"
        unpack_dir "$dir/fonts.tar.gz"       "$HOME"
        unpack_dir "$dir/fonts-local.tar.gz" "$HOME/.local/share"
        if command -v fc-cache >/dev/null 2>&1; then
            fc-cache -f "$HOME/.fonts" "$HOME/.local/share/fonts" >/dev/null 2>&1 || true
        else
            log_msg "$(T "Aviso: fc-cache no está disponible; puede que las fuentes no se vean hasta reiniciar sesión.")"
        fi
    fi

    [ -f "$dir/interface.dconf" ]      && { log_msg "$(T "Restaurando tema, iconos, cursor y fuentes...")"; dconf_load_clean /org/cinnamon/desktop/interface/ "$dir/interface.dconf"; }
    if [ -f "$dir/xapps-portal.dconf" ] || [ -s "$dir/gnome-color-scheme.value" ]; then
        log_msg "$(T "Restaurando preferencia de modo claro/oscuro...")"
        [ -f "$dir/xapps-portal.dconf" ] && dconf_load_clean /org/x/apps/portal/ "$dir/xapps-portal.dconf"
        if [ -s "$dir/gnome-color-scheme.value" ] \
            && ! gsettings set org.gnome.desktop.interface color-scheme "$(cat "$dir/gnome-color-scheme.value")" 2>/dev/null; then
            restore_mark_failed
            log_msg "$(T "Aviso: no se pudo restaurar la preferencia de modo claro/oscuro de GNOME.")"
        fi
    fi
    [ -f "$dir/cinnamon-theme.dconf" ] && { log_msg "$(T "Restaurando tema de Cinnamon (Escritorio)...")"; dconf_load_clean /org/cinnamon/theme/ "$dir/cinnamon-theme.dconf"; }
    [ -f "$dir/wm-preferences.dconf" ] && { log_msg "$(T "Restaurando tema de ventanas...")"; dconf_load_clean /org/cinnamon/desktop/wm/preferences/ "$dir/wm-preferences.dconf"; }
    [ -f "$dir/screensaver.dconf" ]    && { log_msg "$(T "Restaurando protector de pantalla...")"; dconf_load_clean /org/cinnamon/desktop/screensaver/ "$dir/screensaver.dconf"; }

    # We load the wallpaper dconf tree first (picture-options, colors...).
    dconf_load_clean /org/cinnamon/desktop/background/ "$dir/background.dconf"

    # And THEN we fix picture-uri (and its -dark variant) so they point to
    # the local copy of the wallpaper. If this were done before the dconf load,
    # the load would overwrite the saved original path, which may not exist
    # after a clean install. xdg_dir() is used inside the helper instead of
    # assuming "$HOME/Pictures", for machines installed in another language.
    if [ -f "$dir/wallpaper.filename" ] || [ -f "$dir/wallpaper-dark.filename" ]; then
        log_msg "$(T "Restaurando fondo de pantalla...")"
        restore_wallpaper_uri "$dir" picture-uri ""
        restore_wallpaper_uri "$dir" picture-uri-dark "-dark"
    fi

    if [ -f "$dir/gtk3-settings.ini" ]; then
        log_msg "$(T "Restaurando configuración GTK3...")"
        mkdir -p "$HOME/.config/gtk-3.0"
        atomic_copy "$dir/gtk3-settings.ini" "$HOME/.config/gtk-3.0/settings.ini"
    fi

    if restore_clean_end; then log_msg "$(T "Apariencia restaurada.")"; fi
}

# =============================================================================
# MODULE: NEMO
# (Desktop folder, shortcuts, scripts, custom actions, prefs)
# =============================================================================

save_nemo() {
    local dir="$1/nemo"
    mkdir -p "$dir"

    log_msg "$(T "Guardando preferencias de Nemo...")"
    dconf_dump_atomic /org/nemo/ "$dir/nemo.dconf"

    log_msg "$(T "Guardando scripts de Nemo...")"
    pack_dir "$HOME/.local/share/nemo/scripts" "$dir/scripts.tar.gz"

    log_msg "$(T "Guardando acciones personalizadas...")"
    pack_dir "$HOME/.local/share/nemo/actions" "$dir/actions.tar.gz"

    log_msg "$(T "Guardando contenido del Escritorio (accesos directos incluidos)...")"
    local desk_dir
    desk_dir=$(xdg_dir DESKTOP "$HOME/Escritorio")
    [ -d "$desk_dir" ] || desk_dir="$HOME/Desktop"
    pack_dir "$desk_dir" "$dir/desktop-files.tar.gz"

    log_msg "$(T "Guardando lanzadores personalizados (menú, AppImages, etc.)...")"
    pack_dir "$HOME/.local/share/applications" "$dir/user-launchers.tar.gz"

    log_msg "$(T "Guardando marcadores de la barra lateral de Nemo...")"
    save_copy "$HOME/.config/gtk-3.0/bookmarks" "$dir/bookmarks"

    log_msg "$(T "Nemo guardado.")"
    log_msg "$(T "Nota: la posición exacta de los iconos del escritorio depende de los metadatos internos (GVFS) ligados a cada instalación, así que no se puede garantizar al 100% tras una instalación limpia.")"
}

restore_nemo() {
    local dir="$1/nemo"
    if [ ! -d "$dir" ]; then
        log_msg "$(T "No hay datos de Nemo en esta configuración guardada.")"
        return 0
    fi

    [ -f "$dir/nemo.dconf" ] && { log_msg "$(T "Restaurando preferencias de Nemo...")"; dconf_load_clean /org/nemo/ "$dir/nemo.dconf"; }

    mkdir -p "$HOME/.local/share/nemo"
    [ -f "$dir/scripts.tar.gz" ] && { log_msg "$(T "Restaurando scripts de Nemo...")"; safe_extract "$dir/scripts.tar.gz" "$HOME/.local/share/nemo" || restore_problem "$dir/scripts.tar.gz"; }
    [ -f "$dir/actions.tar.gz" ] && { log_msg "$(T "Restaurando acciones personalizadas...")"; safe_extract "$dir/actions.tar.gz" "$HOME/.local/share/nemo" || restore_problem "$dir/actions.tar.gz"; }

    if [ -f "$dir/desktop-files.tar.gz" ]; then
        log_msg "$(T "Restaurando accesos directos del Escritorio (sin sobrescribir archivos existentes)...")"
        # safe_extract(..., keep) keeps any launcher that already existed.
        # Before publishing the extraction we only record the .desktop files
        # that are really new; that way we never change permissions or metadata
        # of a pre-existing launcher just because another copy was restored.
        # The copy stores the Desktop under the name it had when it was saved
        # (Escritorio, Desktop, Bureau...), which is not necessarily what THIS
        # system calls it: the content goes to this system's Desktop folder, not
        # to $HOME/<saved name>. Without a known Desktop folder (no xdg-user-dir)
        # the saved name under $HOME is used.
        local desk_name desk_dir f rel
        local -a new_desktop_launchers=()
        desk_name=$(tar tzf "$dir/desktop-files.tar.gz" 2>/dev/null | head -1 | cut -d/ -f1)
        desk_dir=$(xdg_dir DESKTOP "$HOME/${desk_name:-Desktop}")
        if [ -n "$desk_name" ]; then
            while IFS= read -r rel; do
                case "$rel" in
                    "$desk_name/"*.desktop)
                        rel="${rel#"$desk_name/"}"
                        f="$desk_dir/${rel#./}"
                        if [ ! -e "$f" ] && [ ! -L "$f" ]; then
                            new_desktop_launchers+=("$f")
                        fi
                        ;;
                esac
            done < <(tar tzf "$dir/desktop-files.tar.gz" 2>/dev/null)
        fi
        if ! safe_extract "$dir/desktop-files.tar.gz" "$desk_dir" keep 1; then
            restore_problem "$dir/desktop-files.tar.gz"
        else
            # Nemo (like Nautilus) requires every .desktop on the Desktop to
            # have the execute permission AND the metadata::trusted attribute,
            # or it shows it as "untrusted" (generic icon, warning on opening)
            # and it has to be authorized by hand once per file. Here we
            # reproduce what Nemo does when the user chooses "Trust and Launch",
            # but only for the launchers we have just restored.
            if [ ${#new_desktop_launchers[@]} -gt 0 ]; then
                if command -v gio >/dev/null 2>&1; then
                    log_msg "$(T "Marcando los accesos directos del Escritorio como de confianza...")"
                    local trust_failed=0
                    for f in "${new_desktop_launchers[@]}"; do
                        [ -f "$f" ] || continue
                        chmod +x "$f" 2>/dev/null || trust_failed=1
                        gio set "$f" metadata::trusted true 2>/dev/null || trust_failed=1
                    done
                    [ "$trust_failed" -eq 1 ] && log_msg "$(T "Aviso: no se pudo marcar algún acceso directo como de confianza (esto es normal si lo ejecutas fuera de una sesión de escritorio real, p. ej. por SSH). Ábrelo una vez desde Nemo y elige 'Confiar y lanzar' si hace falta.")"
                    log_msg "$(T "Nota: si el Escritorio no muestra todavía el icono como de confianza, pulsa F5 sobre él para refrescar la vista; Nemo no siempre lo redibuja solo.")"
                else
                    log_msg "$(T "Aviso: gio no está disponible; puede que tengas que autorizar cada acceso directo del Escritorio manualmente (clic derecho > Permitir lanzamiento).")"
                fi
            fi
        fi
    fi

    if [ -f "$dir/user-launchers.tar.gz" ]; then
        log_msg "$(T "Restaurando lanzadores personalizados (sin sobrescribir archivos existentes)...")"
        mkdir -p "$HOME/.local/share/applications"
        safe_extract "$dir/user-launchers.tar.gz" "$HOME/.local/share" keep || restore_problem "$dir/user-launchers.tar.gz"
    fi

    if [ -f "$dir/bookmarks" ]; then
        log_msg "$(T "Restaurando marcadores de la barra lateral de Nemo...")"
        mkdir -p "$HOME/.config/gtk-3.0"
        atomic_copy "$dir/bookmarks" "$HOME/.config/gtk-3.0/bookmarks"
    fi

    if restore_clean_end; then log_msg "$(T "Nemo restaurado.")"; fi
}

# =============================================================================
# MODULE: APPLICATIONS
# (user APT packages, Flatpak, additional repositories)
# =============================================================================

save_software() {
    local dir="$1/software"
    mkdir -p "$dir"

    if command -v apt-mark >/dev/null 2>&1; then
        log_msg "$(T "Guardando paquetes APT instalados manualmente...")"
        atomic_capture "$dir/apt-manual.list" bash -o pipefail -c 'apt-mark showmanual 2>/dev/null | sort' _ 2>/dev/null || save_problem "$dir/apt-manual.list"
    fi

    # Other managers: only the list is saved (read-only query); restoring is
    # guided because this program does not install native dnf or pacman
    # packages by itself.
    case "$PLATFORM_PKG" in
        dnf)
            log_msg "$(T_FMT 'Guardando paquetes instalados manualmente con %s...' dnf)"
            atomic_capture "$dir/native-packages.list" bash -o pipefail -c \
                "dnf repoquery --userinstalled --queryformat '%{name}\\n' 2>/dev/null | sed 's/\\\\n/\\n/g' | sed '/^\$/d' | sort -u" _ 2>/dev/null \
                || save_problem "$dir/native-packages.list"
            printf '%s\n' dnf | atomic_write "$dir/native-packages.manager" || save_problem "$dir/native-packages.manager"
            ;;
        pacman)
            log_msg "$(T_FMT 'Guardando paquetes instalados manualmente con %s...' pacman)"
            atomic_capture "$dir/native-packages.list" bash -o pipefail -c 'pacman -Qqen 2>/dev/null | sort -u' _ 2>/dev/null \
                || save_problem "$dir/native-packages.list"
            printf '%s\n' pacman | atomic_write "$dir/native-packages.manager" || save_problem "$dir/native-packages.manager"
            ;;
    esac

    if command -v flatpak >/dev/null 2>&1; then
        log_msg "$(T "Guardando repositorios Flatpak (remotes)...")"
        atomic_capture "$dir/flatpak-remotes.list" flatpak remotes --columns=name,url 2>/dev/null || save_problem "$dir/flatpak-remotes.list"

        log_msg "$(T "Guardando aplicaciones Flatpak...")"
        atomic_capture "$dir/flatpak.list" flatpak list --app --columns=application,origin 2>/dev/null || save_problem "$dir/flatpak.list"
    fi

    log_msg "$(T "Guardando repositorios adicionales...")"
    pack_dir /etc/apt/sources.list.d "$dir/sources-list-d.tar.gz"
    pack_dir /etc/apt/keyrings       "$dir/keyrings.tar.gz"
    pack_dir /etc/apt/trusted.gpg.d  "$dir/trusted-gpg-d.tar.gz"

    local n
    if [ -f "$dir/native-packages.list" ]; then
        n=$(wc -l < "$dir/native-packages.list" 2>/dev/null || echo 0)
        log_msg "$(T_FMT 'Aplicaciones guardadas (%s paquetes de %s).' "$n" "$PLATFORM_PKG")"
    else
        n=$(wc -l < "$dir/apt-manual.list" 2>/dev/null || echo 0)
        log_msg "$(T_FMT 'Aplicaciones guardadas (%s paquetes APT).' "$n")"
    fi
}

restore_software() {
    local dir="$1/software" module_failed=0
    if [ ! -d "$dir" ]; then
        log_msg "$(T "No hay datos de aplicaciones en esta configuración guardada.")"
        return 0
    fi

    # Short timeouts so that a down/obsolete additional repository (very
    # typical when restoring on a new installation: PPAs that no longer
    # exist or have no package for this Mint version) fails fast instead
    # of waiting out apt's default timeouts.
    local -a APT_FAST=(-o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15 -o Acquire::Retries=1)
    local apt_updated=0 apt_ok=1
    if ! command -v apt-get >/dev/null 2>&1 || ! command -v apt-cache >/dev/null 2>&1; then
        apt_ok=0
        if [ -s "$dir/apt-manual.list" ] || [ -f "$dir/sources-list-d.tar.gz" ] || [ -f "$dir/keyrings.tar.gz" ] || [ -f "$dir/trusted-gpg-d.tar.gz" ]; then
            log_msg "$(T_FMT 'Aviso: esta configuración contiene datos APT (Debian, Ubuntu, Mint) pero este sistema no usa APT; se omiten. La lista guardada está en: %s' "$dir/apt-manual.list")"
            module_failed=1
        fi
    fi
    if [ "$apt_ok" -eq 1 ] && { [ -f "$dir/sources-list-d.tar.gz" ] || [ -f "$dir/keyrings.tar.gz" ] || [ -f "$dir/trusted-gpg-d.tar.gz" ]; }; then
        log_msg "$(T "Restaurando repositorios adicionales (se pedirá contraseña de administrador)...")"
        local tmp tar_failed=0 repo_rc=0
        if ! tmp=$(mktemp -d); then
            log_msg "$(T "No se pudo crear una carpeta temporal. Comprueba que hay espacio libre en el disco.")"
            module_failed=1
        else
            ms_tmp_track "$tmp"
            # -p keeps the saved modes: the root copy below needs them (see copy_tree).
            if [ -f "$dir/sources-list-d.tar.gz" ] && ! tar_archive_is_safe "$dir/sources-list-d.tar.gz"; then
                tar_failed=1
            elif [ -f "$dir/sources-list-d.tar.gz" ] && ! tar xzpf "$dir/sources-list-d.tar.gz" -C "$tmp" 2>/dev/null; then
                tar_failed=1
            fi
            if [ -f "$dir/keyrings.tar.gz" ] && ! tar_archive_is_safe "$dir/keyrings.tar.gz"; then
                tar_failed=1
            elif [ -f "$dir/keyrings.tar.gz" ] && ! tar xzpf "$dir/keyrings.tar.gz" -C "$tmp" 2>/dev/null; then
                tar_failed=1
            fi
            if [ -f "$dir/trusted-gpg-d.tar.gz" ] && ! tar_archive_is_safe "$dir/trusted-gpg-d.tar.gz"; then
                tar_failed=1
            elif [ -f "$dir/trusted-gpg-d.tar.gz" ] && ! tar xzpf "$dir/trusted-gpg-d.tar.gz" -C "$tmp" 2>/dev/null; then
                tar_failed=1
            fi
            if [ "$tar_failed" -ne 0 ]; then
                log_msg "$(T "Aviso: al menos un archivo de repositorios guardado está dañado, incompleto o no es seguro; no se restaurarán esos repositorios.")"
                module_failed=1
            fi
            if [ "$tar_failed" -eq 0 ] && command -v pkexec >/dev/null 2>&1; then
            # Copies each new file to a temporary one in its final directory.
            # Existing ones are kept, same as with cp -rn. Each file keeps the
            # saved read bits (at most 644): apt reads keyrings as the _apt user
            # and the sources as a normal user, so a blanket 600 breaks them.
            # shellcheck disable=SC2016
            prun bash -c '
                # Byte-wise reading: in a UTF-8 locale a name that ends in an incomplete
                # multibyte sequence makes "read -d" drop the next entry.
                LC_ALL=C
                umask 022   # new folders under /etc/apt must stay traversable
                src_root="$1"
                copy_tree() {
                    local src="$1" dst="$2" entry rel target parent tmp_file mode
                    [ -d "$src" ] || return 0
                    while IFS= read -r -d "" entry; do
                        rel="${entry#"$src"/}"
                        target="$dst/$rel"
                        if [ -e "$target" ] || [ -L "$target" ]; then
                            continue
                        fi
                        parent="${target%/*}"
                        mkdir -p -- "$parent" || return 1
                        mode=$(stat -c %a -- "$entry") || return 1
                        tmp_file=$(mktemp -- "$parent/.${target##*/}.mstmp.XXXXXX") || return 1
                        if cp -- "$entry" "$tmp_file" && chmod "$(printf "%o" $(( 0$mode & 0644 )))" -- "$tmp_file" && sync -- "$tmp_file" 2>/dev/null; then
                            if [ -e "$target" ] || [ -L "$target" ]; then
                                rm -f -- "$tmp_file"
                            elif ! mv -T -- "$tmp_file" "$target" || ! sync -- "$parent" 2>/dev/null; then
                                rm -f -- "$tmp_file"
                                return 1
                            fi
                        else
                            rm -f -- "$tmp_file"
                            return 1
                        fi
                    done < <(find "$src" -type f -print0 2>/dev/null)
                }
                copy_tree "$src_root/sources.list.d" /etc/apt/sources.list.d || exit 1
                copy_tree "$src_root/keyrings" /etc/apt/keyrings || exit 1
                copy_tree "$src_root/trusted.gpg.d" /etc/apt/trusted.gpg.d || exit 1
                # Exit 2: the files are published and only the refresh failed.
                apt-get update "${@:2}" || exit 2
            ' _ "$tmp" "${APT_FAST[@]}" || repo_rc=$?
            case "$repo_rc" in
                0) apt_updated=1 ;;
                2)
                    # A repository that no longer exists is the usual cause;
                    # a second update would end the same way, so it is skipped.
                    apt_updated=1
                    module_failed=1
                    log_msg "$(T "Aviso: los repositorios se restauraron, pero «apt-get update» terminó con errores (algún repositorio puede haber dejado de existir o no responder).")"
                    ;;
                *)
                    log_msg "$(T "Aviso: no se pudieron restaurar los repositorios (permisos denegados o cancelado).")"
                    module_failed=1
                    ;;
            esac
            elif [ "$tar_failed" -eq 0 ]; then
                log_msg "$(T "Aviso: pkexec no está disponible; no se pueden restaurar los repositorios automáticamente.")"
                module_failed=1
            fi
            ms_tmp_discard "$tmp"
        fi
    fi

    if [ "$apt_ok" -eq 1 ] && [ -f "$dir/apt-manual.list" ] && [ -s "$dir/apt-manual.list" ]; then
        # A refresh is only needed here if the previous block did not do it
        # already (a copy without its own repositories, or pkexec failed
        # there): it avoids calling "apt-get update" twice in a row, which
        # used to double this part of the restore time for no benefit.
        if [ "$apt_updated" -eq 0 ] && command -v pkexec >/dev/null 2>&1; then
            if prun apt-get update "${APT_FAST[@]}"; then
                apt_updated=1
            else
                module_failed=1
                log_msg "$(T "Aviso: no se pudo actualizar la caché APT antes de instalar los paquetes.")"
            fi
        fi
        log_msg "$(T "Comprobando qué paquetes siguen disponibles en los repositorios...")"
        # apt-get install fails as a whole (installing NOTHING) if just one of
        # the requested packages no longer exists (renamed, from a PPA that is
        # gone, etc.). We filter first so that a single unavailable package
        # does not prevent installing the rest. A single call to
        # apt-cache pkgnames (instead of one "apt-cache show" per package, which
        # with hundreds of packages reread the whole cache hundreds of times)
        # and then in-memory lookups.
        local pkg available=() unavailable=() apt_cache_names=""
        local -A known_pkgs=()
        if apt_cache_names=$(apt-cache pkgnames 2>/dev/null); then
            while IFS= read -r pkg; do
                [ -n "$pkg" ] && known_pkgs["$pkg"]=1
            done <<< "$apt_cache_names"
        else
            module_failed=1
            log_msg "$(T "Aviso: no se pudo consultar la caché APT; no se puede determinar con seguridad qué paquetes se pueden restaurar.")"
        fi
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            if [ -n "${known_pkgs[$pkg]+x}" ]; then
                available+=("$pkg")
            else
                unavailable+=("$pkg")
            fi
        done < "$dir/apt-manual.list"

        if [ ${#unavailable[@]} -gt 0 ]; then
            log_msg "$(T_FMT 'Aviso: %s paquete(s) ya no están disponibles en los repositorios actuales y se omitirán:' "${#unavailable[@]}")"
            printf '  - %s\n' "${unavailable[@]}"
        fi

        if [ ${#available[@]} -gt 0 ]; then
            log_msg "$(T_FMT 'Instalando %s paquete(s) APT (se pedirá contraseña de administrador)...' "${#available[@]}")"
            if command -v pkexec >/dev/null 2>&1; then
                if ! prun env DEBIAN_FRONTEND=noninteractive apt-get install -y "${available[@]}"; then
                    module_failed=1
                    log_msg "$(T "Aviso: algunos paquetes APT no se pudieron instalar.")"
                fi
            else
                module_failed=1
                log_msg "$(T_FMT 'Aviso: pkexec no está disponible; instala manualmente los paquetes listados en %s' "$dir/apt-manual.list")"
            fi
        else
            log_msg "$(T "Aviso: ninguno de los paquetes guardados está disponible para instalar.")"
        fi
    fi

    if [ -s "$dir/native-packages.list" ]; then
        local saved_mgr="" guided=""
        [ -f "$dir/native-packages.manager" ] && read -r saved_mgr < "$dir/native-packages.manager"
        if [ -n "$saved_mgr" ] && [ "$saved_mgr" = "$PLATFORM_PKG" ]; then
            case "$PLATFORM_PKG" in
                dnf)    printf -v guided 'xargs -a %q sudo dnf install' "$dir/native-packages.list" ;;
                pacman) printf -v guided 'sudo pacman -S --needed - < %q' "$dir/native-packages.list" ;;
            esac
            log_msg "$(T_FMT 'Restauración guiada de paquetes (%s): este programa no instala paquetes nativos de este gestor por su cuenta. Ejecuta tú mismo:\n  %s' "$PLATFORM_PKG" "$guided")"
        else
            log_msg "$(T_FMT 'Aviso: la lista de paquetes guardada es de %s, pero este sistema usa %s; no se aplica.' "${saved_mgr:-?}" "${PLATFORM_PKG:-?}")"
        fi
        module_failed=1
    fi

    if command -v flatpak >/dev/null 2>&1; then
        if [ -f "$dir/flatpak-remotes.list" ] && [ -s "$dir/flatpak-remotes.list" ]; then
            log_msg "$(T "Añadiendo repositorios Flatpak (remotes)...")"
            local rname rurl
            while IFS=$'\t' read -r rname rurl; do
                if [ -z "$rname" ] || [ -z "$rurl" ]; then
                    continue
                fi
                if ! flatpak remote-add --if-not-exists "$rname" "$rurl" 2>/dev/null; then
                    module_failed=1
                    log_msg "$(T_FMT 'Aviso: no se pudo añadir el repositorio Flatpak %s.' "$rname")"
                fi
            done < "$dir/flatpak-remotes.list"
        fi

        if [ -f "$dir/flatpak.list" ]; then
            log_msg "$(T "Instalando aplicaciones Flatpak...")"
            # Grouped by origin (normally all "flathub"): a single
            # "flatpak install" call per origin instead of one per app,
            # which repeated the remote metadata refresh on every
            # invocation.
            local app origin key
            local -A by_origin=()
            while IFS=$'\t' read -r app origin; do
                [ -z "$app" ] && continue
                key="${origin:-flathub}"
                by_origin["$key"]="${by_origin[$key]:-}${by_origin[$key]:+ }$app"
            done < "$dir/flatpak.list"
            for origin in "${!by_origin[@]}"; do
                # shellcheck disable=SC2086
                if ! flatpak install -y "$origin" ${by_origin[$origin]} 2>/dev/null; then
                    module_failed=1
                    log_msg "$(T_FMT 'Aviso: alguna app de %s no se pudo instalar.' "$origin")"
                fi
            done
        fi
    elif [ -s "$dir/flatpak-remotes.list" ] || [ -s "$dir/flatpak.list" ]; then
        module_failed=1
        log_msg "$(T "Aviso: hay datos Flatpak guardados, pero flatpak no está instalado en este equipo.")"
    fi

    if [ "$module_failed" -eq 0 ]; then
        log_msg "$(T "Aplicaciones restauradas.")"
        return 0
    fi
    log_msg "$(T "Aviso: Aplicaciones se restauró parcialmente; revisa los avisos anteriores.")"
    return 1
}

# =============================================================================
# MODULE: STARTUP APPLICATIONS (autostart)
# =============================================================================

save_startup() {
    local dir="$1/startup"
    mkdir -p "$dir"
    log_msg "$(T "Guardando aplicaciones de inicio...")"
    pack_dir "$HOME/.config/autostart" "$dir/autostart.tar.gz"
    log_msg "$(T "Aplicaciones de inicio guardadas.")"
}

restore_startup() {
    local dir="$1/startup"
    if [ ! -d "$dir" ]; then
        log_msg "$(T "No hay datos de aplicaciones de inicio en esta configuración guardada.")"
        return 0
    fi
    mkdir -p "$HOME/.config"
    unpack_dir "$dir/autostart.tar.gz" "$HOME/.config"
    if restore_clean_end; then log_msg "$(T "Aplicaciones de inicio restauradas.")"; fi
}

# =============================================================================
# MODULE: DISPLAYS
# (monitor layout/resolution and xrandr plugin settings)
# =============================================================================

save_displays() {
    local dir="$1/displays"
    mkdir -p "$dir"

    log_msg "$(T "Guardando distribución de monitores...")"
    save_copy "$HOME/.config/monitors.xml" "$dir/monitors.xml"

    log_msg "$(T "Guardando configuración del plugin xrandr...")"
    dconf_dump_atomic /org/cinnamon/settings-daemon/plugins/xrandr/ "$dir/xrandr.dconf"

    log_msg "$(T "Pantallas guardadas.")"
}

restore_displays() {
    local dir="$1/displays"
    if [ ! -d "$dir" ]; then
        log_msg "$(T "No hay datos de pantallas en esta configuración guardada.")"
        return 0
    fi

    if [ -f "$dir/monitors.xml" ]; then
        log_msg "$(T "Restaurando distribución de monitores...")"
        mkdir -p "$HOME/.config"
        atomic_copy "$dir/monitors.xml" "$HOME/.config/monitors.xml"
    fi

    [ -f "$dir/xrandr.dconf" ] && { log_msg "$(T "Restaurando configuración del plugin xrandr...")"; dconf_load_clean /org/cinnamon/settings-daemon/plugins/xrandr/ "$dir/xrandr.dconf"; }

    if restore_clean_end; then log_msg "$(T "Pantallas restauradas.")"; fi
    log_msg "$(T "Nota: monitors.xml está ligado al identificador (EDID) de cada monitor;")"
    log_msg "$(T "si el hardware de pantalla ha cambiado, puede que tengas que reajustar")"
    log_msg "$(T "la distribución desde Configuración > Pantallas.")"
}

# =============================================================================
# MODULE: SOUND
# (sound/event theme and default output/input device)
# =============================================================================

save_sound() {
    local dir="$1/sound"
    mkdir -p "$dir"

    log_msg "$(T "Guardando tema de sonido y eventos...")"
    dconf_dump_atomic /org/cinnamon/desktop/sound/ "$dir/sound.dconf"

    if command -v pactl >/dev/null 2>&1; then
        log_msg "$(T "Guardando dispositivo de salida/entrada predeterminado...")"
        atomic_capture "$dir/default-sink.txt" pactl get-default-sink 2>/dev/null || save_problem "$dir/default-sink.txt"
        atomic_capture "$dir/default-source.txt" pactl get-default-source 2>/dev/null || save_problem "$dir/default-source.txt"
    else
        log_msg "$(T "Aviso: pactl no está instalado; solo se guarda el tema de sonido, no el dispositivo predeterminado.")"
    fi

    log_msg "$(T "Sonido guardado.")"
}

restore_sound() {
    local dir="$1/sound"
    if [ ! -d "$dir" ]; then
        log_msg "$(T "No hay datos de sonido en esta configuración guardada.")"
        return 0
    fi

    [ -f "$dir/sound.dconf" ] && { log_msg "$(T "Restaurando tema de sonido y eventos...")"; dconf_load_clean /org/cinnamon/desktop/sound/ "$dir/sound.dconf"; }

    if command -v pactl >/dev/null 2>&1; then
        if [ -s "$dir/default-sink.txt" ]; then
            log_msg "$(T "Restaurando dispositivo de salida predeterminado...")"
            pactl set-default-sink "$(cat "$dir/default-sink.txt")" 2>/dev/null || log_msg "$(T "Aviso: no se pudo restaurar el dispositivo de salida (puede que ya no exista).")"
        fi
        if [ -s "$dir/default-source.txt" ]; then
            log_msg "$(T "Restaurando dispositivo de entrada predeterminado...")"
            pactl set-default-source "$(cat "$dir/default-source.txt")" 2>/dev/null || log_msg "$(T "Aviso: no se pudo restaurar el dispositivo de entrada (puede que ya no exista).")"
        fi
    else
        log_msg "$(T "Aviso: pactl no está instalado; no se restaura el dispositivo predeterminado.")"
    fi

    if restore_clean_end; then log_msg "$(T "Sonido restaurado.")"; fi
}

# =============================================================================
# MODULE: NETWORK
# (saved NetworkManager connections)
# ⚠️ Requires administrator permissions both to save and to restore,
# because /etc/NetworkManager/system-connections/ can only be read by root.
# ⚠️ It usually includes Wi-Fi passwords in plain text.
# =============================================================================

save_network() {
    local dir="$1/network"
    mkdir -p "$dir"

    if ! command -v pkexec >/dev/null 2>&1; then
        log_msg "$(T "Aviso: pkexec no está disponible; no se puede guardar la configuración de red (requiere acceso root).")"
        return 1
    fi

    log_msg "$(T "Guardando conexiones de NetworkManager (se pedirá contraseña de administrador)...")"
    if atomic_capture "$dir/system-connections.tar.gz" prun bash -c 'tar czf - -C /etc/NetworkManager system-connections 2>/dev/null' 2>/dev/null; then
        chmod 600 "$dir/system-connections.tar.gz"
        log_msg "$(T "Conexiones de red guardadas.")"
    else
        save_problem "$dir/system-connections.tar.gz"
    fi
}

restore_network() {
    local dir="$1/network"
    if [ ! -f "$dir/system-connections.tar.gz" ]; then
        log_msg "$(T "No hay datos de red en esta configuración guardada.")"
        return 0
    fi

    if ! command -v pkexec >/dev/null 2>&1; then
        log_msg "$(T "Aviso: pkexec no está disponible; no se puede restaurar la configuración de red (requiere acceso root).")"
        return 1
    fi

    log_msg "$(T "Restaurando conexiones de NetworkManager, sin sobrescribir las existentes (se pedirá contraseña de administrador)...")"
    local tmp
    if ! tmp=$(mktemp -d); then
        log_msg "$(T "No se pudo crear una carpeta temporal. Comprueba que hay espacio libre en el disco.")"
        return 1
    fi
    ms_tmp_track "$tmp"
    if ! tar_archive_is_safe "$dir/system-connections.tar.gz"; then
        log_msg "$(T "Aviso: el archivo de conexiones de red contiene rutas no seguras; no se pudo restaurar.")"
        ms_tmp_discard "$tmp"
        return 1
    fi
    if ! tar xzf "$dir/system-connections.tar.gz" -C "$tmp" 2>/dev/null; then
        log_msg "$(T "Aviso: el archivo de conexiones de red guardado está dañado o incompleto; no se pudo restaurar.")"
        ms_tmp_discard "$tmp"
        return 1
    fi
    # Each new connection is published from a temporary file in the same
    # directory; existing ones are still never overwritten.
    # shellcheck disable=SC2016
    if prun bash -c '
        # Byte-wise reading: in a UTF-8 locale a name that ends in an incomplete
        # multibyte sequence makes "read -d" drop the next entry.
        LC_ALL=C
        src_root="$1/system-connections"
        dst_root=/etc/NetworkManager/system-connections
        mkdir -p -- "$dst_root" || exit 1
        [ -d "$src_root" ] || exit 0
        ec=0
        while IFS= read -r -d "" src; do
            rel="${src#"$src_root/"}"
            dst="$dst_root/$rel"
            if [ -e "$dst" ] || [ -L "$dst" ]; then
                continue
            fi
            parent=$(dirname -- "$dst")
            mkdir -p -- "$parent" || { ec=1; continue; }
            tmp_file=$(mktemp -- "$parent/.${dst##*/}.mstmp.XXXXXX") || { ec=1; continue; }
            if cp -- "$src" "$tmp_file" && chmod 600 -- "$tmp_file" && sync -- "$tmp_file"; then
                mv -T -- "$tmp_file" "$dst" || { rm -f -- "$tmp_file"; ec=1; }
            else
                rm -f -- "$tmp_file"
                ec=1
            fi
        done < <(find "$src_root" -type f -print0)
        systemctl restart NetworkManager 2>/dev/null || true
        exit "$ec"
    ' _ "$tmp"; then
        log_msg "$(T "Conexiones de red restauradas.")"
        ms_tmp_discard "$tmp"
        return 0
    fi
    log_msg "$(T "Aviso: no se pudieron restaurar las conexiones de red (permisos denegados, espacio insuficiente o cancelado).")"
    ms_tmp_discard "$tmp"
    return 1
}

# =============================================================================
# MODULE: BLUETOOTH
# (paired devices)
# ⚠️ Requires administrator permissions both to save and to restore,
# because /var/lib/bluetooth/ can only be read by root.
# =============================================================================

save_bluetooth() {
    local dir="$1/bluetooth"
    mkdir -p "$dir"

    if ! command -v pkexec >/dev/null 2>&1; then
        log_msg "$(T "Aviso: pkexec no está disponible; no se puede guardar la configuración de Bluetooth (requiere acceso root).")"
        return 1
    fi

    log_msg "$(T "Guardando dispositivos Bluetooth emparejados (se pedirá contraseña de administrador)...")"
    if atomic_capture "$dir/bluetooth.tar.gz" prun bash -c 'tar czf - -C /var/lib bluetooth 2>/dev/null' 2>/dev/null; then
        chmod 600 "$dir/bluetooth.tar.gz"
        log_msg "$(T "Bluetooth guardado.")"
    else
        save_problem "$dir/bluetooth.tar.gz"
    fi
}

restore_bluetooth() {
    local dir="$1/bluetooth"
    if [ ! -f "$dir/bluetooth.tar.gz" ]; then
        log_msg "$(T "No hay datos de Bluetooth en esta configuración guardada.")"
        return 0
    fi

    if ! command -v pkexec >/dev/null 2>&1; then
        log_msg "$(T "Aviso: pkexec no está disponible; no se puede restaurar Bluetooth (requiere acceso root).")"
        return 1
    fi

    log_msg "$(T "Restaurando dispositivos Bluetooth emparejados, sin sobrescribir los existentes (se pedirá contraseña de administrador)...")"
    local tmp
    if ! tmp=$(mktemp -d); then
        log_msg "$(T "No se pudo crear una carpeta temporal. Comprueba que hay espacio libre en el disco.")"
        return 1
    fi
    ms_tmp_track "$tmp"
    if ! tar_archive_is_safe "$dir/bluetooth.tar.gz"; then
        log_msg "$(T "Aviso: el archivo de Bluetooth contiene rutas no seguras; no se pudo restaurar.")"
        ms_tmp_discard "$tmp"
        return 1
    fi
    if ! tar xzf "$dir/bluetooth.tar.gz" -C "$tmp" 2>/dev/null; then
        log_msg "$(T "Aviso: el archivo de Bluetooth guardado está dañado o incompleto; no se pudo restaurar.")"
        ms_tmp_discard "$tmp"
        return 1
    fi
    # Each new file is published from a temporary file in the same directory;
    # existing ones are still never overwritten.
    # shellcheck disable=SC2016
    if prun bash -c '
        # Byte-wise reading: in a UTF-8 locale a name that ends in an incomplete
        # multibyte sequence makes "read -d" drop the next entry.
        LC_ALL=C
        src_root="$1/bluetooth"
        dst_root=/var/lib/bluetooth
        mkdir -p -- "$dst_root" || exit 1
        [ -d "$src_root" ] || exit 0
        ec=0
        while IFS= read -r -d "" src; do
            rel="${src#"$src_root/"}"
            dst="$dst_root/$rel"
            if [ -e "$dst" ] || [ -L "$dst" ]; then
                continue
            fi
            parent=$(dirname -- "$dst")
            mkdir -p -- "$parent" || { ec=1; continue; }
            tmp_file=$(mktemp -- "$parent/.${dst##*/}.mstmp.XXXXXX") || { ec=1; continue; }
            if cp -- "$src" "$tmp_file" && chmod 600 -- "$tmp_file" && sync -- "$tmp_file"; then
                mv -T -- "$tmp_file" "$dst" || { rm -f -- "$tmp_file"; ec=1; }
            else
                rm -f -- "$tmp_file"
                ec=1
            fi
        done < <(find "$src_root" -type f -print0)
        systemctl restart bluetooth 2>/dev/null || true
        exit "$ec"
    ' _ "$tmp"; then
        log_msg "$(T "Bluetooth restaurado.")"
        ms_tmp_discard "$tmp"
        return 0
    fi
    log_msg "$(T "Aviso: no se pudo restaurar Bluetooth (permisos denegados, espacio insuficiente o cancelado).")"
    ms_tmp_discard "$tmp"
    return 1
}

# =============================================================================
# MODULE: KEYBOARD
# (keyboard layout(s), XKB options, repeat rate)
# =============================================================================

save_keyboard() {
    local dir="$1/keyboard"
    mkdir -p "$dir"

    log_msg "$(T "Guardando distribución(es) de teclado y opciones XKB...")"
    dconf_dump_atomic /org/gnome/desktop/input-sources/ "$dir/input-sources.dconf"

    log_msg "$(T "Guardando velocidad de repetición y retardo...")"
    dconf_dump_atomic /org/cinnamon/settings-daemon/peripherals/keyboard/ "$dir/keyboard.dconf"

    log_msg "$(T "Teclado guardado.")"
}

restore_keyboard() {
    local dir="$1/keyboard"
    if [ ! -d "$dir" ]; then
        log_msg "$(T "No hay datos de teclado en esta configuración guardada.")"
        return 0
    fi

    [ -f "$dir/input-sources.dconf" ] && { log_msg "$(T "Restaurando distribución(es) de teclado...")"; dconf_load_clean /org/gnome/desktop/input-sources/ "$dir/input-sources.dconf"; }
    [ -f "$dir/keyboard.dconf" ]      && { log_msg "$(T "Restaurando velocidad de repetición y retardo...")"; dconf_load_clean /org/cinnamon/settings-daemon/peripherals/keyboard/ "$dir/keyboard.dconf"; }

    if restore_clean_end; then log_msg "$(T "Teclado restaurado.")"; fi
}

# =============================================================================
# MODULE: MOUSE
# (speed, acceleration, inverted buttons, natural scrolling)
# =============================================================================

save_mouse() {
    local dir="$1/mouse"
    mkdir -p "$dir"
    log_msg "$(T "Guardando configuración del ratón...")"
    dconf_dump_atomic /org/cinnamon/settings-daemon/peripherals/mouse/ "$dir/mouse.dconf"
    log_msg "$(T "Ratón guardado.")"
}

restore_mouse() {
    local dir="$1/mouse"
    if [ ! -d "$dir" ]; then
        log_msg "$(T "No hay datos de ratón en esta configuración guardada.")"
        return 0
    fi
    [ -f "$dir/mouse.dconf" ] && { log_msg "$(T "Restaurando configuración del ratón...")"; dconf_load_clean /org/cinnamon/settings-daemon/peripherals/mouse/ "$dir/mouse.dconf"; }
    if restore_clean_end; then log_msg "$(T "Ratón restaurado.")"; fi
}

# =============================================================================
# MODULE: TOUCHPAD
# (tap to click, two-finger scroll, disable while typing, gestures)
# =============================================================================

save_touchpad() {
    local dir="$1/touchpad"
    mkdir -p "$dir"
    log_msg "$(T "Guardando configuración del touchpad...")"
    dconf_dump_atomic /org/cinnamon/settings-daemon/peripherals/touchpad/ "$dir/touchpad.dconf"
    log_msg "$(T "Touchpad guardado.")"
}

restore_touchpad() {
    local dir="$1/touchpad"
    if [ ! -d "$dir" ]; then
        log_msg "$(T "No hay datos de touchpad en esta configuración guardada.")"
        return 0
    fi
    [ -f "$dir/touchpad.dconf" ] && { log_msg "$(T "Restaurando configuración del touchpad...")"; dconf_load_clean /org/cinnamon/settings-daemon/peripherals/touchpad/ "$dir/touchpad.dconf"; }
    if restore_clean_end; then log_msg "$(T "Touchpad restaurado.")"; fi
}

# =============================================================================
# MODULE: FIREFOX
# (full profile: bookmarks, history, extensions and preferences)
# Covers the native installation via apt, which is the one Linux Mint ships
# by default. The Flatpak version stores the profile in another path
# (~/.var/app/org.mozilla.firefox/...) and is not detected automatically.
# The profiles come from ~/.mozilla/firefox or, on a Firefox 147+ installed
# without ~/.mozilla, from ~/.config/mozilla/firefox (firefox_profiles_root).
# Either way the copy stores them as "firefox/" and Restore puts them in
# ~/.mozilla/firefox, which Firefox 147+ keeps using when ~/.mozilla exists.
# =============================================================================

save_firefox() {
    local dir="$1/firefox" root src
    mkdir -p "$dir"

    if ! src=$(firefox_profiles_root); then
        log_msg "$(T "Firefox no está instalado o no tiene perfiles en este equipo.")"
        return 0
    fi

    if is_running firefox || is_running firefox-esr; then
        log_msg "$(T "Aviso: Firefox está abierto. Ciérralo y vuelve a guardar para evitar una copia inconsistente del perfil.")"
    fi

    log_msg "$(T "Guardando perfil(es) de Firefox (marcadores, extensiones, preferencias)...")"
    root=$(tar_root_member "$src")
    mozilla_excludes "$root"
    atomic_tar "$dir/firefox-profiles.tar.gz" -C "$(dirname "$src")" \
        "${MOZILLA_EXCLUDES[@]}" "$root" || save_problem "$src"

    log_msg "$(T "Firefox guardado.")"
}

restore_firefox() {
    local dir="$1/firefox"
    if [ ! -f "$dir/firefox-profiles.tar.gz" ]; then
        log_msg "$(T "No hay datos de Firefox en esta configuración guardada.")"
        return 0
    fi

    if is_running firefox || is_running firefox-esr; then
        log_msg "$(T "Aviso: Firefox está abierto; ciérralo y vuelve a restaurar para evitar corromper el perfil. Este módulo se ha omitido.")"
        return 1
    fi

    log_msg "$(T "Restaurando perfil(es) de Firefox (marcadores, extensiones, preferencias)...")"
    mkdir -p "$HOME/.mozilla"
    safe_extract "$dir/firefox-profiles.tar.gz" "$HOME/.mozilla" || restore_problem "$dir/firefox-profiles.tar.gz"

    if restore_clean_end; then log_msg "$(T "Firefox restaurado. Ábrelo para comprobar que carga el perfil correctamente.")"; fi
}

# =============================================================================
# MODULE: LIBREWOLF
# (full profile: bookmarks, history, extensions and preferences)
# Covers the native installation via apt. The Flatpak version stores the
# profile in another path and is not detected automatically.
# =============================================================================

save_librewolf() {
    local dir="$1/librewolf" root
    mkdir -p "$dir"

    if [ ! -d "$HOME/.librewolf" ]; then
        log_msg "$(T "LibreWolf no está instalado o no tiene perfiles en este equipo.")"
        return 0
    fi

    if is_running librewolf; then
        log_msg "$(T "Aviso: LibreWolf está abierto. Ciérralo y vuelve a guardar para evitar una copia inconsistente del perfil.")"
    fi

    log_msg "$(T "Guardando perfil(es) de LibreWolf (marcadores, extensiones, preferencias)...")"
    root=$(tar_root_member "$HOME/.librewolf")
    mozilla_excludes "$root"
    atomic_tar "$dir/librewolf-profiles.tar.gz" -C "$HOME" \
        "${MOZILLA_EXCLUDES[@]}" "$root" || save_problem "$HOME/.librewolf"

    log_msg "$(T "LibreWolf guardado.")"
}

restore_librewolf() {
    local dir="$1/librewolf"
    if [ ! -f "$dir/librewolf-profiles.tar.gz" ]; then
        log_msg "$(T "No hay datos de LibreWolf en esta configuración guardada.")"
        return 0
    fi

    if is_running librewolf; then
        log_msg "$(T "Aviso: LibreWolf está abierto; ciérralo y vuelve a restaurar para evitar corromper el perfil. Este módulo se ha omitido.")"
        return 1
    fi

    log_msg "$(T "Restaurando perfil(es) de LibreWolf (marcadores, extensiones, preferencias)...")"
    safe_extract "$dir/librewolf-profiles.tar.gz" "$HOME" || restore_problem "$dir/librewolf-profiles.tar.gz"

    if restore_clean_end; then log_msg "$(T "LibreWolf restaurado. Ábrelo para comprobar que carga el perfil correctamente.")"; fi
}

# =============================================================================
# MODULE: THUNDERBIRD
# (accounts, mail filters, address book, extensions)
# Covers the native installation via apt. The Flatpak version stores the
# profile in another path and is not detected automatically.
# =============================================================================

save_thunderbird() {
    local dir="$1/thunderbird" root
    mkdir -p "$dir"

    if [ ! -d "$HOME/.thunderbird" ]; then
        log_msg "$(T "Thunderbird no está instalado o no tiene perfiles en este equipo.")"
        return 0
    fi

    if is_running thunderbird; then
        log_msg "$(T "Aviso: Thunderbird está abierto. Ciérralo y vuelve a guardar para evitar una copia inconsistente del perfil.")"
    fi

    log_msg "$(T "Guardando perfil(es) de Thunderbird (cuentas, filtros, libreta de direcciones, extensiones)...")"
    root=$(tar_root_member "$HOME/.thunderbird")
    mozilla_excludes "$root"
    atomic_tar "$dir/thunderbird-profiles.tar.gz" -C "$HOME" \
        "${MOZILLA_EXCLUDES[@]}" "$root" || save_problem "$HOME/.thunderbird"

    log_msg "$(T "Thunderbird guardado.")"
    log_msg "$(T "Nota: si alguna cuenta usa POP3 sin 'dejar copia en el servidor', el correo local guardado aquí puede ser la única copia que existe; con IMAP el correo vive en el servidor y esto es solo una caché.")"
}

restore_thunderbird() {
    local dir="$1/thunderbird"
    if [ ! -f "$dir/thunderbird-profiles.tar.gz" ]; then
        log_msg "$(T "No hay datos de Thunderbird en esta configuración guardada.")"
        return 0
    fi

    if is_running thunderbird; then
        log_msg "$(T "Aviso: Thunderbird está abierto; ciérralo y vuelve a restaurar para evitar corromper el perfil. Este módulo se ha omitido.")"
        return 1
    fi

    log_msg "$(T "Restaurando perfil(es) de Thunderbird (cuentas, filtros, libreta de direcciones, extensiones)...")"
    safe_extract "$dir/thunderbird-profiles.tar.gz" "$HOME" || restore_problem "$dir/thunderbird-profiles.tar.gz"

    if restore_clean_end; then log_msg "$(T "Thunderbird restaurado. Ábrelo para comprobar que carga el perfil correctamente.")"; fi
}

# =============================================================================
# MODULE: LIBREOFFICE
# (templates, autocorrect, installed extensions, custom toolbars
# and shortcuts, recent documents)
# =============================================================================

save_libreoffice() {
    local dir="$1/libreoffice"
    mkdir -p "$dir"

    if [ ! -d "$HOME/.config/libreoffice" ]; then
        log_msg "$(T "LibreOffice no tiene configuración de usuario en este equipo.")"
        return 0
    fi

    if is_running soffice.bin; then
        log_msg "$(T "Aviso: LibreOffice está abierto (o el inicio rápido activo). Ciérralo del todo y vuelve a guardar para evitar una copia inconsistente.")"
    fi

    log_msg "$(T "Guardando configuración de usuario de LibreOffice...")"
    pack_dir "$HOME/.config/libreoffice" "$dir/libreoffice-config.tar.gz"

    log_msg "$(T "LibreOffice guardado.")"
}

restore_libreoffice() {
    local dir="$1/libreoffice"
    if [ ! -f "$dir/libreoffice-config.tar.gz" ]; then
        log_msg "$(T "No hay datos de LibreOffice en esta configuración guardada.")"
        return 0
    fi

    if is_running soffice.bin; then
        log_msg "$(T "Aviso: LibreOffice está abierto (o el inicio rápido activo); ciérralo del todo y vuelve a restaurar. Este módulo se ha omitido.")"
        return 1
    fi

    log_msg "$(T "Restaurando configuración de usuario de LibreOffice...")"
    unpack_dir "$dir/libreoffice-config.tar.gz" "$HOME/.config"

    if restore_clean_end; then log_msg "$(T "LibreOffice restaurado.")"; fi
}

# =============================================================================
# MODULE: ONLYOFFICE
# (user settings and plugins of ONLYOFFICE Desktop Editors)
# =============================================================================

save_onlyoffice() {
    local dir="$1/onlyoffice"
    mkdir -p "$dir"

    if [ ! -d "$HOME/.config/onlyoffice" ]; then
        log_msg "$(T "ONLYOFFICE no tiene configuración de usuario en este equipo.")"
        return 0
    fi

    if is_running DesktopEditors; then
        log_msg "$(T "Aviso: ONLYOFFICE Desktop Editors está abierto. Ciérralo y vuelve a guardar para evitar una copia inconsistente.")"
    fi

    log_msg "$(T "Guardando configuración de usuario de ONLYOFFICE...")"
    pack_dir "$HOME/.config/onlyoffice" "$dir/onlyoffice-config.tar.gz"

    # The plugins the user installs by hand (Zotero, Thesaurus, own macros...)
    # do not live in ~/.config/onlyoffice but here; without this they were
    # lost when restoring on a new machine.
    if [ -d "$HOME/.local/share/onlyoffice" ]; then
        log_msg "$(T "Guardando plugins de ONLYOFFICE instalados por el usuario...")"
        pack_dir "$HOME/.local/share/onlyoffice" "$dir/onlyoffice-plugins.tar.gz"
    fi

    log_msg "$(T "ONLYOFFICE guardado.")"
}

restore_onlyoffice() {
    local dir="$1/onlyoffice"
    if [ ! -f "$dir/onlyoffice-config.tar.gz" ]; then
        log_msg "$(T "No hay datos de ONLYOFFICE en esta configuración guardada.")"
        return 0
    fi

    if is_running DesktopEditors; then
        log_msg "$(T "Aviso: ONLYOFFICE Desktop Editors está abierto; ciérralo y vuelve a restaurar. Este módulo se ha omitido.")"
        return 1
    fi

    log_msg "$(T "Restaurando configuración de usuario de ONLYOFFICE...")"
    unpack_dir "$dir/onlyoffice-config.tar.gz" "$HOME/.config"

    [ -f "$dir/onlyoffice-plugins.tar.gz" ] && { log_msg "$(T "Restaurando plugins de ONLYOFFICE...")"; unpack_dir "$dir/onlyoffice-plugins.tar.gz" "$HOME/.local/share"; }

    if restore_clean_end; then log_msg "$(T "ONLYOFFICE restaurado.")"; fi
}

# =============================================================================
# MODULE: VS CODE
# (extensions, settings.json, keybindings.json, snippets, named profiles;
# detects whether what is installed is the stable edition or Insiders)
# The extension list is reinstalled from the marketplace with
# "code --install-extension" instead of copying the whole
# ~/.vscode/extensions folder: it weighs far less and avoids carrying native
# binaries compiled for a VS Code version or an architecture different from
# the one of the machine where it is restored.
# =============================================================================

save_vscode() {
    local dir="$1/vscode"
    mkdir -p "$dir"

    # code_user_dir depends on which variant is installed: the VS Code
    # Insiders configuration folder ("Code - Insiders") differs from that of
    # stable VS Code ("Code"). If only Insiders is present, always using the
    # stable path silently left settings.json/keybindings/snippets unsaved
    # (the extension list was saved correctly, because that part already
    # used "$code_bin" properly).
    local code_bin="" code_user_dir=""
    if command -v code >/dev/null 2>&1; then
        code_bin="code"; code_user_dir="$HOME/.config/Code/User"
    elif command -v code-insiders >/dev/null 2>&1; then
        code_bin="code-insiders"; code_user_dir="$HOME/.config/Code - Insiders/User"
    elif [ -d "$HOME/.config/Code/User" ]; then
        code_user_dir="$HOME/.config/Code/User"
    elif [ -d "$HOME/.config/Code - Insiders/User" ]; then
        code_user_dir="$HOME/.config/Code - Insiders/User"
    fi

    if [ -z "$code_bin" ] && [ -z "$code_user_dir" ]; then
        log_msg "$(T "VS Code no está instalado en este equipo.")"
        return 0
    fi

    if [ -n "$code_bin" ]; then
        log_msg "$(T "Guardando lista de extensiones instaladas...")"
        atomic_capture "$dir/extensions.list" "$code_bin" --list-extensions 2>/dev/null || save_problem "$dir/extensions.list"
        printf '%s\n' "$code_bin" | atomic_write "$dir/variant" || save_problem "$dir/variant"
    else
        log_msg "$(T "Aviso: no se encontró el comando 'code' en el PATH; no se puede guardar la lista de extensiones (sí se guardarán settings.json y demás).")"
    fi

    if [ -n "$code_user_dir" ] && [ -d "$code_user_dir" ]; then
        log_msg "$(T "Guardando settings.json, keybindings.json y snippets...")"
        mkdir -p "$dir/User"
        save_copy "$code_user_dir/settings.json" "$dir/User/settings.json"
        save_copy "$code_user_dir/keybindings.json" "$dir/User/keybindings.json"
        pack_dir "$code_user_dir/snippets" "$dir/snippets.tar.gz"

        # If the user uses VS Code's "Profiles" feature (several named
        # settings.json/keybindings.json files, for different work
        # contexts), each one lives in its own subfolder inside
        # User/profiles/. Without this, restoring only recovered the
        # "Default" profile.
        if [ -d "$code_user_dir/profiles" ]; then
            log_msg "$(T "Guardando perfiles con nombre de VS Code...")"
            pack_dir "$code_user_dir/profiles" "$dir/profiles.tar.gz"
        fi
    fi

    log_msg "$(T "VS Code guardado.")"
}

restore_vscode() {
    local dir="$1/vscode" module_failed=0
    if [ ! -d "$dir" ]; then
        log_msg "$(T "No hay datos de VS Code en esta configuración guardada.")"
        return 0
    fi

    # We prefer the variant actually installed on THIS machine; if there is
    # none in the PATH (e.g. restoring before installing VS Code), we fall
    # back to the variant it was saved with ("variant"), and as a last
    # resort to the stable edition's folder.
    local code_bin="" code_user_dir=""
    if command -v code >/dev/null 2>&1; then
        code_bin="code"; code_user_dir="$HOME/.config/Code/User"
    elif command -v code-insiders >/dev/null 2>&1; then
        code_bin="code-insiders"; code_user_dir="$HOME/.config/Code - Insiders/User"
    elif [ -f "$dir/variant" ] && [ "$(cat "$dir/variant" 2>/dev/null)" = "code-insiders" ]; then
        code_user_dir="$HOME/.config/Code - Insiders/User"
    else
        code_user_dir="$HOME/.config/Code/User"
    fi

    if [ -f "$dir/extensions.list" ] && [ -s "$dir/extensions.list" ]; then
        if [ -n "$code_bin" ]; then
            log_msg "$(T "Instalando extensiones de VS Code...")"
            # All in a single "code" invocation (it accepts a repeated
            # --install-extension): each process start costs several seconds,
            # and that cost used to be paid once PER EXTENSION. The output is
            # no longer silenced, so the result of each extension shows up
            # in the restore details.
            local ext; local -a ext_args=()
            while IFS= read -r ext; do
                [ -n "$ext" ] && ext_args+=(--install-extension "$ext")
            done < "$dir/extensions.list"
            if [ ${#ext_args[@]} -gt 0 ]; then
                "$code_bin" "${ext_args[@]}" --force || {
                    module_failed=1
                    log_msg "$(T "Aviso: alguna extensión no se pudo instalar (revisa el detalle anterior); puede haberse retirado del marketplace o cambiado de identificador.")"
                }
            fi
        else
            module_failed=1
            log_msg "$(T "Aviso: VS Code no está instalado (o 'code' no está en el PATH); instala VS Code y vuelve a restaurar este módulo para recuperar las extensiones.")"
        fi
    fi

    if [ -d "$dir/User" ]; then
        log_msg "$(T "Restaurando settings.json y keybindings.json...")"
        mkdir -p "$code_user_dir"
        [ -f "$dir/User/settings.json" ]    && atomic_copy_keep_bak "$dir/User/settings.json" "$code_user_dir/settings.json"
        [ -f "$dir/User/keybindings.json" ] && atomic_copy_keep_bak "$dir/User/keybindings.json" "$code_user_dir/keybindings.json"
    fi

    [ -f "$dir/snippets.tar.gz" ] && { log_msg "$(T "Restaurando snippets...")"; unpack_dir "$dir/snippets.tar.gz" "$code_user_dir"; }
    [ -f "$dir/profiles.tar.gz" ] && { log_msg "$(T "Restaurando perfiles con nombre de VS Code...")"; unpack_dir "$dir/profiles.tar.gz" "$code_user_dir"; }

    # A failure flagged by atomic_copy_keep_bak or unpack_dir leaves the module partial too.
    [ "${RESTORE_MODULE_FAILED:-0}" -eq 0 ] || module_failed=1

    if [ "$module_failed" -eq 0 ]; then
        log_msg "$(T "VS Code restaurado. Si estaba abierto, reinícialo para que cargue los cambios.")"
        return 0
    fi
    log_msg "$(T "Aviso: VS Code se restauró parcialmente; revisa los avisos anteriores.")"
    return 1
}

# =============================================================================
# MODULE: DOCKER
# (user config ~/.docker, /etc/docker/daemon.json, docker group)
# ⚠️ Only the daemon part and the docker group require administrator
# permissions (via pkexec); the user configuration does not.
# =============================================================================

# True if user "$1" is in group "$2". Whole names are compared: "grep -w" would
# take "docker-users" for "docker" (a hyphen splits words).
user_in_group() {
    id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qxF -- "$2"
}

save_docker() {
    local dir="$1/docker" current_user module_failed=0
    mkdir -p "$dir"

    if ! command -v docker >/dev/null 2>&1; then
        log_msg "$(T "Docker no está instalado en este equipo.")"
        return 0
    fi

    if [ -f /etc/docker/daemon.json ]; then
        log_msg "$(T "Guardando configuración del daemon de Docker...")"
        if ! save_copy /etc/docker/daemon.json "$dir/daemon.json"; then
            if command -v pkexec >/dev/null 2>&1; then
                atomic_capture "$dir/daemon.json" prun cat /etc/docker/daemon.json 2>/dev/null || save_problem /etc/docker/daemon.json
            else
                module_failed=1
                log_msg "$(T "Aviso: no se pudo leer /etc/docker/daemon.json (sin permisos de lectura y pkexec no disponible).")"
            fi
        fi
    fi

    if [ -d "$HOME/.docker" ]; then
        log_msg "$(T "Guardando configuración de Docker CLI del usuario (contexts, config.json)...")"
        pack_dir "$HOME/.docker" "$dir/user-docker.tar.gz"
    fi

    current_user=$(id -un)
    if getent group docker >/dev/null 2>&1 && user_in_group "$current_user" docker; then
        printf '%s\n' true | atomic_write "$dir/user-in-docker-group" || save_problem "$dir/user-in-docker-group"
    fi

    if [ "$module_failed" -eq 0 ]; then
        log_msg "$(T "Docker guardado.")"
        log_msg "$(T "Nota: si tu ~/.docker/config.json guarda credenciales de registros sin un 'credential helper' (campo \"auths\" con contraseñas en base64 en vez de \"credsStore\"), esta copia contendrá esas credenciales. Protege bien la carpeta de copia de seguridad.")"
        return 0
    fi
    log_msg "$(T "Aviso: Docker no se pudo guardar íntegramente; revisa los avisos anteriores.")"
    return 1
}

restore_docker() {
    local dir="$1/docker" current_user module_failed=0 daemon_rc=0
    if [ ! -d "$dir" ]; then
        log_msg "$(T "No hay datos de Docker en esta configuración guardada.")"
        return 0
    fi

    if ! command -v docker >/dev/null 2>&1; then
        log_msg "$(T "Aviso: Docker no está instalado en este equipo; instálalo y vuelve a restaurar este módulo.")"
    fi

    if [ -f "$dir/daemon.json" ]; then
        log_msg "$(T "Restaurando configuración del daemon de Docker (se pedirá contraseña de administrador)...")"
        if command -v pkexec >/dev/null 2>&1; then
            # The daemon is published from a temporary file in the same
            # directory; that way a failure cannot leave a truncated JSON.
            # shellcheck disable=SC2016
            prun bash -c '
                src="$1/daemon.json"
                dst=/etc/docker/daemon.json
                parent=/etc/docker
                # Exit 3: a link in the copy would make root read whatever it
                # points to.
                if [ ! -f "$src" ] || [ -L "$src" ]; then exit 3; fi
                mkdir -p -- "$parent" || exit 1
                tmp_file=$(mktemp -- "$parent/.daemon.json.mstmp.XXXXXX") || exit 1
                cleanup() { rm -f -- "$tmp_file"; }
                trap cleanup EXIT INT TERM HUP
                if cp -- "$src" "$tmp_file" \
                    && if [ -e "$dst" ]; then chmod --reference="$dst" -- "$tmp_file"; else chmod 600 -- "$tmp_file"; fi \
                    && sync -- "$tmp_file" \
                    && mv -T -- "$tmp_file" "$dst"; then
                    # Exit 2: published, but Docker did not restart. Status 5
                    # is "no docker.service" (Docker not installed): nothing
                    # to restart.
                    out=$(systemctl restart docker 2>&1); rc=$?
                    case "$rc" in 0|5) exit 0 ;; esac
                    printf "%s\n" "$out" >&2
                    exit 2
                fi
                exit 1
            ' _ "$dir" || daemon_rc=$?
            case "$daemon_rc" in
                0) ;;
                2)
                    module_failed=1
                    log_msg "$(T "Aviso: /etc/docker/daemon.json se restauró, pero Docker no se pudo reiniciar; revisa «systemctl status docker».")"
                    ;;
                3)
                    module_failed=1
                    log_msg "$(T "Aviso: «daemon.json» de la copia no es un archivo normal (por ejemplo, un enlace simbólico); no se restaura.")"
                    ;;
                *)
                    module_failed=1
                    log_msg "$(T "Aviso: no se pudo restaurar /etc/docker/daemon.json (permisos denegados o cancelado).")"
                    ;;
            esac
        else
            module_failed=1
            log_msg "$(T_FMT 'Aviso: pkexec no está disponible; copia manualmente %s/daemon.json a /etc/docker/daemon.json.' "$dir")"
        fi
    fi

    if [ -f "$dir/user-docker.tar.gz" ]; then
        log_msg "$(T "Restaurando configuración de Docker CLI del usuario...")"
        unpack_dir "$dir/user-docker.tar.gz" "$HOME" || module_failed=1
    fi

    if [ -f "$dir/user-in-docker-group" ]; then
        current_user=$(id -un)
        if getent group docker >/dev/null 2>&1; then
            if user_in_group "$current_user" docker; then
                log_msg "$(T "Tu usuario ya pertenece al grupo docker.")"
            elif command -v pkexec >/dev/null 2>&1; then
                log_msg "$(T "Añadiendo tu usuario al grupo docker (se pedirá contraseña de administrador)...")"
                if prun usermod -aG docker "$current_user"; then
                    log_msg "$(T "Hecho. Cierra sesión y vuelve a entrar para que el cambio de grupo surta efecto.")"
                else
                    module_failed=1
                    log_msg "$(T "Aviso: no se pudo añadir tu usuario al grupo docker (permisos denegados o cancelado).")"
                fi
            else
                module_failed=1
                log_msg "$(T "Aviso: pkexec no está disponible; añádete al grupo manualmente con: sudo usermod -aG docker \$USER")"
            fi
        else
            module_failed=1
            log_msg "$(T "Aviso: el grupo 'docker' no existe todavía en este equipo; instala el paquete docker.io/docker-ce antes de añadir el usuario al grupo.")"
        fi
    fi

    if [ "$module_failed" -eq 0 ]; then
        log_msg "$(T "Docker restaurado.")"
        return 0
    fi
    log_msg "$(T "Aviso: Docker se restauró parcialmente; revisa los avisos anteriores.")"
    return 1
}

# =============================================================================
# MODULE: TERMINAL
# (GNOME Terminal profiles, .bashrc/.zshrc and other shell files)
# =============================================================================

TERMINAL_SHELL_FILES=(.bashrc .bash_aliases .bash_profile .bash_logout .profile .zshrc .zprofile .tmux.conf .inputrc .dircolors)

save_terminal() {
    local dir="$1/terminal" f
    mkdir -p "$dir"

    log_msg "$(T "Guardando perfiles de GNOME Terminal (colores, fuente, atajos)...")"
    dconf_dump_atomic /org/gnome/terminal/legacy/ "$dir/gnome-terminal.dconf"

    log_msg "$(T "Guardando archivos de configuración de la shell...")"
    for f in "${TERMINAL_SHELL_FILES[@]}"; do
        save_copy "$HOME/$f" "$dir/$f"
    done

    if [ -f "$HOME/.config/starship.toml" ]; then
        log_msg "$(T "Guardando configuración de Starship...")"
        mkdir -p "$dir/config"
        save_copy "$HOME/.config/starship.toml" "$dir/config/starship.toml"
    fi
    save_copy "$HOME/.p10k.zsh" "$dir/.p10k.zsh"

    log_msg "$(T "Terminal guardada.")"
}

restore_terminal() {
    local dir="$1/terminal" f
    if [ ! -d "$dir" ]; then
        log_msg "$(T "No hay datos de terminal en esta configuración guardada.")"
        return 0
    fi

    [ -f "$dir/gnome-terminal.dconf" ] && { log_msg "$(T "Restaurando perfiles de GNOME Terminal (colores, fuente, atajos)...")"; dconf_load_clean /org/gnome/terminal/legacy/ "$dir/gnome-terminal.dconf"; }

    log_msg "$(T "Restaurando archivos de configuración de la shell...")"
    for f in "${TERMINAL_SHELL_FILES[@]}"; do
        [ -f "$dir/$f" ] && atomic_copy_keep_bak "$dir/$f" "$HOME/$f"
    done

    if [ -f "$dir/config/starship.toml" ]; then
        log_msg "$(T "Restaurando configuración de Starship...")"
        mkdir -p "$HOME/.config"
        atomic_copy_keep_bak "$dir/config/starship.toml" "$HOME/.config/starship.toml"
    fi
    [ -f "$dir/.p10k.zsh" ] && atomic_copy_keep_bak "$dir/.p10k.zsh" "$HOME/.p10k.zsh"

    if restore_clean_end; then log_msg "$(T "Terminal restaurada. Abre una nueva pestaña o ventana para ver los cambios.")"; fi
}

# =============================================================================
# GRAPHICAL INTERFACE: SAVE CONFIGURATION
# =============================================================================

do_save() {
    local selection name timestamp safe_name backup_dir log modules total step mod key
    local root_keys_save
    local checklist_args=()

    for key in "${MODULE_KEYS[@]}"; do
        checklist_args+=(TRUE "$(T "${MODULE_SHORT_LABELS[$key]:-$key}")" "$(T "${MODULE_LABELS[$key]:-$key}")" "$key")
    done

    selection=$(LANGUAGE="$APP_LANG" zenity --list --title="$(T "$APP_NAME - Guardar")" \
        --text="$(T "¿Qué deseas guardar?")" \
        --checklist --width=700 --height=500 \
        --column="$(T "Sel")" --column="$(T "Módulo")" --column="$(T "Descripción")" --column="Key" \
        --hide-column=4 --print-column=4 --separator="," \
        "${checklist_args[@]}" \
        2>/dev/null)
    [ -z "$selection" ] && return 0

    IFS=',' read -ra modules <<< "$selection"

    # Network and Bluetooth always ask for the administrator password. Docker
    # only needs it as a fallback if /etc/docker/daemon.json is not readable
    # without privileges (unusual: by default it is), so it is only added to
    # the list when it is really needed, to avoid asking for it needlessly.
    # It is computed here to reuse it both in the credentials warning below
    # and in the later preauth.
    root_keys_save="network bluetooth"
    [ -f /etc/docker/daemon.json ] && [ ! -r /etc/docker/daemon.json ] && root_keys_save+=" docker"

    # A single security warning, instead of one window per module, listing
    # only the modules with credentials that are actually selected.
    local cred_warn=""
    printf '%s\n' "${modules[@]}" | grep -qx 'network'     && cred_warn+=$'\n'"$(T '• Red — contraseñas Wi-Fi en texto plano')"
    printf '%s\n' "${modules[@]}" | grep -qx 'bluetooth'   && cred_warn+=$'\n'"$(T '• Bluetooth — claves de emparejamiento de tus dispositivos')"
    printf '%s\n' "${modules[@]}" | grep -qx 'docker'      && cred_warn+=$'\n'"$(T '• Docker — posibles credenciales de registro en base64')"
    printf '%s\n' "${modules[@]}" | grep -qx 'thunderbird' && cred_warn+=$'\n'"$(T '• Thunderbird — contraseñas de tus cuentas de correo')"
    printf '%s\n' "${modules[@]}" | grep -qx 'firefox'     && cred_warn+=$'\n'"$(T '• Firefox — contraseñas guardadas en el navegador')"
    printf '%s\n' "${modules[@]}" | grep -qx 'librewolf'   && cred_warn+=$'\n'"$(T '• LibreWolf — contraseñas guardadas en el navegador')"
    if [ -n "$cred_warn" ]; then
        local pw_note=""
        modules_need_root "$root_keys_save" "${modules[@]}" && pw_note=$'\n\n'"$(T 'Se te pedirá la contraseña de administrador varias veces, una por cada operación que la necesite.')"
        msg_warn "$(T '⚠️ Esta copia incluirá datos sensibles:')${cred_warn}"$'\n\n'"$(T 'Las contraseñas de navegador/correo solo van cifradas si usas una contraseña principal.') $(T 'Protege bien ~/MintSetupBackups.')${pw_note}"
    fi

    name=$(LANGUAGE="$APP_LANG" zenity --entry --title="$(T "$APP_NAME - Guardar")" \
        --text="$(T "Nombre para esta configuración:")" \
        --entry-text="$(hostname)" --width=380 2>/dev/null)
    [ -z "$name" ] && return 0

    timestamp=$(date '+%Y%m%d-%H%M%S')
    # We transliterate accented letters/ñ to ASCII (e.g. "Configuración" ->
    # "Configuracion") before sanitizing with tr, which works byte by byte and
    # would chop multibyte UTF-8 characters, leaving extra underscores. We
    # force LC_ALL=C.UTF-8 (a locale compiled into glibc, always available)
    # because iconv's transliteration depends on the active locale's tables:
    # with a bare POSIX/C locale it replaces each accented letter with "?"
    # instead of the unaccented letter. If iconv is not available, we fall
    # back to the previous simple sanitizing.
    safe_name=""
    command -v iconv >/dev/null 2>&1 && safe_name=$(printf '%s' "$name" | LC_ALL=C.UTF-8 iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null | tr -c '[:alnum:]_-' '_')
    [ -z "$safe_name" ] && safe_name=$(printf '%s' "$name" | tr -c '[:alnum:]_-' '_')
    backup_dir="$BACKUPS_ROOT/${safe_name}_${timestamp}"
    if [ -e "$backup_dir" ]; then
        msg_error "$(T "Ya existe una copia con ese nombre y fecha. Espera un segundo y vuelve a intentarlo.")"
        return 1
    fi

    local stage_dir save_rc=0 report_dir="" failed_mods="" failed_list="" failed_files="" nfiles=0 f
    local SAVE_PROBLEMS_FILE=""
    ms_mktemp stage_dir "$backup_dir" d || {
        msg_error "$(T "No se pudo crear una carpeta temporal. Comprueba que hay espacio libre en el disco.")"
        return 1
    }
    log="$stage_dir/save.log"; : > "$log"
    # What failed is written outside the staged copy (it must not be published with it) and read
    # back below: save.log is discarded with the copy, so the error dialog is the only place left
    # to say which module or file was the problem. Without a folder it falls back to the plain error.
    if report_dir=$(mktemp -d 2>/dev/null); then
        ms_tmp_track "$report_dir"
        SAVE_PROBLEMS_FILE="$report_dir/files"
    else
        report_dir=""
    fi

    total=${#modules[@]}

    # Asked here, BEFORE opening the progress bar, so that the first
    # PolicyKit dialog is not hidden behind it (see root_preauth and
    # root_keys_save above). Each privileged module then asks on its own.
    root_preauth "$root_keys_save" "${modules[@]}" \
        || msg_warn "$(T_FMT "No se ha concedido la contraseña de administrador.\n\nAlgún módulo puede fallar o volver a pedirla más adelante; el resto se guardará igualmente.")"

    (
        step=0
        module_rc=0
        for mod in "${modules[@]}"; do
            # The percentage is the share of modules ALREADY saved. Sending
            # that of the module about to start reached 100 before the last
            # one ran: --auto-close then closed the window and the pipe while
            # it was still saving, and the next write failed with "printf:
            # write error: Broken pipe". Writes ignore errors: if the window
            # goes away the save must still finish.
            # The module is named by its label, as in Restore, not by its key.
            log_msg "$(T_FMT '# Guardando: %s' "$(T "${MODULE_SHORT_LABELS[$mod]:-$mod}")")" 2>/dev/null
            echo "$(( step * 100 / total ))" 2>/dev/null
            if ! run_save_module "$mod" "$stage_dir" >> "$log" 2>&1; then
                module_rc=1
                [ -z "$report_dir" ] || printf '%s\n' "$mod" >> "$report_dir/modules" 2>/dev/null
            fi
            step=$((step + 1))
            # If the module did not end up saving any file (e.g. Network or
            # Bluetooth without pkexec, or Startup Applications without an
            # autostart folder), its folder stays empty. rmdir only removes it
            # if truly empty; otherwise it fails silently and nothing happens.
            # That way Restore never offers a module without data.
            rmdir "$stage_dir/$mod" 2>/dev/null || true
        done
        echo 100 2>/dev/null
        exit "$module_rc"
    # --no-cancel: unlike Restore, there is no mechanism here that checks for
    # a cancellation halfway through a module, so zenity's default Cancel
    # button would not really stop anything (the save would carry on to the
    # end in the background); it is removed so as not to promise something
    # the dialog cannot deliver.
    ) | LANGUAGE="$APP_LANG" zenity --progress --title="$APP_NAME" --text="$(T "Guardando configuración...")" --auto-close --no-cancel --width=420 2>/dev/null
    save_rc=$?
    if [ "$save_rc" -ne 0 ]; then
        if [ -n "$report_dir" ]; then
            while IFS= read -r mod; do
                [ -n "$mod" ] && failed_list+="${failed_list:+, }$(T "${MODULE_SHORT_LABELS[$mod]:-$mod}")"
            done 2>/dev/null < "$report_dir/modules"
            [ -z "$failed_list" ] || failed_mods="$(T_FMT '\n\nMódulos que fallaron: %s' "$failed_list")"
            # At most five files are listed; the staging folder is not part of what the user knows.
            while IFS= read -r f; do
                [ -n "$f" ] || continue
                nfiles=$((nfiles + 1))
                [ "$nfiles" -le 5 ] || continue
                failed_files+=$'\n'"  • ${f#"$stage_dir"/}"
            done 2>/dev/null < "$report_dir/files"
            [ "$nfiles" -le 5 ] || failed_files+=$'\n'"$(T_FMT '  … y %s más' "$((nfiles - 5))")"
            [ -z "$failed_files" ] || failed_files="$(T_FMT '\n\nNo se pudo guardar de forma íntegra:%s' "$failed_files")"
        fi
        ms_tmp_discard "$stage_dir" "$report_dir"
        msg_error "$(T "No se pudo completar la copia. Ninguna configuración incompleta se ha publicado en la carpeta de copias.")${failed_mods}${failed_files}"
        return 1
    fi
    ms_tmp_discard "$report_dir"

    # We use printf %q (instead of wrapping the value in double quotes by
    # hand) so that the name the user typed is correctly escaped for bash.
    # manifest.conf is read again with a safe data parser every time
    # Restore/Compare/Delete is opened (see pick_backup_dir), so
    # if the name contains quotes, "$(...)", backticks, etc. and is not
    # escaped properly, that text would be reinterpreted as code when
    # sourced instead of being treated as text. %q prevents this whatever
    # happens.
    if ! {
        printf 'NAME=%q\n' "$name"
        printf 'DATE=%q\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'MINT_RELEASE=%q\n' "${PLATFORM_NAME:-desconocida}"
        printf 'OS_ID=%q\n' "$PLATFORM_OS_ID"
        printf 'PKG_MANAGER=%q\n' "$PLATFORM_PKG"
        printf 'MODULES=%q\n' "$selection"
    } > "$stage_dir/manifest.conf"; then
        ms_tmp_discard "$stage_dir"
        msg_error "$(T "No se pudo completar la copia. Ninguna configuración incompleta se ha publicado en la carpeta de copias.")"
        return 1
    fi

    if ! chmod -R go-rwx "$stage_dir" 2>/dev/null; then
        ms_tmp_discard "$stage_dir"
        msg_error "$(T "No se pudo asegurar que la copia de seguridad tenga permisos privados. Ninguna configuración incompleta se ha publicado.")"
        return 1
    fi
    if ! ms_commit "$stage_dir" "$backup_dir"; then
        msg_error "$(T "No se pudo completar la copia. Ninguna configuración incompleta se ha publicado en la carpeta de copias.")"
        return 1
    fi

    # Several modules (Network, Bluetooth...) may contain credentials; by
    # default we restrict access to the copy to the current user only.
    # BACKUPS_ROOT lives inside $HOME by default (or in any folder the user
    # has set in MINT_SETUP_BACKUPS_DIR). If it stays inside the home
    # folder, a full disk format when reinstalling Mint (unlike a reinstall
    # that keeps /home separate) would sweep the copy away along with
    # everything else. We warn about it here, just when the user has the
    # freshly made copy in mind.
    local outside_note=""
    case "$BACKUPS_ROOT" in
        "$HOME"|"$HOME"/*)
            outside_note="$(T_FMT '\n\n⚠️ Esta copia vive dentro de tu carpeta personal (%s). Si en algún momento reinstalas Mint formateando TODO el disco (no solo la partición del sistema, dejando /home aparte), esta copia desaparecerá también.\n\nSácala antes a un USB, disco externo o la nube. Puedes hacerlo desde Configuración avanzada → "Exportar copia a...".' "$BACKUPS_ROOT")"
            ;;
    esac

    msg_info "$(T_FMT 'Configuración guardada correctamente en:\n%s%s' "$backup_dir" "$outside_note")"
}

# =============================================================================
# GRAPHICAL INTERFACE: RESTORE CONFIGURATION
# =============================================================================

# Runs a Restore module with an error channel independent of its exit code.
# Some modules carry on after an optional operation fails; the atomic
# helpers then flag the failure and this wrapper turns it into a module
# failure without altering the semantics of the modules that complete
# correctly.
run_restore_module() {
    local mod="$1" backup_dir="$2" RESTORE_CONTEXT=1 RESTORE_MODULE_FAILED=0 rc=0
    "restore_${mod}" "$backup_dir" || rc=$?
    [ "$RESTORE_MODULE_FAILED" -eq 0 ] || rc=1
    return "$rc"
}

# Job of a module that do_restore runs in the background. It ends with "exit" (see ms_tmp_track).
restore_module_job() {
    run_restore_module "$@"
    exit "$?"
}

do_restore() {
    local backup_dir selection modules total pct mod log key mod_rc
    local progress_fifo zenity_pid work_dir logs_dir
    local checklist_args=()
    local -A mod_bytes
    local total_bytes=0 bytes_done=0 restore_start_ts elapsed eta_txt="" b
    local eta_active=0 eta_remaining=0 eta_tick_ts=0 now_ts

    backup_dir=$(pick_backup_dir "$APP_NAME - Restaurar")
    [ -z "$backup_dir" ] && return 0

    for key in "${MODULE_KEYS[@]}"; do
        [ -d "$backup_dir/$key" ] && checklist_args+=(TRUE "$(T "${MODULE_SHORT_LABELS[$key]:-$key}")" "$(T "${MODULE_LABELS[$key]:-$key}")" "$key")
    done

    if [ ${#checklist_args[@]} -eq 0 ]; then
        msg_error "$(T "Esta configuración guardada no contiene datos restaurables.")"
        return 0
    fi

    selection=$(LANGUAGE="$APP_LANG" zenity --list --title="$(T "$APP_NAME - Restaurar")" \
        --text="$(T "¿Qué deseas restaurar?")" \
        --checklist --width=700 --height=500 \
        --column="$(T "Sel")" --column="$(T "Módulo")" --column="$(T "Descripción")" --column="Key" \
        --hide-column=4 --print-column=4 --separator="," \
        "${checklist_args[@]}" \
        2>/dev/null)
    [ -z "$selection" ] && return 0

    IFS=',' read -ra modules <<< "$selection"

    local mods_list="" mod_key
    for mod_key in "${modules[@]}"; do
        mods_list+="$(T "${MODULE_SHORT_LABELS[$mod_key]:-$mod_key}"), "
    done
    mods_list="${mods_list%, }"

    # If ALL the modules available in this backup are restored (not just a
    # selection), we warn that it can take quite a while and that the
    # administrator password may be asked for more than once (every
    # privileged operation asks for it on its own, see prun).
    local full_warn=""
    if [ "${#modules[@]}" -eq $(( ${#checklist_args[@]} / 4 )) ]; then
        full_warn="$(T_FMT '\n\n⚠️ Vas a restaurar TODOS los módulos: puede tardar bastante (Aplicaciones, VS Code o perfiles grandes de navegador/correo son los que más) y es posible que se te pida la contraseña de administrador más de una vez durante el proceso.')"
    fi

    # shellcheck disable=SC2034  # manifest_read fills PKG_MANAGER (and the rest) by name
    local OS_ID="" PKG_MANAGER="" NAME="" DATE="" MODULES="" MINT_RELEASE=""
    if manifest_read "$backup_dir/manifest.conf" 2>/dev/null && [ -n "$OS_ID" ] && [ -n "$PLATFORM_OS_ID" ] \
        && [ "$OS_ID" != "$PLATFORM_OS_ID" ]; then
        full_warn+="$(T_FMT '\n\n⚠️ Esta configuración se guardó en «%s» y este sistema es «%s». Los módulos ligados a la distribución (Aplicaciones, Cinnamon, Nemo) pueden no aplicarse o hacerlo solo en parte.' "${MINT_RELEASE:-$OS_ID}" "$PLATFORM_NAME")"
    fi

    confirm "$(T_FMT 'Vas a restaurar lo siguiente sobre tu sistema actual:\n\n%s\n\nEsto sobrescribirá la configuración actual de esos módulos.%s\n\n¿Deseas continuar?' "$mods_list" "$full_warn")" \
        || return 0

    root_preauth "network bluetooth docker software" "${modules[@]}" \
        || msg_warn "$(T_FMT "No se ha concedido la contraseña de administrador.\n\nLos módulos que la necesitan (Red, Bluetooth, Docker, Aplicaciones) pueden fallar o volver a pedirla más adelante; el resto se restaurará igualmente.")"

    total=${#modules[@]}
    log="$backup_dir/restore.log"; : > "$log"

    # % weighted by the real size of each module (already stored in the
    # backup, so it is an exact figure, not an estimate) instead of by the
    # number of modules: with such uneven data —a few KB of Keyboard against
    # hundreds of MB of Firefox— counting modules equally would leave the bar
    # stuck at the same % for minutes during the big module.
    for mod in "${modules[@]}"; do
        b=$(du -sb "$backup_dir/$mod" 2>/dev/null | cut -f1)
        # Weight >= 1: du reports 0 for an empty folder on btrfs, and
        # bytes_done is the divisor of the ETA (division by 0 aborted the
        # restore if that module finished first, after the first 2 s).
        [ "${b:-0}" -ge 1 ] 2>/dev/null || b=1
        if [ "$mod" = "software" ]; then
            # What this module takes up on disk (text lists, small
            # repository tarballs) bears no relation to how long it takes
            # to restore: almost all the time is network (apt-get update,
            # installing packages and Flatpaks), not copying bytes. Without
            # this, the % stayed stuck at a low value for that whole time.
            local n_apt=0 n_flat=0
            [ -f "$backup_dir/software/apt-manual.list" ] && n_apt=$(wc -l < "$backup_dir/software/apt-manual.list" 2>/dev/null || echo 0)
            [ -f "$backup_dir/software/flatpak.list" ] && n_flat=$(wc -l < "$backup_dir/software/flatpak.list" 2>/dev/null || echo 0)
            b=$(( b + n_apt * 500000 + n_flat * 4000000 ))
        elif [ "$mod" = "vscode" ] && [ -f "$backup_dir/vscode/extensions.list" ]; then
            # Same case as "software": each extension is reinstalled on its
            # own from the marketplace (network), not copied from the backup.
            local n_ext
            n_ext=$(wc -l < "$backup_dir/vscode/extensions.list" 2>/dev/null || echo 0)
            b=$(( b + n_ext * 3000000 ))
        fi
        mod_bytes[$mod]=$b
        total_bytes=$(( total_bytes + b ))
    done
    [ "$total_bytes" -eq 0 ] && total_bytes=1
    pct=0
    restore_start_ts=$(date +%s)

    # zenity runs in the background fed by a FIFO. --auto-close does not
    # reliably close the dialog in every zenity version, so we also close it
    # ourselves (SIGTERM and, if needed, SIGKILL) as soon as the work has
    # really finished, without depending on zenity reacting by itself at
    # 100%.
    work_dir=$(mktemp -d 2>/dev/null) || work_dir=""
    [ -n "$work_dir" ] && ms_tmp_track "$work_dir"
    progress_fifo="$work_dir/progress"
    logs_dir="$work_dir/logs"
    if [ -z "$work_dir" ] || ! mkfifo -m 600 "$progress_fifo" 2>/dev/null \
            || ! mkdir -m 700 "$logs_dir" 2>/dev/null; then
        [ -n "$work_dir" ] && ms_tmp_discard "$work_dir"
        msg_error "$(T "No se pudo crear una carpeta temporal. Comprueba que hay espacio libre en el disco.")"
        return 1
    fi
    LANGUAGE="$APP_LANG" zenity --progress --title="$APP_NAME" --text="$(T "Restaurando configuración...")" \
        --auto-close --width=420 < "$progress_fifo" 2>/dev/null &
    zenity_pid=$!

    # If zenity never starts (e.g. no graphical session), nobody opens the
    # other end of the pipe and "exec 3>" would wait forever for a reader
    # that never comes. A small margin and a liveness check avoid that
    # indefinite block.
    sleep 0.1
    if ! kill -0 "$zenity_pid" 2>/dev/null; then
        ms_tmp_discard "$work_dir"
        msg_error "$(T "No se pudo mostrar la barra de progreso de Restaurar (¿hay una sesión gráfica activa?).")"
        return 1
    fi
    exec 3> "$progress_fifo"

    # The independent modules are ALL launched at once instead of one by one
    # (the total time used to be the SUM of every module; now it is, roughly,
    # that of the slowest). VS Code and Docker are the only exception: they
    # check with "command -v" whether their program is already installed,
    # and that program may come precisely from the Applications module, so
    # they wait for it to finish (if Applications is not among the
    # selected modules, there is nothing to wait for and they are launched
    # right away too).
    # Displays is the other exception, and it runs LAST and alone: it changes
    # the resolution while the privileged modules have PolicyKit dialogs open,
    # and in a real full restore Network, Bluetooth and Applications then
    # failed. It starts only when every other module (the deferred ones too)
    # has finished, so no privileged call is in flight; if the restore is
    # cancelled before that, it never starts.
    local -a phase1_mods=() deferred_mods=() last_mods=() running=()
    local -A mod_pid=() mod_log=()
    local needs_software=0 software_pid="" deferred_launched=0 last_launched=0
    local completed=0 cancelled=0 failed=0 interrupted_list="" failed_list="" status_suffix new_line list

    for mod in "${modules[@]}"; do [ "$mod" = "software" ] && needs_software=1; done
    for mod in "${modules[@]}"; do
        if [ "$needs_software" -eq 1 ] && { [ "$mod" = "vscode" ] || [ "$mod" = "docker" ]; }; then
            deferred_mods+=("$mod")
        elif [ "$mod" = "displays" ]; then
            last_mods+=("$mod")
        else
            phase1_mods+=("$mod")
        fi
    done

    for mod in "${phase1_mods[@]}"; do
        mod_log[$mod]="$logs_dir/$mod.log"
        : > "${mod_log[$mod]}"
        restore_module_job "$mod" "$backup_dir" >> "${mod_log[$mod]}" 2>&1 &
        mod_pid[$mod]=$!
        [ "$mod" = "software" ] && software_pid=${mod_pid[$mod]}
    done
    running=("${phase1_mods[@]}")

    # Also loop while deferred or last modules are still unlaunched: "software"
    # can end in the very turn that empties "running", and they would never be
    # started.
    while [ ${#running[@]} -gt 0 ] \
        || { [ "$deferred_launched" -eq 0 ] && [ ${#deferred_mods[@]} -gt 0 ]; } \
        || { [ "$last_launched" -eq 0 ] && [ ${#last_mods[@]} -gt 0 ]; }; do
        # If the user has already pressed Cancel, the zenity process has
        # ended on its own: kill -0 no longer sees it alive. Everything still
        # running is killed and nothing else is launched.
        if ! kill -0 "$zenity_pid" 2>/dev/null; then
            cancelled=1
            for mod in "${running[@]}"; do
                # The module itself (our user) can be killed; if at that
                # moment it is waiting inside a pkexec, the elevated process
                # (root) may be left orphaned and keep running, something
                # that is reported afterwards in the final message.
                kill "${mod_pid[$mod]}" 2>/dev/null
                interrupted_list+="$(T "${MODULE_SHORT_LABELS[$mod]:-$mod}"), "
            done
            break
        fi

        if [ "$deferred_launched" -eq 0 ] && { [ -z "$software_pid" ] || ! kill -0 "$software_pid" 2>/dev/null; }; then
            deferred_launched=1
            for mod in "${deferred_mods[@]}"; do
                mod_log[$mod]="$logs_dir/$mod.log"
                : > "${mod_log[$mod]}"
                restore_module_job "$mod" "$backup_dir" >> "${mod_log[$mod]}" 2>&1 &
                mod_pid[$mod]=$!
                running+=("$mod")
            done
        fi

        # Last modules: only once nothing else is running and nothing is left to
        # launch (the deferred ones included, hence the check on "running" after
        # the block above).
        if [ "$last_launched" -eq 0 ] && [ ${#last_mods[@]} -gt 0 ] && [ ${#running[@]} -eq 0 ]; then
            last_launched=1
            for mod in "${last_mods[@]}"; do
                mod_log[$mod]="$logs_dir/$mod.log"
                : > "${mod_log[$mod]}"
                restore_module_job "$mod" "$backup_dir" >> "${mod_log[$mod]}" 2>&1 &
                mod_pid[$mod]=$!
                running+=("$mod")
            done
        fi

        # The countdown advances on every loop turn (not only when a module
        # finishes): it used to stay stuck at the same number of seconds
        # while a long module (e.g. Applications) printed nothing new for a
        # while.
        if [ "$eta_active" -eq 1 ]; then
            now_ts=$(date +%s)
            eta_remaining=$(( eta_remaining - (now_ts - eta_tick_ts) ))
            eta_tick_ts=$now_ts
            eta_txt=$(fmt_eta_txt "$eta_remaining")
        fi

        local still_running=() finished_now=()
        for mod in "${running[@]}"; do
            if kill -0 "${mod_pid[$mod]}" 2>/dev/null; then
                still_running+=("$mod")
            else
                finished_now+=("$mod")
            fi
        done

        # With a single module running, the detail of its log is shown
        # (as before, so that long modules such as Applications do not
        # look hung); with several at once, the list of those still running
        # already makes it clear that the process is moving along.
        if [ ${#still_running[@]} -eq 1 ]; then
            mod="${still_running[0]}"
            new_line=$(tail -n 1 "${mod_log[$mod]}" 2>/dev/null)
            status_suffix="$(T "${MODULE_SHORT_LABELS[$mod]:-$mod}"): ${new_line:-$(T "Restaurando...")}"
        elif [ ${#still_running[@]} -gt 1 ]; then
            list=""
            for mod in "${still_running[@]}"; do list+="$(T "${MODULE_SHORT_LABELS[$mod]:-$mod}"), "; done
            status_suffix="$(T_FMT 'Restaurando a la vez: %s' "${list%, }")"
        fi
        [ ${#still_running[@]} -gt 0 ] && printf '# %s%%%s — %s\n' "$pct" "$eta_txt" "$status_suffix" >&3 2>/dev/null

        if [ ${#finished_now[@]} -gt 0 ]; then
            for mod in "${finished_now[@]}"; do
                mod_rc=0
                wait "${mod_pid[$mod]}" 2>/dev/null || mod_rc=$?
                if [ "$mod_rc" -ne 0 ]; then
                    failed=$((failed + 1))
                    failed_list+="$(T "${MODULE_SHORT_LABELS[$mod]:-$mod}"), "
                fi
                # restore.log is read by people: each module goes under a header with its exit
                # status (the module key and "exit N" are not translated, so a report reads the same).
                printf '== %s: exit %s ==\n' "$mod" "$mod_rc" >> "$log"
                cat "${mod_log[$mod]}" >> "$log"
                completed=$((completed + 1))
                bytes_done=$(( bytes_done + ${mod_bytes[$mod]:-1} ))
            done
            # The percentage is sent AFTER each module finishes, not before:
            # that way the 100% (and the resulting closing of the dialog)
            # only arrives when the last one has really been restored.
            pct=$(( bytes_done * 100 / total_bytes ))
            [ "$pct" -gt 100 ] && pct=100
            eta_txt=""
            eta_active=0
            if [ "$completed" -lt "$total" ]; then
                elapsed=$(( $(date +%s) - restore_start_ts ))
                # With less than 2s of margin the measured speed is not
                # reliable yet; it is recalculated every time any module
                # finishes, so if something takes longer or shorter than
                # expected, the next calculation already corrects it.
                if [ "$elapsed" -ge 2 ]; then
                    # The pending modules run in parallel, not one after
                    # another: the time left is set by the heaviest of them
                    # (whether it keeps running or is deferred and not yet
                    # launched), not the sum of all. Adding them up multiplied
                    # the estimate by the number of simultaneous modules.
                    local max_pending=0
                    for mod in "${still_running[@]}"; do
                        [ "${mod_bytes[$mod]:-0}" -gt "$max_pending" ] && max_pending=${mod_bytes[$mod]}
                    done
                    if [ "$deferred_launched" -eq 0 ]; then
                        for mod in "${deferred_mods[@]}"; do
                            [ "${mod_bytes[$mod]:-0}" -gt "$max_pending" ] && max_pending=${mod_bytes[$mod]}
                        done
                    fi
                    eta_remaining=$(( max_pending * elapsed / bytes_done ))
                    eta_tick_ts=$(date +%s)
                    eta_active=1
                    eta_txt=$(fmt_eta_txt "$eta_remaining")
                fi
            fi
            echo "$pct" >&3 2>/dev/null
        fi

        running=("${still_running[@]}")
        sleep 0.3
    done

    exec 3>&-
    ms_tmp_discard "$work_dir"
    if kill -0 "$zenity_pid" 2>/dev/null; then
        kill "$zenity_pid" 2>/dev/null
        sleep 0.2
        kill -0 "$zenity_pid" 2>/dev/null && kill -9 "$zenity_pid" 2>/dev/null
    fi
    wait "$zenity_pid" 2>/dev/null

    # "completed" counts modules that finished, failed ones included: the dialogs
    # report completed - failed, so a failed module is never a completed one.
    if [ "$cancelled" -eq 1 ]; then
        local mid_note=""
        interrupted_list="${interrupted_list%, }"
        [ -n "$interrupted_list" ] && mid_note="$(T_FMT ' Estos módulos pudieron quedar a medias: «%s». Si en ese momento se estaba pidiendo la contraseña de administrador, esas operaciones pueden seguir en marcha en segundo plano aunque hayas cerrado la ventana: espera un momento antes de volver a intentarlo.' "$interrupted_list")"
        msg_warn "$(T_FMT 'Restauración cancelada.\n\nSe completaron %s de %s módulo(s).%s' "$((completed - failed))" "$total" "$mid_note")"
        return 0
    fi

    if [ "$failed" -gt 0 ]; then
        failed_list="${failed_list%, }"
        msg_warn "$(T_FMT 'La restauración ha terminado con errores.\n\nSe completaron %s de %s módulo(s), pero fallaron: %s.' "$((completed - failed))" "$total" "$failed_list")"
        return 1
    fi

    msg_info "$(T_FMT "Configuración restaurada.\n\nEs posible que necesites cerrar sesión o reiniciar Cinnamon (Ctrl+Alt+Esc) para ver todos los cambios.")"
}

# =============================================================================
# GRAPHICAL INTERFACE: COMPARE CONFIGURATION
# =============================================================================

do_compare() {
    local backup_dir report changes old_theme new_theme old_icons new_icons
    local old_bg new_bg same_bg restored_bg old_applets new_applets current_pkgs old_pkgs added removed

    backup_dir=$(pick_backup_dir "$APP_NAME - Comparar")
    [ -z "$backup_dir" ] && return 0

    report=$(mktemp)
    {
        log_msg "$(T "Comparando el sistema actual con:")"
        echo "$backup_dir"
        printf '\n'
        log_msg "$(T "Cambios detectados")"
        log_msg "$(T "-------------------")"
    } > "$report"
    changes=0

    if [ -f "$backup_dir/appearance/interface.dconf" ]; then
        old_theme=$(grep "^gtk-theme=" "$backup_dir/appearance/interface.dconf" | head -1 | cut -d= -f2-)
        new_theme=$(gsettings get org.cinnamon.desktop.interface gtk-theme 2>/dev/null)
        [ -n "$old_theme" ] && [ "$old_theme" != "$new_theme" ] && { log_msg "$(T "• El tema ha cambiado")" >> "$report"; changes=$((changes+1)); }

        old_icons=$(grep "^icon-theme=" "$backup_dir/appearance/interface.dconf" | head -1 | cut -d= -f2-)
        new_icons=$(gsettings get org.cinnamon.desktop.interface icon-theme 2>/dev/null)
        [ -n "$old_icons" ] && [ "$old_icons" != "$new_icons" ] && { log_msg "$(T "• Los iconos han cambiado")" >> "$report"; changes=$((changes+1)); }
    fi

    if [ -f "$backup_dir/appearance/background.dconf" ]; then
        old_bg=$(grep "^picture-uri=" "$backup_dir/appearance/background.dconf" | head -1 | cut -d= -f2-)
        new_bg=$(gsettings get org.cinnamon.desktop.background picture-uri 2>/dev/null)
        # A restore points the key at its copy of the image (see restore_wallpaper_uri), not at the
        # path in the dump: that is the saved wallpaper too, not a change.
        same_bg=0
        [ "$old_bg" != "$new_bg" ] || same_bg=1
        if [ "$same_bg" -eq 0 ] && restored_bg=$(wallpaper_restore_dest "$backup_dir/appearance" ""); then
            [ "$(gvariant_string_value "$new_bg")" != "file://$(uri_encode_path "$restored_bg")" ] || same_bg=1
        fi
        [ -n "$old_bg" ] && [ "$same_bg" -eq 0 ] && { log_msg "$(T "• Nuevo fondo de pantalla")" >> "$report"; changes=$((changes+1)); }
    fi

    if [ -f "$backup_dir/desktop/cinnamon.dconf" ]; then
        old_applets=$(grep "^enabled-applets=" "$backup_dir/desktop/cinnamon.dconf" | head -1 | cut -d= -f2-)
        new_applets=$(gsettings get org.cinnamon enabled-applets 2>/dev/null)
        [ -n "$old_applets" ] && [ "$old_applets" != "$new_applets" ] && { log_msg "$(T "• Ha cambiado la lista de applets del panel")" >> "$report"; changes=$((changes+1)); }
    fi

    if [ -f "$backup_dir/software/apt-manual.list" ] && command -v apt-mark >/dev/null 2>&1; then
        current_pkgs=$(mktemp); old_pkgs=$(mktemp)
        apt-mark showmanual 2>/dev/null | sort > "$current_pkgs"
        sort "$backup_dir/software/apt-manual.list" > "$old_pkgs"
        added=$(comm -13 "$old_pkgs" "$current_pkgs" | wc -l)
        removed=$(comm -23 "$old_pkgs" "$current_pkgs" | wc -l)
        [ "$added" -gt 0 ] && { log_msg "$(T_FMT '• %s paquete(s) nuevo(s) instalado(s) desde el guardado' "$added")" >> "$report"; changes=$((changes+1)); }
        [ "$removed" -gt 0 ] && { log_msg "$(T_FMT '• %s paquete(s) eliminado(s) desde el guardado' "$removed")" >> "$report"; changes=$((changes+1)); }
        rm -f "$current_pkgs" "$old_pkgs"
    fi

    [ "$changes" -eq 0 ] && { printf '\n' >> "$report"; log_msg "$(T "No se han detectado cambios relevantes en las áreas guardadas.")" >> "$report"; }

    LANGUAGE="$APP_LANG" zenity --text-info --title="$(T "$APP_NAME - Comparador")" --filename="$report" --width=520 --height=420 2>/dev/null
    rm -f "$report"
}

# =============================================================================
# GRAPHICAL INTERFACE: EXPORT A COPY TO ANOTHER LOCATION
# =============================================================================

# Copies an already saved configuration to the folder the user chooses (USB,
# external disk, another partition, a cloud-synced folder...), leaving the
# original copy in BACKUPS_ROOT intact. It is the recommended way for the
# copy to survive a full disk format, since BACKUPS_ROOT lives inside $HOME
# by default.
do_export_backup() {
    local src dest_parent dest_dir errfile rc note MODULES cred_mods cred_list export_mods m stuck
    local stage rollback_dir old_stem old_to_remove old_left cp_rc verify_rc detail

    src=$(pick_backup_dir "$(T "$APP_NAME - Exportar")")
    [ -z "$src" ] && return 0

    dest_parent=$(LANGUAGE="$APP_LANG" zenity --file-selection --directory \
        --title="$(T "Elige dónde exportar la copia (USB, disco externo...)")" \
        2>/dev/null)
    [ -z "$dest_parent" ] && return 0

    dest_dir="$dest_parent/$(basename "$src")"

    # The destination folder is the source itself (the backups folder chosen as
    # destination, directly or through a symlink): "overwriting" it would swap
    # the only copy for a copy of itself and report an export that went nowhere.
    if [ "$dest_dir" -ef "$src" ]; then
        msg_error "$(T_FMT 'El origen y el destino son la misma carpeta:\n%s\n\nElige otra carpeta de destino (por ejemplo, un USB o un disco externo).' "$src")"
        return 1
    fi

    # -L as well: -e follows symlinks, so a dangling one (e.g. to an unmounted
    # disk) looked absent and was replaced below without asking.
    if [ -e "$dest_dir" ] || [ -L "$dest_dir" ]; then
        confirm "$(T_FMT 'Ya existe una carpeta con ese nombre en el destino:\n%s\n\n¿Sobrescribirla?' "$dest_dir")" || return 0
    fi

    # The stderr capture and its exit code file are registered like the staged
    # copy: a TERM, HUP or INT during the copy would otherwise leave them behind.
    errfile=$(mktemp 2>/dev/null) || {
        msg_error "$(T "No se pudo crear el archivo temporal.")"
        return 1
    }
    ms_tmp_track "$errfile"
    ms_tmp_track "$errfile.rc"
    if ! ms_mktemp stage "$dest_dir" d; then
        ms_tmp_discard "$errfile" "$errfile.rc"
        msg_error "$(T_FMT 'No se pudo preparar el destino para la exportación:\n%s\n\nComprueba que tienes permiso de escritura y espacio suficiente.' "$dest_parent")"
        return 1
    fi

    (
        cp -a "$src/." "$stage/" 2>"$errfile"
        cp_rc=$?
        printf '%s\n' "$cp_rc" > "$errfile.rc"
        exit "$cp_rc"
    # --no-cancel: nothing here stops cp midway, so a Cancel button would close
    # the window while the export carried on and ended with a success message.
    ) | LANGUAGE="$APP_LANG" zenity --progress --pulsate --auto-close --no-cancel \
        --title="$APP_NAME" --text="$(T_FMT 'Exportando copia a:\n%s' "$(markup_escape "$dest_parent")")" --width=420 2>/dev/null

    rc=$(cat "$errfile.rc" 2>/dev/null)
    cp_rc=${rc:-125}
    verify_rc=1
    if [ -d "$stage" ]; then
        diff -qr -- "$src" "$stage" >/dev/null 2>&1
        verify_rc=$?
    fi

    if [ "$verify_rc" -ne 0 ]; then
        detail=$(head -c 300 "$errfile")
        [ -z "$detail" ] && detail="$(T "El contenido del destino temporal no coincide con la copia original.")"
        ms_tmp_discard "$stage"
        ms_tmp_discard "$errfile" "$errfile.rc"
        msg_error "$(T_FMT 'No se pudo exportar la copia completa. No se ha sustituido el destino.\n\nDetalle: %s' "$detail")"
        return 1
    fi

    old_to_remove=""
    if [ -e "$dest_dir" ] || [ -L "$dest_dir" ]; then
        # Same cut as the staged folder (ms_mktemp): a 239 to 255-byte name leaves no room for
        # the 17 bytes of this one.
        ms_tmp_stem old_stem "${dest_dir##*/}"
        rollback_dir=$(mktemp -d -- "$dest_parent/.$old_stem.mint-old.XXXXXX" 2>/dev/null) || {
            ms_tmp_discard "$stage"
            ms_tmp_discard "$errfile" "$errfile.rc"
            msg_error "$(T_FMT 'No se pudo preparar la sustitución segura del destino:\n%s' "$dest_dir")"
            return 1
        }
        ms_tmp_track "$rollback_dir"
        rmdir -- "$rollback_dir" || {
            ms_tmp_discard "$rollback_dir"
            ms_tmp_discard "$stage"
            ms_tmp_discard "$errfile" "$errfile.rc"
            msg_error "$(T_FMT 'No se pudo preparar la sustitución segura del destino:\n%s' "$dest_dir")"
            return 1
        }
        _MS_DIR_SWAP_OLD="$rollback_dir"
        _MS_DIR_SWAP_DEST="$dest_dir"
        if ! mv -T -- "$dest_dir" "$rollback_dir"; then
            _MS_DIR_SWAP_OLD=""
            _MS_DIR_SWAP_DEST=""
            ms_tmp_discard "$rollback_dir"
            ms_tmp_discard "$stage"
            ms_tmp_discard "$errfile" "$errfile.rc"
            msg_error "$(T_FMT 'No se pudo apartar la copia existente para sustituirla:\n%s' "$dest_dir")"
            return 1
        fi
        old_to_remove="$rollback_dir"
    fi

    if ! ms_commit "$stage" "$dest_dir"; then
        stuck=""
        ms_dir_swap_restore || stuck="$MS_DIR_SWAP_STUCK"
        ms_tmp_discard "$stage"
        ms_tmp_discard "$errfile" "$errfile.rc"
        if [ -n "$stuck" ]; then
            msg_error "$(T_FMT 'No se pudo publicar la copia exportada y la copia anterior no se pudo devolver a su sitio. No se ha borrado: sigue en la carpeta oculta:\n%s' "$stuck")"
        else
            msg_error "$(T_FMT 'No se pudo publicar la copia exportada. El destino anterior se ha conservado siempre que ha sido posible:\n%s' "$dest_dir")"
        fi
        return 1
    fi

    _MS_DIR_SWAP_OLD=""
    _MS_DIR_SWAP_DEST=""
    # ms_rm_tmp opens read-only folders (e.g. 0555) before deleting and keeps
    # rm quiet. What it cannot delete stays in a hidden folder that keeps using
    # space on the destination (and tracked, so the exit trap retries): report it.
    old_left=""
    if [ -n "$old_to_remove" ]; then
        if ms_rm_tmp "$old_to_remove"; then
            ms_tmp_untrack "$old_to_remove"
        else
            old_left="$old_to_remove"
        fi
    fi

    note=""
    if [ -n "$old_left" ]; then
        note="$(T_FMT '\n\n⚠️ No se pudo borrar la copia anterior del destino, que sigue ocupando espacio (carpeta oculta). Bórrala a mano:\n%s' "$old_left")"
    fi
    if [ "$cp_rc" -ne 0 ]; then
        note+="$(T_FMT '\n\n⚠️ El contenido se ha verificado y está completo, pero algunos atributos (permisos, propietario o fechas) no se pudieron preservar. Es habitual en FAT32/exFAT, que no soportan permisos Unix.\n\nDetalle: %s' "$(head -c 300 "$errfile")")"
    fi
    # The original copy records in its manifest which modules it contains. If
    # it includes any of those that do_save() already treats as carrying
    # credentials (Network, Bluetooth, Docker, Thunderbird, Firefox, LibreWolf)
    # we warn because the destination may not support the restricted
    # permissions (go-rwx) that protect them — for example, a USB formatted as
    # FAT32/exFAT has no Unix-style permissions.
    MODULES=""
    if ! manifest_read "$src/manifest.conf" 2>/dev/null; then
        MODULES=""
    fi
    IFS=',' read -ra export_mods <<< "$MODULES"
    cred_mods=()
    for m in "${export_mods[@]}"; do
        case "$m" in
            network)     cred_mods+=("$(T "Red")") ;;
            bluetooth)   cred_mods+=("$(T "Bluetooth")") ;;
            thunderbird) cred_mods+=("$(T "Thunderbird")") ;;
            docker)      cred_mods+=("$(T "Docker")") ;;
            firefox)     cred_mods+=("$(T "Firefox")") ;;
            librewolf)   cred_mods+=("$(T "LibreWolf")") ;;
        esac
    done
    if [ ${#cred_mods[@]} -gt 0 ]; then
        cred_list=$(printf '%s, ' "${cred_mods[@]}")
        cred_list="${cred_list%, }"
        note+="$(T_FMT '\n\n⚠️ Esta copia incluye el módulo %s (puede contener contraseñas Wi-Fi, claves de emparejamiento, contraseñas de correo, contraseñas guardadas en el navegador y/o credenciales de registros Docker). En destinos sin permisos de tipo Unix (por ejemplo, un USB en FAT32/exFAT) no se puede restringir el acceso a esos archivos: cualquiera con el USB en la mano podría leerlas.' "$cred_list")"
    fi
    msg_info "$(T_FMT 'Copia exportada correctamente a:\n%s%s' "$dest_dir" "$note")"
    ms_tmp_discard "$errfile" "$errfile.rc"
}


# =============================================================================
# LUKS HEADER: BACKUP AND EMERGENCY RESTORE
# The LUKS header holds the encryption information needed to unlock the
# disk (metadata + keyslots); if it is corrupted, the data is
# unrecoverable even if the password is correct. It is not a module of
# the Save/Restore checklist (it is not user configuration, but a copy
# tied to one specific physical disk), so it lives in Advanced
# settings.
# ⚠️ Requires administrator permissions: reading or writing the raw block
# device can only be done by root.
# =============================================================================

# Lists, without needing administrator permissions, the devices with a
# detected LUKS header (lsblk reads metadata already cached by udev, not the
# raw device). Output: "device|size|UUID" per line.
luks_detect_devices() {
    local name _ fstype size uuid
    while IFS=' ' read -r name _ fstype size uuid; do
        [ "$fstype" = "crypto_LUKS" ] || continue
        printf '%s|%s|%s\n' "$name" "${size:-?}" "${uuid:-$(T "sin-UUID")}"
    done < <(lsblk -prno NAME,TYPE,FSTYPE,SIZE,UUID 2>/dev/null)
}

# Device picker: lists those detected by luks_detect_devices plus an
# option to type the path by hand (in case the disk is not detected on
# its own, e.g. a LUKS container inside a file). $1 is the warning text
# shown above the list. Returns the chosen path on stdout, or nothing if
# cancelled.
luks_pick_device() {
    local warn_text="$1" options=() dev size uuid device n=0 manual_label

    while IFS='|' read -r dev size uuid; do
        [ -z "$dev" ] && continue
        options+=("$dev" "$size" "$uuid")
        n=$((n + 1))
    done < <(luks_detect_devices)

    if [ "$n" -eq 0 ]; then
        confirm "$(T_FMT "No se ha detectado ningún dispositivo cifrado con LUKS en este equipo.\n\n¿Quieres indicar la ruta manualmente (p. ej. /dev/sdb1)?")" || return 0
        manual_label="$(T "Otro...")"
        device="$manual_label"
    else
        manual_label="$(T "Otro...")"
        options+=("$manual_label" "" "$(T "Especificar ruta manualmente")")
        device=$(LANGUAGE="$APP_LANG" zenity --list --title="$(T "$APP_NAME - Header LUKS")" \
            --text="$(T "$warn_text")" --width=580 --height=280 \
            --column="$(T "Dispositivo")" --column="$(T "Tamaño")" --column="UUID" \
            "${options[@]}" 2>/dev/null)
        [ -z "$device" ] && return 0
    fi

    manual_label="${manual_label:-$(T "Otro...")}"
    if [ "$device" = "$manual_label" ]; then
        device=$(LANGUAGE="$APP_LANG" zenity --entry --title="$(T "$APP_NAME - Header LUKS")" \
            --text="$(T "Ruta del dispositivo (p. ej. /dev/sdb1):")" --width=380 2>/dev/null)
        [ -z "$device" ] && return 0
    fi
    printf '%s' "$device"
}

# Streams the LUKS header of "$1" to stdout, read as root through prun.
# cryptsetup refuses to write over a file that already exists ("Requested
# header backup file ... already exists"), so it cannot be pointed at a
# temporary file created beforehand; and a file it creates as root stays 0400
# root, unreadable for the user. So root works inside its own private folder
# and only streams the content out: the destination file is created by the
# user's shell, belongs to the user, and nothing privileged ever touches a
# path the user controls. Diagnostics go to stderr.
luks_header_stream() {
    # shellcheck disable=SC2016
    prun bash -c 'd=$(mktemp -d) || exit 1; trap "rm -rf -- \"\$d\"" EXIT; cryptsetup -q luksHeaderBackup "$1" --header-backup-file "$d/header" && cat "$d/header"' _ "$1"
}

# Dumps into a separate text file ($2) the readable metadata of the LUKS
# header of $1 (UUID, cipher, hash, keyslots) via "cryptsetup luksDump".
# It is only reference documentation: a text dump does not contain the
# cryptographic material needed to unlock the disk, so it neither replaces
# the binary copy nor can it restore anything on its own; it helps if
# that copy (the .img) gets corrupted or lost.
luks_save_info() {
    local device="$1" outfile="$2" errfile tmp
    errfile=$(mktemp) || return 1
    ms_tmp_track "$errfile"
    if ! ms_mktemp tmp "$outfile"; then
        ms_tmp_discard "$errfile"
        return 1
    fi
    # The temp file is already the user's and is born with 600; root only
    # writes the content. If cryptsetup fails, the old destination is untouched.
    # shellcheck disable=SC2016
    if prun bash -c 'cryptsetup luksDump "$1" > "$2"' \
        _ "$device" "$tmp" 2>"$errfile" && ms_commit "$tmp" "$outfile"; then
        ms_tmp_discard "$errfile"
        return 0
    fi
    ms_tmp_discard "$tmp"
    ms_tmp_discard "$errfile"
    return 1
}

do_luks_header_backup() {
    local device outfile outfile_info uuid ts label errfile info_note tmp base_outfile name_seq
    local uuid_key prev prev_name prev_last prev_count copy_suffix made

    if ! command -v cryptsetup >/dev/null 2>&1; then
        msg_error "$(T_FMT "cryptsetup no está instalado; no se puede hacer la copia del header.\n\nInstálalo con:\nsudo apt install cryptsetup")"
        return 1
    fi
    if ! command -v pkexec >/dev/null 2>&1; then
        msg_error "$(T "pkexec no está disponible; no se puede leer el dispositivo (requiere acceso root).")"
        return 1
    fi

    device=$(luks_pick_device "Elige el dispositivo cifrado cuyo header quieres respaldar:")
    [ -z "$device" ] && return 0
    # It also accepts a regular file (LUKS container with no associated loop
    # device), not only block devices: cryptsetup operates the same on both,
    # and luks_pick_device already offers the manual path with that case in
    # mind.
    [ -b "$device" ] || [ -f "$device" ] || { msg_error "$(T_FMT '«%s» no existe, o no es ni un dispositivo de bloques ni un archivo.' "$device")"; return 0; }

    uuid=$(lsblk -no UUID "$device" 2>/dev/null | head -n1)
    ts=$(date '+%Y%m%d-%H%M%S')
    label=$(printf '%s' "$(basename "$device")-${uuid:-sinuuid}" | tr -c '[:alnum:]_-' '_')

    # Earlier copies of THIS disk's header. They are matched by UUID, so they
    # are still found if the device name changed; without a UUID the whole
    # label is used so two different disks are never mixed up. Recovery copies
    # (luks-header-recovery_*) are not counted.
    uuid_key=$(printf '%s' "$uuid" | tr -c '[:alnum:]_-' '_')
    prev_count=0; prev_last=""
    for prev in "$LUKS_HEADERS_DIR"/luks-header_*.img; do
        [ -f "$prev" ] || continue
        prev_name=${prev##*/}
        if [ -n "$uuid_key" ]; then
            [[ "$prev_name" == luks-header_*"-${uuid_key}"_* ]] || continue
        else
            [[ "$prev_name" == "luks-header_${label}_"* ]] || continue
        fi
        prev_count=$((prev_count + 1)); prev_last="$prev"
    done
    copy_suffix=""
    if [ "$prev_count" -gt 0 ]; then
        copy_suffix="_copy$((prev_count + 1))"
        if [ "$prev_count" -eq 1 ]; then
            confirm "$(T_FMT 'Ya existe una copia del header LUKS de %s:\n%s\n\n¿Hacer otra copia adicional? Se guardará aparte como copia n.º %s y la anterior no se tocará.' "$device" "$prev_last" "$((prev_count + 1))")" || return 0
        else
            confirm "$(T_FMT 'Ya existen %s copias del header LUKS de %s. La más reciente:\n%s\n\n¿Hacer otra copia adicional? Se guardará aparte como copia n.º %s y las anteriores no se tocarán.' "$prev_count" "$device" "$prev_last" "$((prev_count + 1))")" || return 0
        fi
    fi

    outfile="$LUKS_HEADERS_DIR/luks-header_${label}_${ts}${copy_suffix}.img"
    outfile_info="${outfile%.img}.txt"
    base_outfile="$outfile"
    name_seq=0
    while [ -e "$outfile" ] || [ -L "$outfile" ] || [ -e "$outfile_info" ] || [ -L "$outfile_info" ]; do
        name_seq=$((name_seq + 1))
        outfile="${base_outfile%.img}_${name_seq}.img"
        outfile_info="${outfile%.img}.txt"
    done

    confirm "$(T_FMT 'Se va a copiar el header LUKS de:\n%s\n\na:\n%s\n\n(y un volcado de texto con sus metadatos, por si este archivo se corrompiera)\n\nSe te pedirá la contraseña de administrador. ¿Continuar?' "$device" "$outfile")" || return 0

    if ! mkdir -p "$LUKS_HEADERS_DIR"; then
        msg_error "$(T_FMT 'No se pudo crear la carpeta para las copias del header LUKS:\n%s' "$LUKS_HEADERS_DIR")"
        return 1
    fi
    if ! chmod 700 "$LUKS_HEADERS_DIR" 2>/dev/null; then
        msg_error "$(T_FMT 'No se pudo asegurar que la carpeta de copias de seguridad tenga permisos privados (700):\n%s\n\nComprueba los permisos o el tipo de sistema de archivos, o define otra carpeta en MINT_SETUP_BACKUPS_DIR.' "$LUKS_HEADERS_DIR")"
        return 1
    fi
    errfile=$(mktemp) || return 1
    ms_tmp_track "$errfile"
    if ! ms_mktemp tmp "$outfile"; then
        ms_tmp_discard "$errfile"
        msg_error "$(T_FMT 'No se pudo hacer la copia del header (permisos denegados, cancelado, o «%s» no es un volumen LUKS válido).\n\nDetalle: %s' "$device" "$(T "No se pudo crear el archivo temporal.")")"
        return 0
    fi
    # The header is streamed into a temporary file owned by the user (see
    # luks_header_stream) and only published once it reads back as a LUKS
    # header; a failure never leaves a partial file.
    made=0
    if luks_header_stream "$device" > "$tmp" 2>"$errfile"; then
        if [ -s "$tmp" ] && cryptsetup luksDump "$tmp" >/dev/null 2>&1; then
            ms_commit "$tmp" "$outfile" && made=1
        else
            printf '%s\n' "$(T 'La copia generada no se puede leer como un header LUKS válido.')" > "$errfile"
        fi
    fi
    if [ "$made" -eq 1 ]; then
        if luks_save_info "$device" "$outfile_info"; then
            info_note="$(T_FMT '\n\nTambién se ha guardado un volcado de texto con los metadatos del header (UUID, cifrado, keyslots...) en:\n%s\n\nEste archivo por sí solo NO permite desbloquear el disco: es solo referencia adicional por si la copia binaria se corrompiera.' "$outfile_info")"
        else
            info_note="$(T_FMT '\n\n⚠️ No se ha podido guardar el volcado de metadatos en texto (la copia binaria de arriba sí se completó y es la que hace falta para restaurar).')"
        fi
        msg_info "$(T_FMT 'Copia del header LUKS creada correctamente:\n%s%s\n\n⚠️ Guarda también una copia FUERA de este equipo (USB, otro disco...): si el disco entero falla, este archivo se pierde con él. Cópiala con tu gestor de archivos: Configuración avanzada → «Abrir carpeta de configuraciones guardadas» → LuksHeaders (el asistente «Exportar copia a...» no sirve aquí: solo lista configuraciones guardadas, no esta carpeta).\n\n⚠️ Este archivo, junto con tu contraseña de cifrado, permite desbloquear el disco: protégelo igual de bien que la propia contraseña.' "$outfile" "$info_note")"
    else
        ms_tmp_discard "$tmp"
        msg_error "$(T_FMT 'No se pudo hacer la copia del header (permisos denegados, cancelado, o «%s» no es un volumen LUKS válido).\n\nDetalle: %s' "$device" "$(head -c 300 "$errfile")")"
        ms_tmp_discard "$errfile"
        return 1
    fi
    ms_tmp_discard "$errfile"
    return 0
}

luks_header_matches_backup() {
    local device="$1" expected="$2" verify_tmp
    ms_mktemp verify_tmp "$expected.verify" || return 1
    if luks_header_stream "$device" > "$verify_tmp" 2>/dev/null \
        && [ -s "$verify_tmp" ] && cmp -s -- "$expected" "$verify_tmp"; then
        ms_tmp_discard "$verify_tmp"
        return 0
    fi
    ms_tmp_discard "$verify_tmp"
    return 1
}

# UUID of the LUKS header of the device or container "$1"; empty if it cannot
# be read. It is read directly when the user can open it (a container file,
# for instance) and, when that gives nothing, as root: a device only root can
# open (a /dev/sdXN) reads as empty to an unprivileged luksDump even when its
# header is healthy.
luks_device_uuid() {
    local uuid
    uuid=$(cryptsetup luksDump "$1" 2>/dev/null | awk '/^UUID:/{print $2; exit}')
    [ -n "$uuid" ] || uuid=$(prun cryptsetup luksDump "$1" 2>/dev/null | awk '/^UUID:/{print $2; exit}')
    printf '%s' "$uuid"
}

do_luks_header_restore() {
    local backup_file device file_uuid dev_uuid note typed errfile
    local pre_backup pre_tmp pre_errfile pre_uuid label ts
    pre_tmp=""

    if ! command -v cryptsetup >/dev/null 2>&1; then
        msg_error "$(T_FMT "cryptsetup no está instalado; no se puede restaurar el header.\n\nInstálalo con:\nsudo apt install cryptsetup")"
        return 1
    fi
    if ! command -v pkexec >/dev/null 2>&1; then
        msg_error "$(T "pkexec no está disponible; no se puede escribir en el dispositivo (requiere acceso root).")"
        return 1
    fi

    backup_file=$(LANGUAGE="$APP_LANG" zenity --file-selection --title="$(T "$APP_NAME - Elige la copia del header LUKS")" \
        --filename="$LUKS_HEADERS_DIR/" \
        --file-filter="$(T "Copias de header LUKS") | *.img" \
        --file-filter="$(T "Todos los archivos | *")" 2>/dev/null)
    [ -z "$backup_file" ] && return 0
    [ -f "$backup_file" ] || { msg_error "$(T "El archivo elegido no existe.")"; return 0; }

    device=$(luks_pick_device "$(T "⚠️ Elige el dispositivo DESTINO sobre el que se va a escribir este header.\nElegir el dispositivo equivocado puede volver ilegibles TODOS sus datos.")")
    [ -z "$device" ] && return 0
    [ -b "$device" ] || [ -f "$device" ] || { msg_error "$(T_FMT '«%s» no existe, o no es ni un dispositivo de bloques ni un archivo.' "$device")"; return 0; }

    # We validate the copy and compare UUIDs of the LUKS format itself.
    file_uuid=$(cryptsetup luksDump "$backup_file" 2>/dev/null | awk '/^UUID:/{print $2; exit}')
    dev_uuid=$(luks_device_uuid "$device")

    if [ -z "$file_uuid" ]; then
        note="$(T_FMT '\n\n⚠️ No se ha podido leer «%s» como una copia de header LUKS válida. Comprueba que has elegido el archivo correcto.' "$backup_file")"
    elif [ -z "$dev_uuid" ]; then
        note="$(T_FMT '\n\n⚠️ No se ha podido leer el UUID actual de %s (puede ser normal si su header está dañado, que es justo el caso que resuelve esta función). No se puede verificar automáticamente que esta copia pertenezca a este disco: continúa solo si estás seguro.' "$device")"
    elif [ "$file_uuid" != "$dev_uuid" ]; then
        note="$(T_FMT '\n\n🛑 AVISO: el UUID de la copia (%s) NO coincide con el de %s (%s). Restaurar el header de OTRO disco puede volver ilegibles TODOS los datos de este de forma permanente. Solo continúa si sabes exactamente lo que haces.' "$file_uuid" "$device" "$dev_uuid")"
    else
        note="$(T_FMT '\n\n✅ El UUID de la copia coincide con %s.' "$device")"
    fi

    if [ -b "$device" ] && lsblk -nrpo MOUNTPOINTS "$device" 2>/dev/null | grep -q '[^[:space:]]'; then
        note+="$(T_FMT '\n\n⚠️ %s parece estar actualmente montado o en uso. Desmóntalo antes de restaurar para evitar dejar el sistema de archivos a medias.' "$device")"
    fi

    local confirm_word
    if [ "$APP_LANG" = "en" ]; then
        confirm_word="RESTORE"
    else
        confirm_word="RESTAURAR"
    fi

    typed=$(LANGUAGE="$APP_LANG" zenity --entry --title="$(T "$APP_NAME - Confirmación requerida")" \
        --text="$(T_FMT 'Vas a SOBRESCRIBIR el header de cifrado de:\n%s\n\ncon la copia:\n%s%s\n\nEsto es una medida de EMERGENCIA (header dañado) y no se puede deshacer. Si el header actual todavía funciona, no continúes.\n\nEscribe %s para confirmar:' "$device" "$(basename "$backup_file")" "$note" "$confirm_word")" \
        --width=480 2>/dev/null)
    [ "$typed" = "$confirm_word" ] || { msg_info "$(T "Operación cancelada. No se ha modificado nada.")"; return 0; }

    # A readable header is kept before writing. If the restore fails or ends
    # up verified with a different UUID, this copy is used for rollback.
    pre_backup=""
    if [ -n "$dev_uuid" ]; then
        mkdir -p "$LUKS_HEADERS_DIR" || return 1
        if ! chmod 700 "$LUKS_HEADERS_DIR" 2>/dev/null; then
            msg_error "$(T_FMT 'No se pudo asegurar que la carpeta de copias de seguridad tenga permisos privados (700):\n%s\n\nComprueba los permisos o el tipo de sistema de archivos, o define otra carpeta en MINT_SETUP_BACKUPS_DIR.' "$LUKS_HEADERS_DIR")"
            return 1
        fi
        ts=$(date '+%Y%m%d-%H%M%S')
        label=$(printf '%s' "$(basename "$device")-$dev_uuid" | tr -c '[:alnum:]_-' '_')
        pre_backup="$LUKS_HEADERS_DIR/luks-header-recovery_${label}_${ts}.img"
        base_outfile="$pre_backup"
        name_seq=0
        while [ -e "$pre_backup" ] || [ -L "$pre_backup" ]; do
            name_seq=$((name_seq + 1))
            pre_backup="${base_outfile%.img}_${name_seq}.img"
        done
        pre_errfile=$(mktemp)
        if ! ms_mktemp pre_tmp "$pre_backup" || ! luks_header_stream "$device" > "$pre_tmp" 2>"$pre_errfile" \
            || [ ! -s "$pre_tmp" ] || ! ms_commit "$pre_tmp" "$pre_backup"; then
            note=$(head -c 300 "$pre_errfile")
            ms_tmp_discard "$pre_tmp"
            rm -f "$pre_errfile"
            msg_error "$(T_FMT 'No se pudo crear una copia de recuperación del header actual. No se escribirá nada en %s.\n\nDetalle: %s' "$device" "${note:-$(T "No se pudo crear el archivo temporal.")}")"
            return 1
        fi
        rm -f "$pre_errfile"
        pre_uuid=$(cryptsetup luksDump "$pre_backup" 2>/dev/null | awk '/^UUID:/{print $2; exit}')
        if [ "$pre_uuid" != "$dev_uuid" ]; then
            rm -f "$pre_backup"
            msg_error "$(T_FMT 'No se pudo crear una copia de recuperación del header actual. No se escribirá nada en %s.\n\nDetalle: %s' "$device" "$(T_FMT 'La copia de recuperación no coincide con el UUID esperado (%s); no se escribirá nada en el dispositivo.' "$dev_uuid")")"
            return 1
        fi
    fi

    errfile=$(mktemp)
    if prun cryptsetup -q luksHeaderRestore "$device" --header-backup-file "$backup_file" 2>"$errfile"; then
        # The device header read back as root equal to the copy already implies
        # its UUID; a luksDump without privileges reads nothing on a device only
        # root can open and would reject a correct restore.
        if [ -n "$file_uuid" ] && luks_header_matches_backup "$device" "$backup_file"; then
            [ -n "$pre_backup" ] && rm -f "$pre_backup"
            msg_info "$(T_FMT 'Header LUKS restaurado en %s.\n\nComprueba que el disco vuelve a desbloquearse con tu contraseña habitual.' "$device")"
            rm -f "$errfile"
            return 0
        else
            if [ -z "$pre_backup" ]; then
                # No recovery copy exists (the current UUID could not be read
                # before writing): nothing to put back and no path to show.
                msg_error "$(T_FMT 'La restauración no ha pasado la verificación posterior y no había copia de recuperación del header anterior, así que no se ha podido deshacer.\n\nComprueba si el disco se desbloquea con tu contraseña. Si no, restaura de nuevo la copia elegida u otra que tengas.')"
                rm -f "$errfile"
                return 1
            fi
            log_msg "$(T 'La restauración no ha pasado la verificación posterior. Se intentará recuperar automáticamente el header anterior.')"
            if prun cryptsetup -q luksHeaderRestore "$device" --header-backup-file "$pre_backup" >/dev/null 2>&1; then
                if luks_header_matches_backup "$device" "$pre_backup"; then
                    rm -f "$pre_backup"
                    msg_error "$(T 'El header anterior se ha recuperado correctamente. No se ha aplicado la copia seleccionada.')"
                else
                    msg_error "$(T_FMT 'Se ha conservado una copia de recuperación del header actual en: %s' "$pre_backup")"
                fi
            else
                msg_error "$(T_FMT 'Se ha conservado una copia de recuperación del header actual en: %s' "$pre_backup")"
            fi
            rm -f "$errfile"
            return 1
        fi
    else
        note=$(head -c 300 "$errfile")
        if [ -n "$pre_backup" ] && prun cryptsetup -q luksHeaderRestore "$device" --header-backup-file "$pre_backup" >/dev/null 2>&1; then
            if luks_header_matches_backup "$device" "$pre_backup"; then
                rm -f "$pre_backup"
                msg_error "$(T_FMT 'No se pudo restaurar el header (permisos denegados, cancelado, o error de cryptsetup).\n\nDetalle: %s' "${note:-$(T "No se pudo determinar el detalle del error.")}")\n\n$(T 'El header anterior se ha recuperado correctamente. No se ha aplicado la copia seleccionada.')"
            else
                msg_error "$(T_FMT 'No se pudo restaurar el header (permisos denegados, cancelado, o error de cryptsetup).\n\nDetalle: %s' "${note:-$(T "No se pudo determinar el detalle del error.")}")\n$(T_FMT 'Se ha conservado una copia de recuperación del header actual en: %s' "$pre_backup")"
            fi
        elif [ -n "$pre_backup" ]; then
            msg_error "$(T_FMT 'No se pudo restaurar el header (permisos denegados, cancelado, o error de cryptsetup).\n\nDetalle: %s' "${note:-$(T "No se pudo determinar el detalle del error.")}")\n$(T_FMT 'Se ha conservado una copia de recuperación del header actual en: %s' "$pre_backup")"
        else
            msg_error "$(T_FMT 'No se pudo restaurar el header (permisos denegados, cancelado, o error de cryptsetup).\n\nDetalle: %s' "${note:-$(T "No se pudo determinar el detalle del error.")}")"
        fi
        rm -f "$errfile"
        return 1
    fi
}

# =============================================================================
# GRAPHICAL INTERFACE: ADVANCED SETTINGS
# =============================================================================

# Deletes a saved copy for good. It can hold folders without write permission
# (copied from read-only media, say) whose content rm cannot delete, and a copy
# half deleted has lost its manifest.conf, so it can no longer be listed or
# deleted from the program: a real folder (never a link) is opened first.
# Fails (1) if anything was left; rm's own message is not shown. Used by the
# Advanced menu and by --uninstall --purge.
rm_backup_dir() {
    if [ -d "$1" ] && [ ! -L "$1" ]; then chmod -R u+rwX -- "$1" 2>/dev/null; fi
    rm -rf -- "$1" 2>/dev/null
}

do_advanced() {
    local choice targets t list failed n_ok

    # --text is mandatory: without it zenity writes its own text, translated with
    # the system locale instead of APP_LANG.
    choice=$(LANGUAGE="$APP_LANG" zenity --list --title="$(T "$APP_NAME - Avanzado")" \
        --text="$(T "¿Qué deseas hacer?")" \
        --width=460 --height=380 \
        --column="$(T "Op")" --column="$(T "Acción")" --hide-header \
        1 "$(T "📂  Abrir carpeta de configuraciones guardadas")" \
        2 "$(T "📤  Exportar copia a... (USB, disco externo...)")" \
        3 "$(T "🗑️  Eliminar configuraciones guardadas")" \
        4 "$(T "🔐  Copia de seguridad del header LUKS")" \
        5 "$(T "🚑  Restaurar header LUKS (emergencia)")" \
        6 "$(T "ℹ️  Acerca de $APP_NAME")" \
        2>/dev/null)

    case "$choice" in
        1)
            xdg-open "$BACKUPS_ROOT" >/dev/null 2>&1 &
            ;;
        2)
            do_export_backup
            ;;
        3)
            mapfile -t targets < <(pick_backup_dirs_multi "$(T "$APP_NAME - Eliminar")")
            [ ${#targets[@]} -eq 0 ] && return 0
            # One name per line: T_FMT expands "\n" in the format only, never in the data (%s).
            list=""
            for t in "${targets[@]}"; do list+="${list:+$'\n'}• $(basename "$t")"; done
            if confirm "$(T_FMT '¿Eliminar definitivamente estas %s configuración(es) guardada(s)?\n\n%s' "${#targets[@]}" "$list")"; then
                failed=""; n_ok=0
                for t in "${targets[@]}"; do
                    if rm_backup_dir "$t"; then n_ok=$((n_ok + 1)); else failed+="${failed:+$'\n'}• $(basename "$t")"; fi
                done
                if [ -z "$failed" ]; then
                    msg_info "$(T_FMT '%s configuración(es) eliminada(s).' "$n_ok")"
                else
                    msg_warn "$(T_FMT 'Se eliminaron %s de %s configuración(es). No se pudieron eliminar (sin permiso de escritura o disco de solo lectura):\n\n%s' "$n_ok" "${#targets[@]}" "$failed")"
                fi
            fi
            ;;
        4)
            do_luks_header_backup
            ;;
        5)
            do_luks_header_restore
            ;;
        6)
            local about_text
            about_text=$(T_FMT "<b>%s</b> v%s\nAutor: Filonux\n\nGuarda y restaura la configuración del entorno de escritorio en Linux Mint (Cinnamon): paneles, applets, apariencia, Nemo, aplicaciones instaladas, aplicaciones de inicio, pantallas, sonido, red, bluetooth, teclado, ratón y touchpad. También guarda la configuración propia de aplicaciones concretas: Firefox, LibreWolf, Thunderbird, LibreOffice, ONLYOFFICE, VS Code, Docker y la terminal.\n\nNo sustituye a Timeshift ni a MintBackup: los complementa.\n• Timeshift recupera el sistema.\n• MintBackup recupera archivos personales.\n• %s reconstruye el entorno de trabajo.\n\nLos módulos Red y Bluetooth piden permisos de administrador tanto al guardar como al restaurar, y pueden contener credenciales (contraseñas Wi-Fi, claves de emparejamiento). El módulo Docker los pide solo para la parte del daemon y el grupo docker.\n\nConfiguración avanzada añade copia de seguridad y restauración de emergencia del header LUKS de discos cifrados (también requiere administrador).\n\nLas configuraciones guardadas se almacenan en:\n%s" "$APP_NAME" "$APP_VERSION" "$APP_NAME" "$(markup_escape "$BACKUPS_ROOT")")
            LANGUAGE="$APP_LANG" zenity --info --title="$APP_NAME" \
                --text="$about_text" \
                --width=460 2>/dev/null
            ;;
    esac
}

# =============================================================================
# INSTALL AND UNINSTALL (current user only, no root)
# =============================================================================
# --install copies the program to ~/.local/bin, creates the menu launcher
# and its icon (embedded at the end of this section) and records everything
# in a manifest. --uninstall removes exactly what was recorded and only asks
# about what belongs to the user: their preferences and their saved copies.

ICON_SHA256="1144e76b102822b9ee0410d6e94233f185bc0b2a87dd897979758b1b553c64b5"
INSTALL_ID="mint-setup"
INSTALL_MARK="X-MintSetup-Managed=true"
INSTALL_FILES=(); INSTALL_SUMS=(); INSTALL_DIRS=()
INSTALL_NEW_FILES=(); INSTALL_NEW_DIRS=()

# Installation paths according to the current HOME and XDG_DATA_HOME.
install_paths() {
    local data="${XDG_DATA_HOME:-$HOME/.local/share}"
    INSTALL_BIN="$HOME/.local/bin/$INSTALL_ID"
    INSTALL_ICON="$data/icons/hicolor/256x256/apps/$INSTALL_ID.png"
    INSTALL_DESKTOP="$data/applications/$INSTALL_ID.desktop"
    INSTALL_STATE_DIR="$data/$INSTALL_ID"
    INSTALL_MANIFEST="$INSTALL_STATE_DIR/install.manifest"
}

# Succeeds if "$1" is an absolute path inside $HOME, without "." or "..", and different from $HOME.
install_path_is_safe() {
    case "$1" in
        "$HOME"/?*) ;;
        *) return 1 ;;
    esac
    case "/$1/" in */../*|*/./*) return 1 ;; esac
    return 0
}

# Succeeds if "$1" is one of the four files an install writes. Their paths come from
# XDG_DATA_HOME, so they may lie outside $HOME, where install_path_is_safe refuses everything.
install_target_is_own() {
    case "$1" in
        "$INSTALL_BIN"|"$INSTALL_ICON"|"$INSTALL_DESKTOP"|"$INSTALL_MANIFEST") return 0 ;;
    esac
    return 1
}

# Succeeds if "$1" is one of the four install folders or a parent of one, stopping at $HOME:
# the only folders an install can have created (outside $HOME, when XDG_DATA_HOME is).
install_dir_is_own() {
    local leaf p home="$HOME"
    while [ "${home%/}" != "$home" ]; do home="${home%/}"; done
    for leaf in "$(dirname -- "$INSTALL_BIN")" "$(dirname -- "$INSTALL_ICON")" \
                "$(dirname -- "$INSTALL_DESKTOP")" "$INSTALL_STATE_DIR"; do
        p="$leaf"
        while [ "$p" != / ] && [ "$p" != . ] && [ "$p" != "$home" ]; do
            [ "$p" = "$1" ] && return 0
            p=$(dirname -- "$p")
        done
    done
    return 1
}

cli_is_interactive() { [ -t 0 ] || [ "${MINT_SETUP_FORCE_INTERACTIVE:-0}" = 1 ]; }

# ask_yes_no "question" y|n: reads the answer; if unrecognizable, the default option applies.
ask_yes_no() {
    local prompt="$1" def="$2" ans=""
    printf '%s' "$prompt" >&2
    # read returns 1 on a last line with no newline but still sets ans: that answer counts.
    IFS= read -r ans || true
    # sí and SÍ as bytes: outside a UTF-8 locale [íÍ] matches one byte, not the letter.
    case "$ans" in
        [yYsS]|[yY][eE][sS]|[sS][iI]|[sS]$'\303\255'|[sS]$'\303\215') return 0 ;;
        [nN]|[nN][oO]) return 1 ;;
    esac
    [ "$def" = y ]
}

# Writes the embedded PNG to "$1" after checking its SHA-256.
icon_extract() {
    local dest="$1" tmp sum
    ms_mktemp tmp "$dest" || return 1
    if icon_png_b64 | base64 -d > "$tmp" 2>/dev/null \
        && sum=$(sha256sum -- "$tmp" | cut -d' ' -f1) && [ "$sum" = "$ICON_SHA256" ] \
        && chmod 644 -- "$tmp" && ms_commit "$tmp" "$dest"; then
        return 0
    fi
    ms_tmp_discard "$tmp"
    return 1
}

# Exec= value for the program path "$1": double-quoted when it holds any
# character the Desktop Entry specification reserves (space, tab and
# ' > < ~ | & ; * ? # ( )), left as is otherwise. do_install has already
# refused paths with \ " ` $ % or a newline, the ones that would need
# escaping inside the quotes, so no escaping is done here.
desktop_exec_quote() {
    case "$1" in
        *[[:space:]\'\>\<~\|\&\;\*\?\#\(\)]*) printf '"%s"' "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Launcher content; "$1" is the program path already quoted for Exec=
# (see desktop_exec_quote).
desktop_entry_text() {
    printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Version=1.0' "Name=$APP_NAME" \
        'GenericName=Configuration backup and restore' \
        'GenericName[es]=Copia y restauración de la configuración' \
        'Comment=Save and restore your Linux Mint configuration' \
        'Comment[es]=Guarda y restaura la configuración de tu Linux Mint' \
        "Exec=$1" "Icon=$INSTALL_ID" 'Terminal=false' 'Categories=System;Utility;' \
        'Keywords=backup;restore;settings;configuration;mint;copia;restaurar;' "$INSTALL_MARK"
}

# Creates "$1" and any missing parents (755) and records in INSTALL_NEW_DIRS those it creates.
# If mkdir fails halfway, the levels it did create are recorded too (so the rollback removes
# them) and its status is returned.
install_mkdir() {
    local p="$1" missing=() i rc=0
    while [ ! -d "$p" ] && [ "$p" != / ] && [ "$p" != . ]; do
        missing+=("$p")
        p=$(dirname -- "$p")
    done
    [ "${#missing[@]}" -eq 0 ] && return 0
    ( umask 022; mkdir -p -- "$1" ) || rc=$?
    for (( i = ${#missing[@]} - 1; i >= 0; i-- )); do
        [ -d "${missing[$i]}" ] && INSTALL_NEW_DIRS+=("${missing[$i]}")
    done
    return "$rc"
}

# Undoes what this run created (new files and new empty folders).
install_rollback() {
    local f i
    for f in ${INSTALL_NEW_FILES[@]+"${INSTALL_NEW_FILES[@]}"}; do rm -f -- "$f"; done
    for (( i = ${#INSTALL_NEW_DIRS[@]} - 1; i >= 0; i-- )); do rmdir -- "${INSTALL_NEW_DIRS[$i]}" 2>/dev/null || true; done
}

install_fail() {
    install_rollback
    printf '%s\n' "$(T_FMT 'Error: no se pudo instalar %s. Se ha deshecho lo creado hasta ahora.' "$APP_NAME")" >&2
}

# Reads the manifest (safe parser: never runs its content).
install_manifest_read() {
    INSTALL_FILES=(); INSTALL_SUMS=(); INSTALL_DIRS=()
    [ -f "$INSTALL_MANIFEST" ] || return 1
    local line rest sum value
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "F "*)
                rest="${line#F }"; sum="${rest%% *}"
                case "$sum" in ""|*[!0-9a-f]*) continue ;; esac
                manifest_decode_q value "${rest#* }" || continue
                INSTALL_FILES+=("$value"); INSTALL_SUMS+=("$sum") ;;
            "D "*)
                manifest_decode_q value "${line#D }" || continue
                INSTALL_DIRS+=("$value") ;;
        esac
    done < "$INSTALL_MANIFEST"
}

install_manifest_write() {
    local i d
    {
        printf 'VERSION=%q\n' "$APP_VERSION"
        for i in "${!INSTALL_FILES[@]}"; do printf 'F %s %q\n' "${INSTALL_SUMS[$i]}" "${INSTALL_FILES[$i]}"; done
        for d in ${INSTALL_DIRS[@]+"${INSTALL_DIRS[@]}"}; do printf 'D %q\n' "$d"; done
    } | atomic_write "$INSTALL_MANIFEST" 600
}

do_install() {
    local self dir exec_path sum f i d known invoke
    local -a old_dirs=()
    install_paths
    INSTALL_NEW_FILES=(); INSTALL_NEW_DIRS=()
    self=$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null) || self=""
    if [ -z "$self" ] || [ ! -f "$self" ]; then
        printf '%s\n' "$(T 'No se puede instalar: el script no es un archivo (¿se está ejecutando desde una tubería?). Descárgalo y ejecútalo desde el archivo.')" >&2
        return 1
    fi
    case "$INSTALL_BIN" in
        *[\\\"\`\$%]*|*$'\n'*)
            printf '%s\n' "$(T_FMT 'No se puede instalar: la ruta %s contiene caracteres no admitidos en un lanzador.' "$INSTALL_BIN")" >&2
            return 1 ;;
    esac
    if [ -e "$INSTALL_BIN" ] && ! grep -q '^APP_NAME="Mint-Setup"$' "$INSTALL_BIN" 2>/dev/null; then
        printf '%s\n' "$(T_FMT 'No se instala: %s ya existe y no es de este programa; no se sobrescribe.' "$INSTALL_BIN")" >&2
        return 1
    fi
    if [ -e "$INSTALL_DESKTOP" ] && ! grep -qx "$INSTALL_MARK" "$INSTALL_DESKTOP" 2>/dev/null; then
        printf '%s\n' "$(T_FMT 'No se instala: %s ya existe y no es de este programa; no se sobrescribe.' "$INSTALL_DESKTOP")" >&2
        return 1
    fi

    printf '%s\n' "$(T_FMT 'Instalando %s para tu usuario...' "$APP_NAME")"
    if install_manifest_read; then old_dirs=(${INSTALL_DIRS[@]+"${INSTALL_DIRS[@]}"}); fi
    for dir in "$(dirname -- "$INSTALL_BIN")" "$(dirname -- "$INSTALL_ICON")" "$(dirname -- "$INSTALL_DESKTOP")" "$INSTALL_STATE_DIR"; do
        install_mkdir "$dir" || { install_fail; return 1; }
    done

    if [ "$self" != "$INSTALL_BIN" ]; then
        [ -e "$INSTALL_BIN" ] || INSTALL_NEW_FILES+=("$INSTALL_BIN")
        atomic_copy "$self" "$INSTALL_BIN" 755 || { install_fail; return 1; }
    fi
    [ -e "$INSTALL_ICON" ] || INSTALL_NEW_FILES+=("$INSTALL_ICON")
    icon_extract "$INSTALL_ICON" || { install_fail; return 1; }
    exec_path=$(desktop_exec_quote "$INSTALL_BIN")
    [ -e "$INSTALL_DESKTOP" ] || INSTALL_NEW_FILES+=("$INSTALL_DESKTOP")
    desktop_entry_text "$exec_path" | atomic_write "$INSTALL_DESKTOP" 644 || { install_fail; return 1; }

    INSTALL_FILES=(); INSTALL_SUMS=()
    for f in "$INSTALL_BIN" "$INSTALL_ICON" "$INSTALL_DESKTOP"; do
        sum=$(sha256sum -- "$f" | cut -d' ' -f1) || { install_fail; return 1; }
        INSTALL_FILES+=("$f"); INSTALL_SUMS+=("$sum")
    done
    INSTALL_DIRS=(${old_dirs[@]+"${old_dirs[@]}"})
    for d in ${INSTALL_NEW_DIRS[@]+"${INSTALL_NEW_DIRS[@]}"}; do
        known=0
        for i in ${INSTALL_DIRS[@]+"${INSTALL_DIRS[@]}"}; do [ "$i" = "$d" ] && known=1; done
        [ "$known" -eq 1 ] || INSTALL_DIRS+=("$d")
    done
    install_manifest_write || { install_fail; return 1; }

    printf '  ✔ %s\n' "$(T_FMT 'Programa: %s' "$INSTALL_BIN")"
    printf '  ✔ %s\n' "$(T_FMT 'Lanzador: %s' "$INSTALL_DESKTOP")"
    printf '  ✔ %s\n' "$(T_FMT 'Icono: %s' "$INSTALL_ICON")"
    invoke="$INSTALL_BIN"
    case ":$PATH:" in *":$(dirname -- "$INSTALL_BIN"):"*) invoke="$INSTALL_ID" ;; esac
    printf '%s\n' "$(T_FMT 'Instalación completada. Búscalo en el menú de aplicaciones como «%s» o ejecuta: %s' "$APP_NAME" "$invoke")"
    case ":$PATH:" in
        *":$(dirname -- "$INSTALL_BIN"):"*) ;;
        *) printf '%s\n' "$(T_FMT 'Aviso: %s no está en tu PATH. Cierra la sesión y vuelve a entrar (o añádelo a tu PATH) para usar el comando; el lanzador del menú ya funciona.' "$(dirname -- "$INSTALL_BIN")")" ;;
    esac
    return 0
}

# Removes "$1" if it is a regular file of ours; "$2" is its SHA-256 ("-" = already verified by
# content). "$3" = trusted: path derived from our own environment (not from a manifest),
# so it may lie outside $HOME (XDG_CONFIG_HOME, XDG_RUNTIME_DIR...). The four install
# targets are accepted outside $HOME too (install_target_is_own).
# Fails (1) if the file could not be removed; it is named on stderr.
uninstall_file() {
    local f="$1" want="$2" have
    [ "${3:-}" = trusted ] || install_path_is_safe "$f" || install_target_is_own "$f" || return 0
    [ -L "$f" ] && return 0
    [ -f "$f" ] || return 0
    if [ "$want" != "-" ]; then
        have=$(sha256sum -- "$f" | cut -d' ' -f1)
        if [ "$have" != "$want" ]; then
            printf '  • %s\n' "$(T_FMT 'Conservado (lo has modificado tú): %s' "$f")"
            return 0
        fi
    fi
    if rm -f -- "$f" 2>/dev/null; then
        printf '  ✘ %s\n' "$(T_FMT 'Eliminado: %s' "$f")"
    else
        printf '  ! %s\n' "$(T_FMT 'No se pudo eliminar: %s' "$f")" >&2
        return 1
    fi
}

# Removes the recovery copies (*.mint-setup.bak*) recorded in the journal.
# Fails (1) if any of them could not be removed; the rest are still tried.
uninstall_recovery_copies() {
    local line f left=0
    [ -f "$RECOVERY_JOURNAL" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        manifest_decode_q f "$line" || continue
        case "$f" in *.mint-setup.bak|*.mint-setup.bak.[0-9]*) ;; *) continue ;; esac
        uninstall_file "$f" - || left=1
    done < "$RECOVERY_JOURNAL"
    return "$left"
}

# Deletes only recognizable backup folders (with manifest.conf); never other files.
# Fails (1) if any of them could not be deleted; each one is named on stderr.
uninstall_backups() {
    local d left=0
    [ -d "$BACKUPS_ROOT" ] || return 0
    for d in "$BACKUPS_ROOT"/*/; do
        [ -f "${d}manifest.conf" ] || continue
        if rm_backup_dir "${d%/}"; then
            printf '  ✘ %s\n' "$(T_FMT 'Eliminado: %s' "${d%/}")"
        else
            printf '  ! %s\n' "$(T_FMT 'No se pudo eliminar: %s' "${d%/}")" >&2
            left=1
        fi
    done
    rmdir -- "$BACKUPS_ROOT" 2>/dev/null || true
    return "$left"
}

do_uninstall() {
    local yes="$1" cfg="$2" i f d n_backups=0 size="" have_cfg=0 have_backups=0 sum cache
    local files_left=0 backups_left=0   # 1 = something could not be removed
    local -a dirs=()
    install_paths
    if ! install_manifest_read; then
        # No manifest (interrupted install): only known paths, and with proof they are ours.
        INSTALL_FILES=(); INSTALL_SUMS=(); INSTALL_DIRS=()
        if [ -f "$INSTALL_BIN" ] && grep -q '^APP_NAME="Mint-Setup"$' "$INSTALL_BIN" 2>/dev/null; then
            INSTALL_FILES+=("$INSTALL_BIN"); INSTALL_SUMS+=("-")
        fi
        if [ -f "$INSTALL_DESKTOP" ] && grep -qx "$INSTALL_MARK" "$INSTALL_DESKTOP" 2>/dev/null; then
            INSTALL_FILES+=("$INSTALL_DESKTOP"); INSTALL_SUMS+=("-")
        fi
        if [ -f "$INSTALL_ICON" ] && [ "$(sha256sum -- "$INSTALL_ICON" | cut -d' ' -f1)" = "$ICON_SHA256" ]; then
            INSTALL_FILES+=("$INSTALL_ICON"); INSTALL_SUMS+=("-")
        fi
        # The icon folders are claimed only once one of our files was recognised: with
        # nothing of ours on disk, empty ones may belong to other programs.
        if [ "${#INSTALL_FILES[@]}" -gt 0 ]; then
            INSTALL_DIRS=("$(dirname -- "$INSTALL_ICON")" "$(dirname -- "$(dirname -- "$INSTALL_ICON")")")
        fi
    fi

    [ -d "$LANGUAGE_CONFIG_DIR" ] && have_cfg=1
    if [ -d "$BACKUPS_ROOT" ]; then
        have_backups=1
        for d in "$BACKUPS_ROOT"/*/; do [ -f "${d}manifest.conf" ] && n_backups=$((n_backups + 1)); done
        size=$(du -sh -- "$BACKUPS_ROOT" 2>/dev/null | cut -f1)
    fi
    if [ "${#INSTALL_FILES[@]}" -eq 0 ]; then
        printf '%s\n' "$(T_FMT 'No hay nada que desinstalar: %s no está instalado.' "$APP_NAME")"
    fi

    if [ "$yes" -ne 1 ]; then
        if ! cli_is_interactive; then
            printf '%s\n' "$(T 'Esta acción es interactiva. Añade --yes para ejecutarla sin preguntas.')" >&2
            return 2
        fi
        ask_yes_no "$(T_FMT '¿Desinstalar %s de tu usuario? [s/N] ' "$APP_NAME")" n \
            || { printf '%s\n' "$(T 'Operación cancelada. No se ha modificado nada.')"; return 0; }
    fi

    # What to do with what belongs to the user (preferences and saved copies).
    if [ "$have_cfg" -eq 1 ] || [ "$have_backups" -eq 1 ]; then
        if [ -z "$cfg" ]; then
            if [ "$yes" -eq 1 ]; then
                cfg=keep
            else
                printf '%s\n' "$(T_FMT 'Tus configuraciones: preferencias en %s y %s copia(s) guardada(s) en %s (%s).' "$LANGUAGE_CONFIG_DIR" "$n_backups" "$BACKUPS_ROOT" "${size:-0}")"
                cfg=keep
                if ! ask_yes_no "$(T '¿Conservar tus preferencias y copias guardadas? [S/n] ')" y; then
                    ask_yes_no "$(T_FMT 'Se borrarán para siempre %s copia(s) y tus preferencias. ¿Seguro? [s/N] ' "$n_backups")" n && cfg=purge
                fi
            fi
        fi
    fi

    # With nothing installed the "nothing to uninstall" notice already went out.
    [ "${#INSTALL_FILES[@]}" -eq 0 ] || printf '%s\n' "$(T_FMT 'Desinstalando %s...' "$APP_NAME")"
    for i in "${!INSTALL_FILES[@]}"; do uninstall_file "${INSTALL_FILES[$i]}" "${INSTALL_SUMS[$i]}" || files_left=1; done
    uninstall_file "$INSTALL_MANIFEST" - || files_left=1
    # pkexec lock (ephemeral): in a graphical session it lives in XDG_RUNTIME_DIR; otherwise, in the cache.
    cache="${XDG_CACHE_HOME:-$HOME/.cache}/$INSTALL_ID"
    uninstall_file "$cache/.${APP_NAME}-pkexec.lock" - trusted || files_left=1
    rmdir -- "$cache" 2>/dev/null || true
    [ -z "${XDG_RUNTIME_DIR:-}" ] || uninstall_file "$XDG_RUNTIME_DIR/.${APP_NAME}-pkexec.lock" - trusted || files_left=1
    dirs=("$INSTALL_STATE_DIR" ${INSTALL_DIRS[@]+"${INSTALL_DIRS[@]}"})
    # Deepest first: a child always has a longer path than its parent.
    while IFS= read -r d; do
        { install_path_is_safe "$d" || install_dir_is_own "$d"; } && [ ! -L "$d" ] && rmdir -- "$d" 2>/dev/null
    done < <(for d in "${dirs[@]}"; do printf '%s\t%s\n' "${#d}" "$d"; done | sort -rn | cut -f2-)

    if [ "$cfg" = purge ]; then
        uninstall_recovery_copies || files_left=1
        uninstall_file "$RECOVERY_JOURNAL" - trusted || files_left=1
        uninstall_file "$LANGUAGE_CONFIG_FILE" - trusted || files_left=1
        rmdir -- "$LANGUAGE_CONFIG_DIR" 2>/dev/null || true
        uninstall_backups || backups_left=1
    fi
    if [ "$files_left" -eq 1 ] || [ "$backups_left" -eq 1 ]; then
        [ "$files_left" -eq 0 ] || printf '%s\n' "$(T 'Desinstalación incompleta: no se pudieron eliminar algunos archivos (sin permiso de escritura o disco de solo lectura). Bórralos a mano.')" >&2
        [ "$backups_left" -eq 0 ] || printf '%s\n' "$(T 'Desinstalación incompleta: no se pudieron eliminar algunas copias guardadas (sin permiso de escritura o disco de solo lectura). Bórralas a mano.')" >&2
        return 1
    fi

    if [ "$cfg" = purge ]; then
        # --purge never deletes the LuksHeaders folder (README): it must not say that
        # nothing is left while a header copy, which with the passphrase unlocks the
        # disk, is still there. A folder with no file in it holds nothing.
        if [ -n "$(ls -A -- "$LUKS_HEADERS_DIR" 2>/dev/null)" ]; then
            printf '%s\n' "$(T 'Desinstalación completada. Se han conservado tus copias del header LUKS (--purge no las borra):')"
            printf '  • %s\n' "$(T_FMT 'Conservado: %s' "$LUKS_HEADERS_DIR")"
        else
            printf '%s\n' "$(T_FMT 'Desinstalación completada. No queda ningún archivo de %s.' "$APP_NAME")"
        fi
    elif [ "$have_cfg" -eq 1 ] || [ "$have_backups" -eq 1 ]; then
        printf '%s\n' "$(T 'Desinstalación completada. Se han conservado tus configuraciones:')"
        [ "$have_cfg" -eq 1 ] && printf '  • %s\n' "$(T_FMT 'Conservado: %s' "$LANGUAGE_CONFIG_DIR")"
        [ "$have_backups" -eq 1 ] && printf '  • %s\n' "$(T_FMT 'Conservado: %s' "$BACKUPS_ROOT")"
    else
        printf '%s\n' "$(T_FMT 'Desinstalación completada. No queda ningún archivo de %s.' "$APP_NAME")"
    fi
    return 0
}

print_usage() {
    printf '%s\n' "$(T 'Uso: mint-setup.sh [opciones]')"
    printf '  %-22s %s\n' "$(T '(sin opciones)')" "$(T 'abre el programa')"
    printf '  %-22s %s\n' '--install' "$(T 'instala para tu usuario: menú, icono y comando')"
    printf '  %-22s %s\n' '--uninstall' "$(T 'desinstala; pregunta si conservar tus configuraciones')"
    printf '  %-22s %s\n' '--yes, -y' "$(T 'no pregunta (con --uninstall conserva tus configuraciones)')"
    printf '  %-22s %s\n' '--keep-config' "$(T 'con --uninstall: conserva preferencias y copias')"
    printf '  %-22s %s\n' '--purge' "$(T 'con --uninstall: borra también preferencias y copias')"
    printf '  %-22s %s\n' '-l, --toggle-language' "$(T 'cambia el idioma')"
    printf '  %-22s %s\n' '--version' "$(T 'muestra la versión')"
    printf '  %-22s %s\n' '-h, --help' "$(T 'muestra esta ayuda')"
}

# Command-line actions (--install, --uninstall, --help). Exits if it runs one.
run_cli_action() {
    local cfg_mode rc
    cli_parse_args "$@"
    case "$CLI_ERR" in
        unknown)
            printf '%s\n' "$(T_FMT 'Opción desconocida: %s' "$CLI_ERR_ARG")" >&2
            print_usage >&2
            exit 2 ;;
        both_actions)
            printf '%s\n' "$(T '--install y --uninstall no se pueden usar juntos.')" >&2
            exit 2 ;;
        keep_purge)
            printf '%s\n' "$(T '--purge y --keep-config no se pueden usar juntos.')" >&2
            exit 2 ;;
        only_uninstall)
            printf '%s\n' "$(T 'Estas opciones solo se usan con --uninstall.')" >&2
            exit 2 ;;
    esac
    if [ "$CLI_HELP" -eq 1 ]; then print_usage; exit 0; fi
    case "$CLI_ACTION" in
        install) do_install; exit $? ;;
        uninstall)
            cfg_mode=""
            if [ "$CLI_PURGE" -eq 1 ]; then cfg_mode=purge; elif [ "$CLI_KEEP" -eq 1 ]; then cfg_mode=keep; fi
            do_uninstall "$CLI_YES" "$cfg_mode"
            rc=$?
            exit "$rc" ;;
    esac
    return 0
}

# --- Embedded icon (256x256 PNG, base64; SHA-256 in ICON_SHA256) --------------
icon_png_b64() {
    cat <<'ICON_PNG_B64'
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
RU5ErkJggg==
ICON_PNG_B64
}

# =============================================================================
# MAIN PROGRAM
# =============================================================================

if [ "${MINT_SETUP_TEST:-0}" != "1" ]; then
    run_cli_action "$@"
fi
# Only whoever is going to use the copies gets here: run_cli_action already
# exited on --help, --install, --uninstall and on rejected command lines.
# The dependencies are checked before creating the folder: a run that fails
# for lack of tools does not leave it created. In test mode (the script is
# loaded as a library) they are not checked and the folder is created here.
if [ "${MINT_SETUP_TEST:-0}" != "1" ]; then
    check_dependencies
fi
ensure_backups_root || exit 1

main_menu() {
    local choice rc desktop_note=""
    if ! is_cinnamon_desktop; then
        desktop_note="\n$(T_FMT 'Escritorio detectado: %s (los módulos de Cinnamon y Nemo pueden no aplicarse aquí)' "$(markup_escape "${XDG_CURRENT_DESKTOP:-$PLATFORM_DESKTOP}")")"
    fi
    while true; do
        choice=$(LANGUAGE="$APP_LANG" zenity --list \
            --title="$APP_NAME" \
            --text="<b>$APP_NAME</b>\n$(T "¿Qué deseas hacer?")\n$(T "Idioma actual"): ${APP_LANG^^} · L = $(T "Cambiar idioma")${desktop_note}" \
            --width=440 --height=340 \
            --column="$(T "Op")" --column="$(T "Acción")" --hide-header \
            1 "$(T "💾  Guardar configuración")" \
            2 "$(T "♻️  Restaurar configuración")" \
            3 "$(T "🔍  Comparar configuración")" \
            4 "$(T "⚙️  Configuración avanzada")" \
            5 "$(T "🚪  Salir")" \
            L "$(T "🌐  Cambiar idioma")" \
            2>/dev/null)
        rc=$?

        # Zenity returns 1 and empty output both when Cancel is pressed and
        # when it cannot open the display. Without a graphical session nobody
        # can answer: a warning is given and it exits with 1, instead of
        # ending silently with 0 as if Exit had been chosen.
        if [ -z "$choice" ] && [ "$rc" -ne 0 ] \
            && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
            printf '%s\n' "$(T "No se pudo abrir el menú: no hay sesión gráfica (DISPLAY y WAYLAND_DISPLAY no están definidas). Ejecútalo desde el escritorio.")" >&2
            exit 1
        fi

        case "$choice" in
            1) do_save ;;
            2) do_restore ;;
            3) do_compare ;;
            4) do_advanced ;;
            l|L) toggle_language || warn_language_not_saved ;;
            5|"") exit 0 ;;
        esac
    done
}

if [ "${MINT_SETUP_TEST:-0}" != "1" ]; then
    main_menu
fi
