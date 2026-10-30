#!/bin/bash
# shellcheck disable=SC2016  # bash -c payloads are intentionally single-quoted
set -euo pipefail
umask 022   # fixture modes must not depend on the contributor's umask

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/script/mint-setup.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Own HOME and backups folder, and no real runtime/cache folder: the program creates
# ~/.cache/mint-setup, its pkexec lock and ~/MintSetupBackups when it runs.
unset XDG_RUNTIME_DIR XDG_CACHE_HOME
mkdir -p "$TMP/home"
export HOME="$TMP/home" MINT_SETUP_BACKUPS_DIR="$TMP/backups"

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() {
    [ "$1" = "$2" ] || fail "$3 (expected '$2', got '$1')"
}

bash -n "$SCRIPT"
pass "shell syntax"

EXPECTED_VERSION="$(sed -n 's/^APP_VERSION="\([0-9][0-9.]*\)"$/\1/p' "$SCRIPT")"
[[ "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "APP_VERSION is missing or not semantic (got '$EXPECTED_VERSION')"
version="$(bash "$SCRIPT" --version)"
assert_eq "$version" "Mint-Setup $EXPECTED_VERSION" "--version matches APP_VERSION"
pass "--version"

# --version must stay independent of the translation catalog.
mkdir -p "$TMP/version-only"
cp "$SCRIPT" "$TMP/version-only/mint-setup.sh"
chmod +x "$TMP/version-only/mint-setup.sh"
assert_eq "$("$TMP/version-only/mint-setup.sh" --version)" "Mint-Setup $EXPECTED_VERSION" "--version without language catalog"
pass "version path isolation"

expected_modules="desktop appearance nemo software startup displays sound network bluetooth keyboard mouse touchpad firefox librewolf thunderbird libreoffice onlyoffice vscode docker terminal"
result="$(MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/config" LC_ALL=C LANG=C bash -c 'source "$1"; printf "%s\n" "${MODULE_KEYS[*]}"' _ "$SCRIPT")"
assert_eq "$result" "$expected_modules" "module keys unchanged"
pass "module keys"

for f in $expected_modules; do
    if ! MINT_SETUP_TEST=1 bash -c 'source "$1"; declare -F "save_$2" >/dev/null && declare -F "restore_$2" >/dev/null' _ "$SCRIPT" "$f"; then
        fail "missing save/restore function for $f"
    fi
done
pass "save/restore functions"

detect() {
    local cfg="$TMP/config-$1"
    rm -rf "$cfg"
    mkdir -p "$cfg"
    MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$cfg" "$2" bash -c '
        source "$1"
        printf "%s\n" "$APP_LANG"
    ' _ "$SCRIPT"
}

# Locale precedence: LC_ALL > LC_MESSAGES > LANGUAGE > LANG.
a="$(env -u LANGUAGE LC_ALL=es_ES.UTF-8 LC_MESSAGES=en_US.UTF-8 LANG=en_US.UTF-8 MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/d1" bash -c 'source "$1"; printf "%s\n" "$APP_LANG"' _ "$SCRIPT" 2>/dev/null)"
assert_eq "$a" "es" "LC_ALL Spanish detection"
b="$(env -u LANGUAGE LC_ALL=C LC_MESSAGES=es_ES.UTF-8 LANG=en_US.UTF-8 MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/d2" bash -c 'source "$1"; printf "%s\n" "$APP_LANG"' _ "$SCRIPT" 2>/dev/null)"
assert_eq "$b" "en" "LC_ALL precedence"
c="$(env -u LC_ALL LANG=en_US.UTF-8 LC_MESSAGES=en_US.UTF-8 LANGUAGE=es:en MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/d3" bash -c 'source "$1"; printf "%s\n" "$APP_LANG"' _ "$SCRIPT" 2>/dev/null)"
assert_eq "$c" "en" "LANGUAGE does not override LC_MESSAGES"
d="$(env -u LC_ALL LC_MESSAGES=es_ES.UTF-8 LANG=en_US.UTF-8 LANGUAGE=es:en MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/d4" bash -c 'source "$1"; printf "%s\n" "$APP_LANG"' _ "$SCRIPT" 2>/dev/null)"
assert_eq "$d" "es" "LC_MESSAGES Spanish detection"
e="$(env -u LC_ALL LC_MESSAGES=en_US.UTF-8 LANG=en_US.UTF-8 LANGUAGE=es:en MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/d5" bash -c 'source "$1"; printf "%s\n" "$APP_LANG"' _ "$SCRIPT" 2>/dev/null)"
assert_eq "$e" "en" "English default"
f="$(env -u LC_ALL -u LC_MESSAGES LANG=en_US.UTF-8 LANGUAGE=es:en MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/d6" bash -c 'source "$1"; printf "%s\n" "$APP_LANG"' _ "$SCRIPT" 2>/dev/null)"
assert_eq "$f" "es" "GNU LANGUAGE preference when LC_MESSAGES is unset"
pass "locale detection"

cfg="$TMP/persist"
mkdir -p "$cfg"
out="$(MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$cfg" LANG=en_US.UTF-8 bash -c 'source "$1"; printf "%s\n" "$APP_LANG"; set_language es; printf "%s\n" "$APP_LANG"' _ "$SCRIPT" 2>/dev/null)"
assert_eq "$(printf '%s\n' "$out" | sed -n '1p')" "en" "initial persisted test language"
assert_eq "$(printf '%s\n' "$out" | sed -n '2p')" "es" "set_language"
out2="$(MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$cfg" LANG=en_US.UTF-8 bash -c 'source "$1"; printf "%s\n" "$APP_LANG"; toggle_language; printf "%s\n" "$APP_LANG"' _ "$SCRIPT" 2>/dev/null)"
assert_eq "$(printf '%s\n' "$out2" | sed -n '1p')" "es" "language persistence"
assert_eq "$(printf '%s\n' "$out2" | sed -n '2p')" "en" "toggle_language"
pass "language persistence and toggle"

# An invalid saved value must be ignored and locale detection used again.
printf '%s\n' 'fr' > "$cfg/mint-setup/language"
invalid="$(env LC_ALL=es_ES.UTF-8 MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$cfg" bash -c 'source "$1"; printf "%s\n" "$APP_LANG"' _ "$SCRIPT" 2>/dev/null)"
assert_eq "$invalid" "es" "invalid saved language fallback"
[ "$(stat -c '%a' "$cfg/mint-setup")" = "700" ] || fail "language config directory permissions"
[ "$(stat -c '%a' "$cfg/mint-setup/language")" = "600" ] || fail "language config file permissions"
pass "invalid language fallback and permissions"

