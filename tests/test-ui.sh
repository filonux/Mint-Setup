#!/bin/bash
set -u
umask 022   # fixture modes must not depend on the contributor's umask
ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/script/mint-setup.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

# Every dialog opens with the program's language, not the session's: the buttons and the texts
# zenity writes itself follow LANGUAGE. The mocks log "<LANGUAGE seen> <mode>" per call and the
# runs below export LANGUAGE=ja:de, which is neither of the program's languages.
dialog_language() {   # dialog_language DIR WANT WHAT [MODE...]: every call had LANGUAGE=WANT; each MODE was opened
    local file="$1/capture/language" want="$2" what="$3" mode
    shift 3
    [ -s "$file" ] || fail "$what: no dialog was recorded"
    if grep -vq -- "^$want " "$file"; then
        fail "$what: dialogs without LANGUAGE=$want: $(grep -v -- "^$want " "$file" | tr '\n' ',')"
    fi
    for mode in "$@"; do
        grep -Fqx -- "$want $mode" "$file" || fail "$what: no $mode dialog was opened"
    done
}

MOCK="$TMP/bin"; mkdir -p "$MOCK"
cat > "$MOCK/zenity" <<'ZENITY'
#!/bin/bash
out=${ZENITY_CAPTURE:?}; mkdir -p "$out"
printf '%s\n' "$*" >> "$out/calls"
printf '%s %s\n' "${LANGUAGE-UNSET}" "${1-}" >> "$out/language"   # LANGUAGE this dialog gets, and its mode
case " $* " in *' --list '*) printf '5\n';; esac
ZENITY
chmod +x "$MOCK/zenity"

for lang in es en; do
    dir="$TMP/$lang"; mkdir -p "$dir/home" "$dir/config" "$dir/backups"
    LANGUAGE=ja:de HOME="$dir/home" XDG_CONFIG_HOME="$dir/config" MINT_SETUP_BACKUPS_DIR="$dir/backups" \
    PATH="$MOCK:/usr/bin:/bin" ZENITY_CAPTURE="$dir/capture" MINT_SETUP_TEST=1 LC_ALL=C \
    bash -c 'source "$1"; set_language "$2"; main_menu' _ "$SCRIPT" "$lang"
    dialog_language "$dir" "$lang" "$lang main menu" --list
    calls=$(cat "$dir/capture/calls")
    if [ "$lang" = en ]; then
        grep -Fq 'What do you want to do?' <<<"$calls" || fail "English main prompt"
        grep -Fq 'Opt.' <<<"$calls" || fail "English option header"
        grep -Fq 'Change language' <<<"$calls" || fail "English language action"
        grep -Fq 'Save configuration' <<<"$calls" || fail "English save action"
        grep -Fq 'Advanced settings' <<<"$calls" || fail "English advanced action"
    else
        grep -Fq '¿Qué deseas hacer?' <<<"$calls" || fail "Spanish main prompt"
        grep -Fq 'Op' <<<"$calls" || fail "Spanish option header"
        grep -Fq 'Cambiar idioma' <<<"$calls" || fail "Spanish language action"
    fi
    # Main menu dimensions are intentionally fixed to avoid accidental GUI drift.
    grep -Fq -- '--width=440 --height=340' "$dir/capture/calls" || fail "$lang main menu size"
done
pass "main menu visual contract"

# Capture Save/Restore checklist headers and module labels in both languages.
for lang in es en; do
    dir="$TMP/check-$lang"; mkdir -p "$dir/home" "$dir/config" "$dir/backups"
    cp "$MOCK/zenity" "$dir/zenity"
    LANGUAGE=ja:de ZENITY_CAPTURE="$dir/capture" HOME="$dir/home" XDG_CONFIG_HOME="$dir/config" MINT_SETUP_BACKUPS_DIR="$dir/backups" PATH="$MOCK:/usr/bin:/bin" MINT_SETUP_TEST=1 LC_ALL=C \
    bash -c 'source "$1"; set_language "$2"; do_save' _ "$SCRIPT" "$lang" >/dev/null 2>&1
    dialog_language "$dir" "$lang" "$lang save" --list --entry
    calls=$(cat "$dir/capture/calls")
    if [ "$lang" = en ]; then
        grep -Fq 'Mint-Setup - Save' <<<"$calls" || fail "English save dialog title"
        grep -Fq -- '--column=Select' <<<"$calls" || fail "English selection column"
        grep -Fq -- '--column=Module' <<<"$calls" || fail "English module column"
        grep -Fq -- '--column=Description' <<<"$calls" || fail "English description column"
        grep -Fq -- '--hide-column=4 --print-column=4' <<<"$calls" || fail "English hidden module key contract"
        grep -Fq 'Network' <<<"$calls" || fail "English visible module name"
        grep -Fq 'NetworkManager connections' <<<"$calls" || fail "English network description"
        if grep -Eq '(^| )TRUE desktop( |$)|(^| )TRUE appearance( |$)|(^| )TRUE nemo( |$)' <<<"$calls"; then fail "English internal module keys leaked into UI"; fi
    else
        grep -Fq 'Mint-Setup - Guardar' <<<"$calls" || fail "Spanish save dialog title"
        grep -Fq -- '--column=Sel' <<<"$calls" || fail "Spanish selection column"
        grep -Fq -- '--column=Módulo' <<<"$calls" || fail "Spanish module column"
        grep -Fq -- '--column=Descripción' <<<"$calls" || fail "Spanish description column"
    fi
    grep -Fq -- '--width=700 --height=500' "$dir/capture/calls" || fail "$lang save checklist size"