# 12.47: the saved language is the first line of the file and counts even without a
# final newline (read returns 1 for it but still sets the value); anything else falls
# back to the locale. Each case runs under a locale that contradicts the saved value, and
# stderr is part of the output: a read error must not leak.
saved_lang() {   # saved_lang 'content (printf %b)' LC_ALL
    local c="$TMP/saved-lang"
    rm -rf "$c"; mkdir -p "$c/mint-setup"
    printf '%b' "$1" > "$c/mint-setup/language"
    LC_ALL="$2" MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$c" bash -c 'source "$1"; printf "%s" "$APP_LANG"' _ "$SCRIPT" 2>&1
}
assert_eq "$(saved_lang 'en' es_ES.UTF-8)" "en" "saved language without final newline (en)"
assert_eq "$(saved_lang 'es' en_US.UTF-8)" "es" "saved language without final newline (es)"
assert_eq "$(saved_lang 'en\n' es_ES.UTF-8)" "en" "saved language with final newline"
assert_eq "$(saved_lang '  es  ' en_US.UTF-8)" "es" "saved language with spaces and no final newline"
assert_eq "$(saved_lang 'es\nen\n' en_US.UTF-8)" "es" "only the first line of the saved language counts"
assert_eq "$(saved_lang '' es_ES.UTF-8)" "es" "empty saved language falls back to the locale"
assert_eq "$(saved_lang 'fr' es_ES.UTF-8)" "es" "invalid saved language without final newline falls back (es)"
assert_eq "$(saved_lang 'fr' en_US.UTF-8)" "en" "invalid saved language without final newline falls back (en)"
if [ "$(id -u)" -ne 0 ]; then   # root reads any file
    saved_lang 'en\n' es_ES.UTF-8 >/dev/null
    chmod 000 "$TMP/saved-lang/mint-setup/language"
    unreadable=$(LC_ALL=es_ES.UTF-8 MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/saved-lang" bash -c 'source "$1"; printf "%s" "$APP_LANG"' _ "$SCRIPT" 2>&1)
    assert_eq "$unreadable" "es" "unreadable saved language: locale fallback and no error text"
else
    printf 'SKIP: unreadable saved language (root reads any file)\n'
fi
pass "saved language: no final newline, first line only, unreadable file"

# CLI toggle must persist without starting dependency checks or the GUI in test mode.
cli_cfg="$TMP/cli-toggle"
MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$cli_cfg" LC_ALL=C bash "$SCRIPT" --toggle-language 2>/dev/null
[ "$(cat "$cli_cfg/mint-setup/language")" = "es" ] || fail "CLI toggle did not persist Spanish"
MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$cli_cfg" LC_ALL=C bash "$SCRIPT" --toggle-language 2>/dev/null
[ "$(cat "$cli_cfg/mint-setup/language")" = "en" ] || fail "CLI toggle did not persist English"
pass "CLI language toggle"

# Running as root must be rejected before any language setting is written.
if [ "$(id -u)" -eq 0 ]; then
    root_cfg="$TMP/root-guard"
    mkdir -p "$root_cfg"
    if MINT_SETUP_TEST=0 XDG_CONFIG_HOME="$root_cfg" LC_ALL=C bash "$SCRIPT" --toggle-language >/dev/null 2>&1; then
        fail "root guard allowed the script to continue"
    fi
    [ ! -e "$root_cfg/mint-setup/language" ] || fail "root guard wrote the language setting"
    pass "root guard precedes language toggle"
fi

translation="$(MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/translation" bash -c '
source "$1"
APP_LANG=en
printf "%s\n" \
  "$(T "¿Qué deseas hacer?")" \
  "$(T "💾  Guardar configuración")" \
  "$(T "⚙️  Configuración avanzada")" \
  "$(T_FMT "Aplicaciones guardadas (%s paquetes APT)." 12)" \
  "$(T "Restaurando repositorios adicionales (se pedirá contraseña de administrador)...")" \
  "$(T "Guardando configuración de Docker CLI del usuario (contexts, config.json)...")"
' _ "$SCRIPT")"
printf '%s\n' "$translation" | grep -Fqx "What do you want to do?"
printf '%s\n' "$translation" | grep -Fqx "💾  Save configuration"
printf '%s\n' "$translation" | grep -Fqx "⚙️  Advanced settings"
printf '%s\n' "$translation" | grep -Fqx "APT packages saved: 12."
printf '%s\n' "$translation" | grep -Fqx "Restoring additional repositories (you will be prompted for the administrator password)..."
printf '%s\n' "$translation" | grep -Fqx "Saving user Docker CLI configuration (contexts, config.json)..."
pass "translation catalog"

# High-risk dynamic notices and progress suffixes must translate without changing variable data.
dynamic="$(MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/dynamic" bash -c '
source "$1"
APP_LANG=en
cred_warn="$(T "⚠️ Esta copia incluirá datos sensibles:")"
cred_warn+="\n$(T "• Red — contraseñas Wi-Fi en texto plano")"
cred_warn+="\n$(T "• Bluetooth — claves de emparejamiento de tus dispositivos")"
cred_warn+="\n$(T "• Docker — posibles credenciales de registro en base64")"
cred_warn+="\n$(T "• Thunderbird — contraseñas de tus cuentas de correo")"
cred_warn+="\n$(T "• Firefox — contraseñas guardadas en el navegador")"
cred_warn+="\n$(T "• LibreWolf — contraseñas guardadas en el navegador")"
cred_warn+="\n\n$(T "Las contraseñas de navegador/correo solo van cifradas si usas una contraseña principal.") $(T "Protege bien ~/MintSetupBackups.")"
cred_warn+="\n\n$(T "Se te pedirá la contraseña de administrador varias veces, una por cada operación que la necesite.")"
printf "%s\n" "$cred_warn"
printf "%s\n" "$(T_FMT "Se va a copiar el header LUKS de:\n%s\n\na:\n%s\n\n(y un volcado de texto con sus metadatos, por si este archivo se corrompiera)\n\nSe te pedirá la contraseña de administrador. ¿Continuar?" /dev/sdb1 /tmp/luks.img)"
printf "%s\n" "$(T "¿Qué deseas restaurar?")"
printf "%s\n" "$(T " · quedan %s")"
' _ "$SCRIPT")"
grep -Fq "Network — Wi-Fi passwords in plain text" <<<"$dynamic"
grep -Fq "Bluetooth — pairing keys for your devices" <<<"$dynamic"
grep -Fq "Browser/email passwords are only encrypted when you use a Primary Password." <<<"$dynamic"
grep -Fq "LUKS header will be copied from:" <<<"$dynamic"
grep -Fq "Continue?" <<<"$dynamic"
grep -Fq "What do you want to restore?" <<<"$dynamic"
grep -Fq " · %s left" <<<"$dynamic"
pass "dynamic and high-risk message translation"
about_key="$(MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/about-translation" bash -c '\
source "$1"; printf "%s\n" "${!T_EXACT[@]}"' _ "$SCRIPT" | grep -F '<b>%s</b> v%s' | head -1)"
[ -n "$about_key" ] || fail "About catalog entry missing"
about_path="$TMP/about-backups"
about_translation="$(MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/about-translation" bash -c '\
source "$1"; APP_LANG=en; T_FMT "$2" Mint-Setup 3.0.0 Mint-Setup "$3"' _ "$SCRIPT" "$about_key" "$about_path")"
grep -Fq 'Saves and restores the desktop environment configuration on Linux Mint (Cinnamon):' <<<"$about_translation" || fail "English About text translation"
grep -Fq 'Saved configurations are stored in:' <<<"$about_translation" || fail "English About storage text translation"
grep -Fq "$about_path" <<<"$about_translation" || fail "About path placeholder"
pass "About text translation"