done
pass "save checklist visual contract"

# Restore checklist uses the same visible columns while returning hidden keys.
dir="$TMP/restore-check"; mkdir -p "$dir/home" "$dir/config" "$dir/backups/demo/terminal" "$dir/bin"
printf 'NAME=demo\nDATE=test\n' > "$dir/backups/demo/manifest.conf"
cat > "$dir/bin/zenity" <<'ZENITY_RESTORE'
#!/bin/bash
out=${ZENITY_CAPTURE:?}; mkdir -p "$out"
idx="$out/index"; n=0; [ -f "$idx" ] && n=$(cat "$idx"); n=$((n+1)); printf '%s\n' "$n" > "$idx"
printf '%s\n' "$*" >> "$out/calls"
printf '%s %s\n' "${LANGUAGE-UNSET}" "${1-}" >> "$out/language"
case "$n" in
  1) printf '%s\n' "$MINT_BACKUP_PATH" ;;
  2) printf 'terminal\n' ;;
  3) exit 0 ;;
  4) cat >/dev/null ;;
esac
ZENITY_RESTORE
chmod +x "$dir/bin/zenity"
LANGUAGE=ja:de ZENITY_CAPTURE="$dir/capture" MINT_BACKUP_PATH="$dir/backups/demo" HOME="$dir/home" XDG_CONFIG_HOME="$dir/config" MINT_SETUP_BACKUPS_DIR="$dir/backups" PATH="$dir/bin:/usr/bin:/bin" MINT_SETUP_TEST=1 LC_ALL=C \
    bash -c 'source "$1"; set_language en; do_restore' _ "$SCRIPT" >/dev/null 2>&1
dialog_language "$dir" en "restore" --list --question --progress --info
calls=$(cat "$dir/capture/calls")
grep -Fq 'Mint-Setup - Restore' <<<"$calls" || fail "English restore dialog title"
grep -Fq -- '--column=Select --column=Module --column=Description --column=Key' <<<"$calls" || fail "English restore columns"
grep -Fq -- '--hide-column=4 --print-column=4' <<<"$calls" || fail "English restore hidden key contract"
grep -Fq 'Terminal' <<<"$calls" || fail "English restore visible module"
grep -Fq 'demo' <<<"$calls" || fail "English backup selector"
grep -Fq 'What do you want to restore?' <<<"$calls" || fail "English restore prompt"
pass "restore checklist visual contract"

# Advanced menu text is fully translated and remains compact.
for lang in es en; do
    dir="$TMP/advanced-$lang"; mkdir -p "$dir/home" "$dir/config" "$dir/backups"
    LANGUAGE=ja:de ZENITY_CAPTURE="$dir/capture" HOME="$dir/home" XDG_CONFIG_HOME="$dir/config" MINT_SETUP_BACKUPS_DIR="$dir/backups" PATH="$MOCK:/usr/bin:/bin" MINT_SETUP_TEST=1 LC_ALL=C \
    bash -c 'source "$1"; set_language "$2"; do_advanced' _ "$SCRIPT" "$lang" >/dev/null 2>&1
    dialog_language "$dir" "$lang" "$lang advanced" --list --error
    calls=$(cat "$dir/capture/calls")
    # The list must carry its own --text: without it zenity writes its own text,
    # translated with the system locale and not with APP_LANG.
    first=$(sed -n 1p "$dir/capture/calls")
    grep -Fq -- '--text=' <<<"$first" || fail "$lang advanced list has no --text"
    if [ "$lang" = en ]; then
        grep -Fq 'Mint-Setup - Advanced settings' <<<"$calls" || fail "English advanced title"
        grep -Fq -- '--text=What do you want to do?' <<<"$first" || fail "English advanced prompt"
        if grep -Fq '¿' <<<"$first"; then fail "English advanced list carries Spanish text"; fi
        grep -Fq 'Open saved configurations folder' <<<"$calls" || fail "English advanced folder action"
        grep -Fq 'Back up LUKS header' <<<"$calls" || fail "English advanced LUKS action"
    else
        grep -Fq 'Mint-Setup - Avanzado' <<<"$calls" || fail "Spanish advanced title"
        grep -Fq -- '--text=¿Qué deseas hacer?' <<<"$first" || fail "Spanish advanced prompt"
        grep -Fq 'Abrir carpeta de configuraciones guardadas' <<<"$calls" || fail "Spanish advanced folder action"
        grep -Fq 'Copia de seguridad del header LUKS' <<<"$calls" || fail "Spanish advanced LUKS action"
    fi
    grep -Fq -- '--width=460 --height=380' "$dir/capture/calls" || fail "$lang advanced size"