# Dynamic UI strings must translate even when runtime values change.
dynamic_runtime="$(MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/dynamic-runtime" bash -c '
source "$1"
APP_LANG=en
printf "%s\n" "$(T_FMT "Faltan herramientas necesarias para ejecutar %s:\n%s\n\nInstálalas con:\n%s" Mint-Setup "zenity dconf" "sudo apt install zenity dconf")"
printf "%s\n" "$(T_FMT "Exportando copia a:\n%s" "/media/test USB")"
' _ "$SCRIPT")"
grep -Fq "Required tools are missing to run Mint-Setup:" <<<"$dynamic_runtime"
grep -Fq "Install them with:" <<<"$dynamic_runtime"
grep -Fq "Exporting backup to:" <<<"$dynamic_runtime"
grep -Fq "/media/test USB" <<<"$dynamic_runtime"
pass "dynamic runtime UI translation"
size_fallback="$(MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/size-fallback" bash -c '\
source "$1"; APP_LANG=en; T "tamaño desconocido"' _ "$SCRIPT")"
assert_eq "$size_fallback" "unknown size" "English size fallback translation"
pass "dynamic backup size translation"


# Escaped shell variables in translated notices must stay literal and translatable.
docker_hint="$(MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/docker-hint" bash -c '\
source "$1"; set_language en; log_msg "Aviso: pkexec no está disponible; añádete al grupo manualmente con: sudo usermod -aG docker \$USER"\
' _ "$SCRIPT")"
grep -Fqx 'Warning: pkexec is not available; add yourself to the group manually with: sudo usermod -aG docker $USER' <<<"$docker_hint" \
    || fail "English Docker group fallback translation"
pass "escaped shell-variable translation"

# Empty text must print nothing, on stdout or stderr, in both languages. Bash
# 5.2 rejects an empty associative subscript, so T() printed "bad array
# subscript" for every empty text in English (Compare passed two of them).
# log_msg "" must still print exactly one newline.
for lang in es en; do
    MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/t-empty" LC_ALL=C.UTF-8 bash -c '
        source "$1"; APP_LANG=$2; T "" && T_FMT "" && log_msg ""' _ "$SCRIPT" "$lang" \
        >"$TMP/t-empty.out" 2>"$TMP/t-empty.err" || fail "empty text made T fail ($lang)"
    printf '\n' | cmp -s - "$TMP/t-empty.out" || fail "empty text printed more than log_msg's newline ($lang)"
    [ ! -s "$TMP/t-empty.err" ] || fail "empty text printed an error ($lang): $(head -c 200 "$TMP/t-empty.err")"
done
pass "empty text through T prints nothing in ES and EN"

# Texts that look like array syntax, printf formats or shell code are data: they
# come back unchanged (none is in the catalog) in both languages, with no error
# and no side effect.
mkdir -p "$TMP/t-keys"
keys=('@' '*' ']' '[' 'a]' '[a' ' ' '-' '--' '%' '%s' 'a\nb' '$(touch pwned)' '`touch pwned`' 'a[$(touch pwned)]')
for lang in es en; do
    mapfile -d '' -t got < <(cd "$TMP/t-keys" && MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/t-keys-cfg" LC_ALL=C.UTF-8 bash -c '
        source "$1"; APP_LANG=$2; shift 2
        for t in "$@"; do printf "%s\0" "$(T "$t")"; done' _ "$SCRIPT" "$lang" "${keys[@]}" 2>"$TMP/t-keys.err")
    [ "${#got[@]}" -eq "${#keys[@]}" ] || fail "T answered ${#got[@]} of ${#keys[@]} odd texts ($lang)"
    for i in "${!keys[@]}"; do
        [ "${got[$i]}" = "${keys[$i]}" ] || fail "T changed the text '${keys[$i]}' into '${got[$i]}' ($lang)"
    done
    [ ! -s "$TMP/t-keys.err" ] || fail "T printed an error for an odd text ($lang): $(head -c 200 "$TMP/t-keys.err")"
    [ -z "$(ls -A "$TMP/t-keys")" ] || fail "T ran code taken from a text ($lang)"
done
pass "texts that look like array syntax, printf formats or code stay literal"

# Every catalog entry must preserve the same number of printf placeholders.
placeholder_status=0
while IFS=$'\t' read -r src en; do
    [ -n "$src" ] || continue
    src_n=$(grep -o '%s' <<<"$src" | wc -l)
    en_n=$(grep -o '%s' <<<"$en" | wc -l)
    if [ "$src_n" -ne "$en_n" ]; then
        printf 'Placeholder mismatch: %s => %s\n' "$src" "$en" >&2
        placeholder_status=1
    fi
done < <(for key in "${!T_EXACT[@]}"; do printf '%s\t%s\n' "$key" "${T_EXACT[$key]}"; done)
[ "$placeholder_status" -eq 0 ] || fail "catalog placeholder parity"
pass "catalog placeholder parity"
entry_count=$(grep -c '^add_exact ' "$SCRIPT")
# shellcheck source=../script/mint-setup.sh
unique_count="$(MINT_SETUP_TEST=1 source "$SCRIPT" 2>/dev/null; printf "%s" "${#T_EXACT[@]}")"
assert_eq "$unique_count" "$entry_count" "catalog has no duplicate keys"
pass "catalog key uniqueness"

# Exercise the real LUKS restore function with mocked external commands.
LUKS_MOCKBIN="$TMP/luks-mockbin"
mkdir -p "$LUKS_MOCKBIN"
cat > "$LUKS_MOCKBIN/zenity" <<'ZENITY_LUKS'
#!/bin/bash
printf '%s\n' "$*" >> "${ZENITY_LOG:?}"
case "$*" in
  *--file-selection*) printf '%s\n' "$ZENITY_BACKUP" ;;
  *--list*) printf '%s\n' "$ZENITY_DEVICE" ;;
  *--entry*) printf '%s\n' "$ZENITY_TYPED" ;;
esac
exit 0
ZENITY_LUKS
# cryptsetup stand-in that keeps the behaviours the program depends on: the
# "header" of a device (or file) is its content, luksHeaderBackup refuses to
# write over an existing file (as the real tool does) and creates it 0400.
cat > "$LUKS_MOCKBIN/cryptsetup" <<'CRYPT_LUKS'
#!/bin/bash
action=""; dev=""; file=""
while [ $# -gt 0 ]; do
    case "$1" in
        luksDump|luksHeaderBackup|luksHeaderRestore) action="$1"; dev="${2:-}"; shift ;;
        --header-backup-file) file="${2:-}"; shift ;;
    esac
    shift
done
case "$action" in
    luksDump) printf 'UUID: test-uuid\n' ;;
    luksHeaderBackup)
        if [ -e "$file" ] || [ -L "$file" ]; then
            printf 'Requested header backup file %s already exists.\n' "$file" >&2; exit 1
        fi
        ( umask 277; cat -- "$dev" > "$file" ) ;;
    luksHeaderRestore) cat -- "$file" > "$dev" ;;
esac
exit 0
CRYPT_LUKS
cat > "$LUKS_MOCKBIN/pkexec" <<'PKEXEC_LUKS'
#!/bin/bash
[ "${1:-}" = --disable-internal-agent ] && shift   # prun adds it; the real pkexec consumes it
exec "$@"
PKEXEC_LUKS
cat > "$LUKS_MOCKBIN/lsblk" <<'LSBLK_LUKS'
#!/bin/bash
case "$*" in
  *'-prno NAME,TYPE,FSTYPE,SIZE,UUID'*) printf '%s\n' "$ZENITY_DEVICE block crypto_LUKS 1G test-uuid" ;;
  *'-no UUID'*) printf 'test-uuid\n' ;;
  *'-rno PKNAME,TYPE'*) : ;;
esac
exit 0
LSBLK_LUKS
chmod +x "$LUKS_MOCKBIN"/*
LUKS_DEVICE="$TMP/luks-device"
LUKS_BACKUP="$TMP/luks-backup.img"
printf 'CURRENT-HEADER\n' > "$LUKS_DEVICE"
printf 'BACKUP-HEADER\n' > "$LUKS_BACKUP"
for lang in en es; do
    log="$TMP/luks-$lang.log"
    if [ "$lang" = en ]; then typed=RESTORE; else typed=RESTAURAR; fi
    XDG_CONFIG_HOME="$TMP/luks-config-$lang" MINT_SETUP_TEST=1 LC_ALL=C \
    PATH="$LUKS_MOCKBIN:$PATH" ZENITY_LOG="$log" ZENITY_TYPED="$typed" \
    ZENITY_BACKUP="$LUKS_BACKUP" ZENITY_DEVICE="$LUKS_DEVICE" \
    bash -c 'source "$1"; set_language "$2"; do_luks_header_restore' _ "$SCRIPT" "$lang"
    if [ "$lang" = en ]; then
        grep -Fq 'Type RESTORE to confirm:' "$log" || fail "English LUKS confirmation token"
        grep -Fq 'LUKS header restored to' "$log" || fail "English LUKS restore result"
    else
        grep -Fq 'Escribe RESTAURAR para confirmar:' "$log" || fail "Spanish LUKS confirmation token"
        grep -Fq 'Header LUKS restaurado en' "$log" || fail "Spanish LUKS restore result"
    fi
done
pass "LUKS restore language integration"

# Manual LUKS device path must keep a stable semantic value in both languages.
manual_log="$TMP/luks-manual-en.log"
cat > "$LUKS_MOCKBIN/zenity" <<'ZENITY_LUKS_MANUAL'
#!/bin/bash
printf '%s\n' "$*" >> "${ZENITY_LOG:?}"
case "$*" in
  *--list*) printf 'Other...\n' ;;
  *--entry*) printf '%s\n' "$ZENITY_TYPED" ;;
esac
exit 0
ZENITY_LUKS_MANUAL
chmod +x "$LUKS_MOCKBIN/zenity"
manual_device="$(XDG_CONFIG_HOME="$TMP/luks-manual-config" MINT_SETUP_TEST=1 LC_ALL=C \
    PATH="$LUKS_MOCKBIN:$PATH" ZENITY_LOG="$manual_log" ZENITY_TYPED="/dev/test-luks" \
    bash -c 'source "$1"; set_language en; luks_detect_devices() { printf "%s\n" "/dev/crypt|1G|test-uuid"; }; luks_pick_device "choose"' _ "$SCRIPT")"
assert_eq "$manual_device" "/dev/test-luks" "English manual LUKS device path"
grep -Fq -- '--column=Device --column=Size --column=UUID' "$manual_log" || fail "English manual LUKS selector columns"
grep -Fq 'Other...' "$manual_log" || fail "English manual LUKS option not exposed"
pass "LUKS manual-device language regression"

# A LUKS device without UUID shows a placeholder in the UUID column; it must follow the language.
LUKS_NOUUID_BIN="$TMP/luks-nouuid-bin"; mkdir -p "$LUKS_NOUUID_BIN"
cat > "$LUKS_NOUUID_BIN/lsblk" <<'LSBLK_NOUUID'
#!/bin/bash
case "$*" in
  *'-prno NAME,TYPE,FSTYPE,SIZE,UUID'*) printf '%s\n' '/dev/sdb1 part crypto_LUKS 10G' '/dev/sdc1 part crypto_LUKS 20G abcd-1234' ;;
esac
exit 0
LSBLK_NOUUID
cat > "$LUKS_NOUUID_BIN/zenity" <<'ZENITY_NOUUID'
#!/bin/bash
printf '%s\n' "$*" >> "${ZENITY_LOG:?}"
exit 0
ZENITY_NOUUID
chmod +x "$LUKS_NOUUID_BIN"/*
for lang in en es; do
    nouuid_log="$TMP/luks-nouuid-$lang.log"; : > "$nouuid_log"
    XDG_CONFIG_HOME="$TMP/luks-nouuid-cfg-$lang" MINT_SETUP_TEST=1 LC_ALL=C PATH="$LUKS_NOUUID_BIN:$PATH" ZENITY_LOG="$nouuid_log" \
        bash -c 'source "$1"; set_language "$2"; luks_pick_device "choose"' _ "$SCRIPT" "$lang" >/dev/null
    if [ "$lang" = en ]; then
        grep -Fq -- '/dev/sdb1 10G no UUID /dev/sdc1 20G abcd-1234' "$nouuid_log" || fail "English LUKS placeholder for a device without UUID"
        ! grep -Fq 'sin-UUID' "$nouuid_log" || fail "Spanish LUKS UUID placeholder leaked into English"
    else
        grep -Fq -- '/dev/sdb1 10G sin-UUID /dev/sdc1 20G abcd-1234' "$nouuid_log" || fail "Spanish LUKS placeholder for a device without UUID"
    fi
done
pass "LUKS device without UUID follows the language"

# LUKS metadata and binary backups must not replace an existing file after a
# failed privileged write, and a failed first write must leave no artifact.
LUKS_ATOMIC="$TMP/luks-atomic"; mkdir -p "$LUKS_ATOMIC"
printf 'old\n' > "$LUKS_ATOMIC/info.txt"
MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/luks-atomic-cfg" bash -c '
source "$1"
prun() { out="${@: -1}"; printf "partial\n" > "$out"; return 7; }   # not pkexec: flock would not see a function
luks_save_info /dev/test "$2"
' _ "$SCRIPT" "$LUKS_ATOMIC/info.txt" >/dev/null 2>&1 || true
grep -qx 'old' "$LUKS_ATOMIC/info.txt" || fail "failed LUKS metadata dump replaced the previous file"
find "$LUKS_ATOMIC" -name '.*.mstmp.*' -print -quit | grep -q . && fail "failed LUKS metadata dump left staging"
pass "LUKS backup staging"

# GUI contract test. A fake zenity captures the exact dialog arguments without
# requiring a graphical session.
MOCKBIN="$TMP/mockbin"
mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/zenity" <<'ZENITY'
#!/bin/bash
printf '%s\n' "$*" >> "${ZENITY_LOG:?}"
case " $* " in
  *" --list "*) printf '5\n'; exit 0 ;;
esac
exit 0
ZENITY
chmod +x "$MOCKBIN/zenity"

for lang in en es; do
    log="$TMP/zenity-$lang.log"
    XDG_CONFIG_HOME="$TMP/gui-$lang" MINT_SETUP_TEST=1 LC_ALL=C \
    ZENITY_LOG="$log" PATH="$MOCKBIN:$PATH" \
    bash -c 'source "$1"; set_language "$2"; main_menu' _ "$SCRIPT" "$lang"
    grep -Fq "$( [ "$lang" = en ] && printf 'What do you want to do?' || printf '¿Qué deseas hacer?' )" "$log"
    grep -Fq "$( [ "$lang" = en ] && printf 'Save configuration' || printf 'Guardar configuración' )" "$log"
    grep -Fq "$( [ "$lang" = en ] && printf 'Change language' || printf 'Cambiar idioma' )" "$log"
    grep -Fq 'L' "$log"
done
pass "main menu English/Spanish GUI contract"

# Exercise the visible L action itself: one menu pass toggles and the next exits.
cat > "$MOCKBIN/zenity-toggle" <<'ZENITY_TOGGLE'
#!/bin/bash
printf '%s\n' "$*" >> "${ZENITY_LOG:?}"
state="${ZENITY_STATE:?}"
if [ ! -e "$state" ]; then touch "$state"; printf 'L\n'; else printf '5\n'; fi
ZENITY_TOGGLE
chmod +x "$MOCKBIN/zenity-toggle"
log="$TMP/zenity-toggle.log"
cp "$MOCKBIN/zenity-toggle" "$MOCKBIN/zenity"
XDG_CONFIG_HOME="$TMP/gui-toggle" MINT_SETUP_TEST=1 LC_ALL=C \
ZENITY_LOG="$log" ZENITY_STATE="$TMP/toggle.state" PATH="$MOCKBIN:$PATH" \
bash -c 'source "$1"; set_language es; main_menu' _ "$SCRIPT"
[ "$(cat "$TMP/gui-toggle/mint-setup/language")" = "en" ] || fail "visible L action did not switch Spanish to English"
grep -Fq 'Change language' "$log"
pass "visible L action"

# Static UI guard: every Zenity text/title/column carrying Spanish prose must go through T().
if grep -nE -- '--(text|title|column|file-filter)="[^\"]*(¿|¡|á|é|í|ó|ú|ñ|Á|É|Í|Ó|Ú|Ñ)' "$SCRIPT" | grep -v '$(T '; then
    fail "raw Spanish UI text bypasses T()"
fi
pass "GUI translation guard"

# Static UI guard: a zenity dialog with a built-in text (list, entry, question, info,
# warning, error, progress, password, calendar, scale) must pass --text. Without it
# zenity writes its own text ("Select items from the list below."), translated with
# the system locale and not with APP_LANG: an English session on a Spanish system
# showed Spanish. --text-info and --file-selection have no built-in text. Limit: it
# reads calls written on one command line (with \ continuations), not argument arrays.
zenity_text_guard() {   # zenity_text_guard FILE: names every such dialog without --text
    python3 - "$1" <<'PY2'
import re, sys
MODES = 'list|entry|question|info|warning|error|progress|password|calendar|scale'
lines = open(sys.argv[1], encoding='utf-8').read().split('\n')
bad, i = 0, 0
while i < len(lines):
    first, text = i + 1, lines[i]
    while text.endswith('\\') and i + 1 < len(lines):
        i += 1
        text = text[:-1] + ' ' + lines[i].strip()
    i += 1
    if text.lstrip().startswith('#'):
        continue
    for call in re.split(r'(?<![\w./-])zenity\s', text)[1:]:
        if re.search(r'(?<![\w-])--(?:%s)(?![\w-])' % MODES, call) \
                and not re.search(r'(?<![\w-])--text(?:=|\s)', call):
            print(f'zenity dialog without --text (line {first}): {call[:70]}', file=sys.stderr)
            bad = 1
sys.exit(bad)
PY2
}
zenity_text_guard "$SCRIPT" || fail "a zenity dialog has no --text"
pass "GUI dialogs carry their own --text"

# The guard itself: it must catch the Advanced list without --text (the real defect)
# and a new dialog, and leave alone the dialogs that have no built-in text.
sed '/zenity --list --title="$(T "$APP_NAME - Avanzado")"/{n;/--text=/d;}' "$SCRIPT" > "$TMP/text-guard-advanced.sh"
if cmp -s "$SCRIPT" "$TMP/text-guard-advanced.sh"; then fail "text guard check: the --text line of the Advanced list was not found"; fi
if zenity_text_guard "$TMP/text-guard-advanced.sh" 2>"$TMP/text-guard-advanced.err"; then fail "text guard accepts the Advanced list without --text"; fi
grep -Fq 'Avanzado' "$TMP/text-guard-advanced.err" || fail "text guard did not name the Advanced list"
{ cat "$SCRIPT"; printf '%s\n' 'x=$(zenity --entry --title="x" --width=300)'; } > "$TMP/text-guard-new.sh"
if zenity_text_guard "$TMP/text-guard-new.sh" 2>"$TMP/text-guard-new.err"; then fail "text guard accepts a new dialog without --text"; fi
grep -Fq -- '--entry' "$TMP/text-guard-new.err" || fail "text guard did not name the new dialog"
{ cat "$SCRIPT"; printf '%s\n' 'zenity --text-info --title="x" --filename=/dev/null' 'zenity --file-selection --title="x"' 'zenity --list --text "x" --column=a a'; } > "$TMP/text-guard-ok.sh"
zenity_text_guard "$TMP/text-guard-ok.sh" || fail "text guard flags a dialog without a built-in text, or --text as a separate word"
pass "text guard detects a list without --text and ignores dialogs without a built-in text"

# Static UI guard: every zenity dialog must start with LANGUAGE="$APP_LANG". The buttons
# (Cancel/OK, Yes/No), the file chooser and any other text zenity writes itself come from
# the system catalogs, chosen with the session locale and not with APP_LANG: an English
# program on a Spanish system showed "Cancelar/Aceptar" (and the other way round). The
# prefix is per call: LANGUAGE is never exported. Same limit as the --text guard (one
# command line, with \ continuations).
zenity_language_guard() {   # zenity_language_guard FILE: names every dialog without the prefix
    python3 - "$1" <<'PY2'
import re, sys
MODES = ('about|calendar|color-selection|entry|error|file-selection|font-selection|forms|'
         'info|list|notification|password|progress|question|scale|text-info|warning')
CALL = r'(?<![\w./-])zenity\s'
lines = open(sys.argv[1], encoding='utf-8').read().split('\n')
bad, i = 0, 0
while i < len(lines):
    first, text = i + 1, lines[i]
    while text.endswith('\\') and i + 1 < len(lines):
        i += 1
        text = text[:-1] + ' ' + lines[i].strip()
    i += 1
    if text.lstrip().startswith('#'):
        continue
    for m in re.finditer(CALL, text):
        call = re.split(CALL, text[m.end():])[0]
        if re.search(r'(?<![\w-])--(?:%s)(?![\w-])' % MODES, call) \
                and not re.search(r'(?<![\w-])LANGUAGE="\$APP_LANG"\s+$', text[:m.start()]):
            print(f'zenity dialog without LANGUAGE="$APP_LANG" (line {first}): {call[:70]}', file=sys.stderr)
            bad = 1
sys.exit(bad)
PY2
}
zenity_language_guard "$SCRIPT" || fail "a zenity dialog does not run with LANGUAGE=\"\$APP_LANG\""
pass "GUI dialogs run with the program language"

# The guard itself: it must catch the prefix missing from the Advanced list (the real
# defect) or written any other way (fixed language, another variable, no quotes), and a
# new dialog in every zenity mode, split over two lines, after an export or with the prefix
# apart from the call; and leave alone comments, calls that open no dialog and prefixed
# calls (also split over two lines). Each case must flag that one call and no other.
language_guard_rejects() {   # language_guard_rejects WHAT NEEDLE LINE...: the script plus LINEs must fail naming NEEDLE
    local what="$1" needle="$2"
    shift 2
    { cat "$SCRIPT"; printf '%s\n' "$@"; } > "$TMP/language-guard.sh"
    if zenity_language_guard "$TMP/language-guard.sh" 2>"$TMP/language-guard.err"; then fail "language guard accepts $what"; fi
    grep -Fq -- "$needle" "$TMP/language-guard.err" || fail "language guard did not name $what"
    [ "$(wc -l < "$TMP/language-guard.err")" -eq 1 ] || fail "language guard flagged more than $what"
}
advanced='/zenity --list --title="$(T "$APP_NAME - Avanzado")"/'
for prefix in '' 'LANGUAGE=en ' 'LANGUAGE="$LANG" ' 'LANGUAGE=$APP_LANG '; do
    sed "${advanced}s/LANGUAGE=\"\$APP_LANG\" /${prefix}/" "$SCRIPT" > "$TMP/language-guard.sh"
    if cmp -s "$SCRIPT" "$TMP/language-guard.sh"; then fail "language guard check: the prefix of the Advanced list was not found"; fi
    if zenity_language_guard "$TMP/language-guard.sh" 2>"$TMP/language-guard.err"; then fail "language guard accepts the Advanced list with prefix '$prefix'"; fi
    grep -Fq 'Avanzado' "$TMP/language-guard.err" || fail "language guard did not name the Advanced list (prefix '$prefix')"
    [ "$(wc -l < "$TMP/language-guard.err")" -eq 1 ] || fail "language guard flagged more than the Advanced list (prefix '$prefix')"
done
# Every real call: without its prefix the guard flags that call and no other (startup_error
# shares its line with "command -v zenity", the progress pipes come after a closing paren).
n_calls=0
while IFS=: read -r n _; do
    n_calls=$((n_calls + 1))
    sed "${n}s/LANGUAGE=\"\$APP_LANG\" //" "$SCRIPT" > "$TMP/language-guard.sh"
    if zenity_language_guard "$TMP/language-guard.sh" 2>"$TMP/language-guard.err"; then fail "language guard accepts line $n without the prefix"; fi
    [ "$(wc -l < "$TMP/language-guard.err")" -eq 1 ] || fail "language guard flagged more than line $n"
done < <(grep -n 'LANGUAGE="$APP_LANG" zenity' "$SCRIPT")
[ "$n_calls" -gt 0 ] || fail "language guard check: the script has no prefixed zenity call"
for mode in about calendar color-selection entry error file-selection font-selection forms info list notification password progress question scale text-info warning; do
    language_guard_rejects "a new --$mode dialog without the prefix" "--$mode" "x=\$(zenity --$mode --title=\"x\")"
done
language_guard_rejects "a dialog split over two lines" 'split-dialog' $'x=$(zenity \\' '    --entry --title="split-dialog")'
language_guard_rejects "an exported LANGUAGE instead of the prefix" 'exported' 'export LANGUAGE="$APP_LANG"' 'x=$(zenity --list --title="exported" --column=a a)'
language_guard_rejects "a prefix apart from the call" 'apart' 'LANGUAGE="$APP_LANG" true; x=$(zenity --list --title="apart" --column=a a)'
language_guard_rejects "the second call of a line" 'second-call' 'x=$(LANGUAGE="$APP_LANG" zenity --list --text="x" --column=a a) | zenity --progress --title="second-call"'
language_guard_rejects "a variable that only ends in LANGUAGE" 'lookalike' 'x=$(APP_LANGUAGE="$APP_LANG" zenity --list --title="lookalike" --column=a a)'
{ cat "$SCRIPT"; printf '%s\n' \
    '# zenity --list --title="a comment" --column=a a' \
    'command -v zenity >/dev/null 2>&1 && zenity --version >/dev/null' \
    'kill -0 "$zenity_pid"' \
    'x=$(LANGUAGE="$APP_LANG" zenity --entry --title="x" --text="x")' \
    $'LANGUAGE="$APP_LANG" zenity --progress \\' \
    '    --text="x" --pulsate' \
    $'x=$(LANGUAGE="$APP_LANG" \\' \
    '    zenity --list --text="x" --column=a a)'; } > "$TMP/language-guard.sh"
zenity_language_guard "$TMP/language-guard.sh" || fail "language guard flags a comment, a call that opens no dialog or a prefixed call"
pass "language guard detects a dialog without the exact prefix and ignores calls that open none"

# Message dialogs run with --no-markup, and zenity 4.0.1 then shows a literal "\n"
# instead of a line break. A text with line breaks must reach msg_*()/confirm()
# through T_FMT, which expands them (plain T does not). A real break written as
# $'\n' is fine, so ANSI-C quoted pieces are dropped before looking.
if grep -nE '(msg_info|msg_warn|msg_error|confirm)[[:space:]]' "$SCRIPT" | sed -E "s/[\$]'[^']*'//g" | grep -F '\n' | grep -v 'T_FMT'; then
    fail "message dialog text carries a literal \\n (build it with T_FMT)"
fi
pass "message dialogs break lines for real"

# shellcheck source=../script/mint-setup.sh
MINT_SETUP_TEST=1 source "$SCRIPT"
APP_LANG=en
apt_unavailable="$(T_FMT 'Aviso: %s paquete(s) ya no están disponibles en los repositorios actuales y se omitirán:' 3)"
grep -Fqx 'Warning: 3 APT package(s) are no longer available in the current repositories and will be skipped:' <<<"$apt_unavailable" || fail "English APT unavailable warning"
pass "dynamic placeholder rendering"

# Every T()/T_FMT() key must have a real English entry. The parser is quote
# aware, so "$(T "...")" nested in another string is found, and it resolves
# $APP_NAME. It also checks keys kept in variables (T "$var" with a literal
# assignment), literals handed to helpers that call T() themselves, and the
# module labels. A key may stay identical only if listed in NEUTRAL. The other
# way round, every catalog entry must be written by some call site.
catalog_guard() {   # catalog_guard SCRIPT -> 0 ok, 1 findings on stderr
    local target="$1" dump="$TMP/catalog-dump.bin"
    MINT_SETUP_TEST=1 MINT_SETUP_BACKUPS_DIR="$TMP/catalog-backups" XDG_CONFIG_HOME="$TMP/catalog-cfg" LC_ALL=C bash -c '
        source "$1"; APP_LANG=en
        printf "N\0%s\0" "$APP_NAME"
        for k in "${!T_EXACT[@]}"; do printf "K\0%s\0%s\0" "$k" "${T_EXACT[$k]}"; done
        for k in "${MODULE_KEYS[@]}"; do printf "M\0%s\0M\0%s\0" "${MODULE_LABELS[$k]}" "${MODULE_SHORT_LABELS[$k]}"; done
    ' _ "$target" > "$dump" || return 1
    python3 -I - "$target" "$dump" <<'PY2'
import re, sys
script, dump = sys.argv[1:3]
NEUTRAL = {'Bluetooth', 'Docker', 'Firefox', 'LibreOffice', 'LibreWolf', 'Nemo',
           'ONLYOFFICE', 'Terminal', 'Thunderbird', 'Touchpad', 'VS Code'}
HELPERS = ('msg_info', 'msg_error', 'msg_warn', 'log_msg', 'confirm',
           'pick_backup_dir', 'pick_backup_dirs_multi', 'luks_pick_device')
recs = open(dump, 'rb').read().decode('utf-8').split('\0')
cat, labels, app, i = {}, [], '', 0
while i < len(recs) - 1:
    if recs[i] == 'N': app = recs[i+1]; i += 2
    elif recs[i] == 'M': labels.append(recs[i+1]); i += 2
    elif recs[i] == 'K': cat[recs[i+1]] = recs[i+2]; i += 3
    else: i += 1

def dq_end(s, i):   # s[i] is the opening quote; returns the raw inner text or None
    j, depth, out = i + 1, 0, []
    while j < len(s):
        c = s[j]
        if c == '\\' and j + 1 < len(s): out.append(s[j:j+2]); j += 2; continue
        if c == '$' and s[j+1:j+2] == '(': depth += 1; out.append('$('); j += 2; continue
        if depth and c == ')': depth -= 1
        elif c == '"' and not depth: return ''.join(out)
        out.append(c); j += 1
    return None

def literal(line, k):   # bash string literal at line[k]; None if dynamic
    if line[k] == "'":
        j = line.find("'", k + 1)
        return None if j < 0 else line[k+1:j]
    raw = dq_end(line, k)
    if raw is None: return None
    out, j = [], 0
    while j < len(raw):
        c = raw[j]
        if c == '\\' and j + 1 < len(raw) and raw[j+1] in '\\"$`': out.append(raw[j+1]); j += 2
        elif raw.startswith('$APP_NAME', j): out.append(app); j += 9
        elif c in '$`': return None
        else: out.append(c); j += 1
    return ''.join(out)

keys, held, assigned = [], [], {}
for n, line in enumerate(open(script, encoding='utf-8'), 1):
    line = line.rstrip('\n')
    st = line.lstrip()
    if st.startswith(('#', 'add_exact ', 'T()', 'T_FMT()')): continue
    for m in re.finditer(r'(?<![\w$-])(\w+)=(?=["\'])', line):
        v = literal(line, m.end())
        if v is not None: assigned.setdefault(m.group(1), []).append((n, v))
    for m in re.finditer(r'(?<![\w$.-])(T|T_FMT)[ \t]+(?=["\'$])', line):
        k = m.end()
        v = literal(line, k) if line[k] in '"\'' else None
        if v is not None: keys.append((n, v))
        else:
            h = re.match(r'"?\$\{?(\w+)\}?"?', line[k:])
            if h: held.append(h.group(1))
    for m in re.finditer(r'(?<![\w$.-])(?:' + '|'.join(HELPERS) + r')[ \t]+"(?!\$\()', line):
        v = literal(line, m.end() - 1)
        if v is not None: keys.append((n, v))
for name in set(held):
    keys += assigned.get(name, [])
keys += [(0, v) for v in labels]

bad, seen = 0, set()
for n, key in keys:
    if not key or re.fullmatch(r'-+', key) or key in seen: continue
    seen.add(key)
    where = f'at {n}' if n else 'in module labels'
    if key in NEUTRAL: continue
    if key not in cat:
        print(f'Missing English catalog entry {where}: {key}', file=sys.stderr); bad = 1
    elif cat[key] == key:
        print(f'Untranslated English message {where}: {key}', file=sys.stderr); bad = 1
if len(seen) < 300: print(f'parser found only {len(seen)} keys', file=sys.stderr); bad = 1
used = {k for _, k in keys}
for key in sorted(cat):   # reworded call site, old entry left behind: it can never be looked up
    if key not in used:
        print(f'Unused catalog entry (no call site writes it): {key}', file=sys.stderr); bad = 1
sys.exit(bad)
PY2
}
catalog_guard "$SCRIPT" || fail "static message translation coverage"
pass "static message translation coverage"

# The guard itself: it must catch a deleted entry and a new untranslated call
# nested inside "$(T "...")", the exact shape the previous guard skipped.
sed '/^add_exact "Aviso: Docker se restauró parcialmente/d' "$SCRIPT" > "$TMP/guard-missing.sh"
if catalog_guard "$TMP/guard-missing.sh" 2>"$TMP/guard-missing.err"; then fail "guard accepts a deleted catalog entry"; fi
grep -Fq 'Docker se restauró parcialmente' "$TMP/guard-missing.err" || fail "guard did not name the deleted entry"
{ cat "$SCRIPT"; printf '%s\n' 'log_msg "$(T "Aviso: mensaje nuevo sin traducir")"'; } > "$TMP/guard-new.sh"
if catalog_guard "$TMP/guard-new.sh" 2>"$TMP/guard-new.err"; then fail "guard accepts a new untranslated call"; fi
grep -Fq 'mensaje nuevo sin traducir' "$TMP/guard-new.err" || fail "guard did not name the new call"
pass "catalog guard detects regressions"
sed '/^add_exact "sin-UUID"/a add_exact "Texto huérfano que nadie escribe" "Orphan text nobody writes"' "$SCRIPT" > "$TMP/guard-unused.sh"
if catalog_guard "$TMP/guard-unused.sh" 2>"$TMP/guard-unused.err"; then fail "guard accepts an unused catalog entry"; fi
grep -Fq 'Texto huérfano que nadie escribe' "$TMP/guard-unused.err" || fail "guard did not name the unused entry"
pass "catalog guard detects an unused entry"

# Static user-facing messages must route through T().
message_usage_status=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf 'Raw untranslated message call: %s\n' "$line" >&2
    message_usage_status=1
done < <(python3 - "$SCRIPT" <<'PY2'
import re, sys
for line in open(sys.argv[1], encoding='utf-8'):
    for m in re.finditer(r'\b(log_msg|msg_info|msg_error|msg_warn|confirm)\s+("(?:\\.|[^"\\])*")', line):
        if '$(T' not in m.group(0) and m.group(2) != '""':
            print(line.rstrip())
            break
PY2
)
[ "$message_usage_status" -eq 0 ] || fail "static message calls bypass T()"
pass "static message calls use T()"

# Duplicate catalog keys would silently overwrite earlier translations.
python3 - "$SCRIPT" <<'PY2'
import re, sys
seen={}
for n,line in enumerate(open(sys.argv[1],encoding='utf-8'),1):
    m=re.match(r'add_exact "(.*)" "(.*)"$',line.rstrip('\n'))
    if not m: continue
    key=m.group(1)
    if key in seen: raise SystemExit(f'duplicate catalog key at lines {seen[key]} and {n}')
    seen[key]=n
print(f'ok ({len(seen)} unique catalog entries)')
PY2
pass "catalog has unique keys"

# Every T_FMT template must have an English catalog entry and compatible printf specifiers.
fmt_status=0
while IFS= read -r template; do
    [ -n "$template" ] || continue
    [ -n "${T_EXACT[$template]+x}" ] || { printf 'Missing T_FMT catalog entry: %s\n' "$template" >&2; fmt_status=1; continue; }
    en="${T_EXACT[$template]}"
    # grep exits 1 for a template without specifiers (only \n): that must not stop the suite (set -e + pipefail).
    src_specs=$({ grep -oE '%(s|d|i|u|f|F|g|G|e|E|x|X|o|c)' <<<"$template" || true; } | paste -sd, -)
    en_specs=$({ grep -oE '%(s|d|i|u|f|F|g|G|e|E|x|X|o|c)' <<<"$en" || true; } | paste -sd, -)
    [ "$src_specs" = "$en_specs" ] || { printf 'T_FMT printf specifiers differ: %s -> %s\n' "$template" "$en" >&2; fmt_status=1; }
done < <(python3 - "$SCRIPT" <<'PY2'
import re, sys
seen=set()
for line in open(sys.argv[1],encoding='utf-8'):
    for m in re.finditer(r"T_FMT\s+'([^']*)'", line):
        if m.group(1) not in seen:
            seen.add(m.group(1)); print(m.group(1))
PY2
)
[ "$fmt_status" -eq 0 ] || fail "dynamic message translation coverage"
pass "dynamic message translation coverage and printf contracts"

# All module labels must remain Spanish in es and be translated in en.
module_check="$(MINT_SETUP_TEST=1 XDG_CONFIG_HOME="$TMP/module-labels" bash -c '
source "$1"
for lang in es en; do
  APP_LANG="$lang"
  for key in "${MODULE_KEYS[@]}"; do printf "%s\t%s\n" "$lang" "$(T "${MODULE_LABELS[$key]}")"; done
done
' _ "$SCRIPT")"
printf '%s\n' "$module_check" | awk -F '\t' '$1=="en" && $2 ~ /[áéíóúñ¿¡]/ {exit 1}' || fail "English module labels still contain Spanish characters"
pass "module label translation coverage"

# Language selection must not alter internal backup literals.
for literal in 'manifest.conf' 'NAME=%q' 'DATE=%q' 'MINT_RELEASE=%q' 'MODULES=%q' 'apt-manual.list' 'user-in-docker-group'; do
    grep -Fq "$literal" "$SCRIPT" || fail "backup literal disappeared: $literal"
done
pass "backup format literals preserved"

# Default language folder is outside BACKUPS_ROOT.
grep -Fq 'LANGUAGE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mint-setup"' "$SCRIPT"
grep -Fq 'LANGUAGE_CONFIG_FILE="$LANGUAGE_CONFIG_DIR/language"' "$SCRIPT"
pass "language state isolated from backups"

# No accidental source renames/additional original replacements.
for original in README.md LICENSE.txt script/mint-setup.sh assets/icon.png assets/icon2.png assets/icon3.png assets/icon5.png; do
    [ -e "$ROOT/$original" ] || fail "original path missing: $original"
done
pass "original paths preserved"

# Documentation links must point to files that are actually shipped.
for readme in "$ROOT/README.md" "$ROOT/README-es.md"; do
    grep -Fq 'README-es.md' "$ROOT/README.md" || fail "English README language link missing"
    grep -Fq 'README.md' "$ROOT/README-es.md" || fail "Spanish README language link missing"
    grep -Fq 'LICENSE.txt' "$readme" || fail "LICENSE.txt link missing from $(basename "$readme")"
    # Every local image and link (src="..." and ](...)) must exist; URLs and #anchors are not files.
    while IFS= read -r target; do
        [ -e "$ROOT/${target%%#*}" ] || fail "$(basename "$readme"): local target missing: $target"
    done < <(grep -oE '(src="|\]\()[^")]+' "$readme" | sed -E 's/^(src="|\]\()//' | grep -vE '^(https?:|mailto:|#)')
done
pass "README language and local links"

# The minimum bash version is written in six places that must agree: the guard (its condition
# and both messages), the badge and the compatibility sentence of each README, and CONTRIBUTING.
# The guard is the reference.
guard_min=$(sed -n 's/^    echo "Mint-Setup needs bash \([0-9][0-9]*\.[0-9][0-9]*\) or newer;.*/\1/p' "$SCRIPT")
[[ "$guard_min" =~ ^([0-9]+)\.([0-9]+)$ ]] || fail "bash guard: its English message does not state a minimum version"
min_major=${BASH_REMATCH[1]}
min_minor=${BASH_REMATCH[2]}
grep -Fq "echo \"Mint-Setup necesita bash $guard_min o superior;" "$SCRIPT" || fail "bash guard: the Spanish message does not say $guard_min"
grep -Fq "\"\${BASH_VERSINFO[0]}\" -lt $min_major" "$SCRIPT" || fail "bash guard: the major version is not tested with -lt $min_major"
grep -Fq "\"\${BASH_VERSINFO[0]}\" -eq $min_major" "$SCRIPT" || fail "bash guard: the minor version is not tested only when the major is $min_major"
grep -Fq "\"\${BASH_VERSINFO[1]}\" -lt $min_minor" "$SCRIPT" || fail "bash guard: the minor version is not tested with -lt $min_minor"
for readme in README.md README-es.md; do
    grep -Fq "[![Bash $guard_min+]" "$ROOT/$readme" || fail "$readme: the Bash badge does not say $guard_min+"
    grep -Fq "bash-%3E%3D$guard_min-" "$ROOT/$readme" || fail "$readme: the Bash badge does not link >=$guard_min"
    grep -Fq "**Bash:** $guard_min " "$ROOT/$readme" || fail "$readme: the compatibility section does not start with Bash $guard_min"
done
grep -Fq "You need Bash $guard_min or newer" "$ROOT/.github/CONTRIBUTING.md" || fail "CONTRIBUTING.md does not say Bash $guard_min or newer"
pass "minimum bash version agrees across the guard, both READMEs and CONTRIBUTING"

printf 'All localization/regression tests passed.\n'