done
pass "advanced menu visual contract"

# Message helpers and startup_error (the flows above reach them only by chance) with the
# session exporting LANGUAGE=ja:de and with it unset. The prefix gives LANGUAGE to that one
# command: the shell running the program must end with what the session had, and nothing
# exported if the session had nothing.
for session in ja:de none; do
    for lang in es en; do
        dir="$TMP/helpers-$lang-$session"; mkdir -p "$dir/home" "$dir/config" "$dir/backups"
        after=$(
            if [ "$session" = none ]; then unset LANGUAGE; else export LANGUAGE="$session"; fi
            HOME="$dir/home" XDG_CONFIG_HOME="$dir/config" MINT_SETUP_BACKUPS_DIR="$dir/backups" \
            PATH="$MOCK:/usr/bin:/bin" ZENITY_CAPTURE="$dir/capture" MINT_SETUP_TEST=1 LC_ALL=C \
            bash -c 'source "$1"; set_language "$2"
                msg_info x; msg_warn x; msg_error x; confirm x; startup_error x
                printf "%s %s\n" "${LANGUAGE-UNSET}" "$(env | grep -c "^LANGUAGE=")"' _ "$SCRIPT" "$lang" 2>/dev/null | tail -n 1)
        dialog_language "$dir" "$lang" "$lang helpers, session $session" --info --warning --error --question
        opened=$(cut -d' ' -f2 "$dir/capture/language" | tr '\n' ' ')
        [ "$opened" = '--info --warning --error --question --error ' ] || fail "$lang helpers, session $session opened: $opened"
        expected="$session 1"; [ "$session" = none ] && expected="UNSET 0"
        [ "$after" = "$expected" ] || fail "$lang: after the dialogs the shell has LANGUAGE '$after' (session $session), expected '$expected'"
    done
done
pass "dialogs run with the program language and leave the session's LANGUAGE alone"

# Verify every module label is short enough to fit a 580 px Zenity checklist
# without pathological one-word overflow, and all translated labels are non-empty.
python3 - "$SCRIPT" <<'PY'
import subprocess, sys
p=sys.argv[1]
code=r'''
MINT_SETUP_TEST=1 source "$1"
for lang in es en; do
  APP_LANG="$lang"
  for key in "${MODULE_KEYS[@]}"; do
    printf "%s\t%s\n" "$lang" "$(T "${MODULE_LABELS[$key]}")"
  done
done
'''
out=subprocess.check_output(['bash','-c',code,'_',p],text=True)
rows=[x.split('\t',1) for x in out.splitlines()]
assert len(rows)==40
for lang,text in rows:
    assert text.strip()
    # Approximate GTK width guard using UTF-8 codepoint count as a cheap floor.
    assert len(text) <= 160, (lang,len(text),text)
print('ok')
PY
pass "module label visual length"

# Check dialog sizes and long-text safety surfaces.
grep -Fq -- '--width=700 --height=500' "$SCRIPT" || fail "save/restore dialog size"
grep -Fq -- '--width=460 --height=380' "$SCRIPT" || fail "advanced dialog size"
python3 - "$SCRIPT" <<'PY'
import subprocess,sys
p=sys.argv[1]
out=subprocess.check_output(['bash','-c','MINT_SETUP_TEST=1 source "$1"; for k in "${!T_EXACT[@]}"; do printf "%s\t%s\n" "$k" "${T_EXACT[$k]}"; done','_',p],text=True)
rows=[x.split('\t',1) for x in out.splitlines()]
for k,v in rows:
    assert v.strip(), k
    assert '\u0000' not in v
    # A translated catalog entry must not contain Spanish inverted punctuation.
    assert not any(c in v for c in '¿¡'), (k,v)
print('ok')
PY
pass "translation catalog visual safety"

printf 'All UI/aesthetic tests passed.\n'
