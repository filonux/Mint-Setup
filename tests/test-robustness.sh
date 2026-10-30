#!/bin/bash
# Robustness suite: text formatting edge cases, dialog safety with hostile
# names, cancellations, damaged data and interruptions. Every check that expects
# a failure is paired with a positive control so it can never pass vacuously.
# shellcheck disable=SC2016  # ms_lib payloads are intentionally single-quoted
set -u
umask 022   # fixture modes must not depend on the contributor's umask

# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
ms_init

# --- T_FMT: arguments are data, never formatting ------------------------------
tfmt() { ms_lib 'T_FMT "$@"' "$@"; }   # prints the formatted text

check_tfmt() {   # check_tfmt "description" "expected" fmt args...
    local desc="$1" want="$2" got
    shift 2
    got=$(tfmt "$@"; printf x); got=${got%x}
    if [ "$got" = "$want" ]; then pass "T_FMT $desc"; else fail "T_FMT $desc (expected [$want], got [$got])"; fi
}

check_tfmt "substitutes plain arguments (control)"      "Ruta: /tmp/a"      'Ruta: %s' '/tmp/a'
check_tfmt "keeps an ampersand inside an argument"       "Ruta: Fotos & Videos" 'Ruta: %s' 'Fotos & Videos'
check_tfmt "keeps several ampersands and markup chars"   "<a&b&&c>"          '%s' '<a&b&&c>'
check_tfmt "does not re-substitute a %s inside an argument" "a%sb y c"       '%s y %s' 'a%sb' 'c'
check_tfmt "keeps backslashes of arguments literal"      'x a\nb y'          'x %s y' 'a\nb'
check_tfmt "leaves unmatched placeholders alone"         "a y %s"            '%s y %s' 'a'
check_tfmt "ignores extra arguments"                     "solo a"            'solo %s' 'a' 'b'
check_tfmt "expands \\n escapes of the format only"      $'a\nb x'           'a\nb %s' 'x'
check_tfmt "handles an empty argument"                   "[]"                '[%s]' ''

# --- fmt_eta: remaining time of the Restore bar -------------------------------
# Minutes are rounded to the nearest whole one (halves up) and the hours are taken from
# that figure. Rounding only below the hour printed "~60 min" for 3570-3599 s, which has
# to read "~1 h 0 min". The rows pin the thresholds; the sweep then compares every
# second up to a day and a half with an independent calculation (awk, floating point).
# The row count of the sweep is checked too, so an empty output cannot pass.
eta_rows=(
    "1|~1 s" "59|~59 s" "60|~1 min" "89|~1 min" "90|~2 min"
    "3569|~59 min" "3570|~1 h 0 min" "3599|~1 h 0 min" "3600|~1 h 0 min"
    "3629|~1 h 0 min" "3630|~1 h 1 min" "7169|~1 h 59 min" "7170|~2 h 0 min"
    "86400|~24 h 0 min"
)
eta_in=()
for row in "${eta_rows[@]}"; do eta_in+=("${row%%|*}"); done
mapfile -t eta_out < <(ms_lib 'for s in "$@"; do fmt_eta "$s"; printf "\n"; done' "${eta_in[@]}")
for i in "${!eta_rows[@]}"; do
    row=${eta_rows[$i]}
    if [ "${eta_out[$i]-}" = "${row#*|}" ]; then pass "fmt_eta ${row%%|*} s -> ${row#*|}"
    else fail "fmt_eta ${row%%|*} s: expected [${row#*|}], got [${eta_out[$i]-}]"; fi
done

eta_sweep=$(ms_lib 'for ((s = 1; s <= 129600; s++)); do printf "%d\t" "$s"; fmt_eta "$s"; printf "\n"; done' \
    | awk -F '\t' '
        { m = int(($1 + 30) / 60)
          if ($1 < 60) want = sprintf("~%d s", $1)
          else if (m < 60) want = sprintf("~%d min", m)
          else want = sprintf("~%d h %d min", int(m / 60), m % 60)
          if ($2 != want) { bad++; if (bad <= 3) first = first sprintf(" [%d: got %s, want %s]", $1, $2, want) } }
        END { printf "%d rows, %d mismatches%s", NR, bad, first }')
if [ "$eta_sweep" = "129600 rows, 0 mismatches" ]; then pass "fmt_eta sweep: 1 s to 36 h match the independent calculation"
else fail "fmt_eta sweep: $eta_sweep"; fi

# fmt_eta_txt: the three texts, in both languages, and where the text switches.
eta_txt_rows=(
    "es|3570| · quedan ~1 h 0 min"  "en|3570| · ~1 h 0 min left"
    "es|1| · quedan ~1 s"           "en|1| · ~1 s left"
    "es|0| · terminando..."         "en|0| · finishing..."
    "es|-3| · terminando..."        "en|-3| · finishing..."
    "es|-4| · tardando más de lo previsto (+~4 s)"  "en|-4| · taking longer than expected (+~4 s)"
    "es|-3570| · tardando más de lo previsto (+~1 h 0 min)"  "en|-3570| · taking longer than expected (+~1 h 0 min)"
)
for row in "${eta_txt_rows[@]}"; do
    IFS='|' read -r lang secs want <<<"$row"
    got=$(ms_lib 'APP_LANG=$1; fmt_eta_txt "$2"' "$lang" "$secs")
    if [ "$got" = "$want" ]; then pass "fmt_eta_txt [$lang] $secs s -> [$want]"
    else fail "fmt_eta_txt [$lang] $secs s: expected [$want], got [$got]"; fi
done

# --- safe_extract: names that are not valid UTF-8 -----------------------------------
# In a UTF-8 locale bash's `read -d ''` swallows the NUL after a name that ends in an
# incomplete multibyte sequence (Latin-1 "é" or "ó" as the last byte) and drops the NEXT
# name: the restore answered "success" with entries missing, and the staging folder was then
# deleted. The fixture has two such names plus a folder, so at least one of them is never
# the last one in find's order. Every comparison is byte-wise (LC_ALL=C).
xt_names() {   # xt_names DIR: creates the fixture tree (names built byte by byte)
    local d="$1" n
    (
        LC_ALL=C
        mkdir -p "$d/$(printf 'Caf\xe9')"
        for n in alfa beta gamma delta epsilon "$(printf 'Jos\xe9')" "$(printf 'Canci\xf3')"; do
            printf '%s\n' "content-of-$n" > "$d/$n"
        done
        printf 'inner\n' > "$d/$(printf 'Caf\xe9')/inner"
    )
}
xt_hashes() { ( cd "$1" && LC_ALL=C find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha1sum ); }   # raw names + hashes

XT_SRC="$TMP/xt-src"; mkdir -p "$XT_SRC"; xt_names "$XT_SRC"
( cd "$XT_SRC" && tar czf "$TMP/xt.tar.gz" . )
xt_want=$(xt_hashes "$XT_SRC" | wc -l)
if [ "$xt_want" -eq 8 ]; then pass "safe_extract fixture: 8 files including 3 names that are not valid UTF-8"
else fail "safe_extract fixture: expected 8 files, got $xt_want"; fi

xt_saved=("${MS_ENV[@]}")
xt_locales=(C C.UTF-8)
for l in en_US.UTF-8 es_ES.UTF-8; do
    locale -a 2>/dev/null | grep -qix "${l%.UTF-8}.utf-\?8" && xt_locales+=("$l")
done
for loc in "${xt_locales[@]}"; do
    MS_ENV=("${xt_saved[@]}" "LC_ALL=$loc")
    xt_dst="$TMP/xt-dst-$loc"; rm -rf "$xt_dst"; mkdir -p "$xt_dst"
    ms_lib 'safe_extract "$1" "$2"' "$TMP/xt.tar.gz" "$xt_dst"; xt_rc=$?
    if [ "$xt_rc" -eq 0 ] && [ "$(xt_hashes "$xt_dst")" = "$(xt_hashes "$XT_SRC")" ]; then
        pass "safe_extract [$loc]: every entry arrives, names that are not valid UTF-8 included"
    else
        fail "safe_extract [$loc]: rc=$xt_rc, $(xt_hashes "$xt_dst" | wc -l) of $xt_want files arrived"
    fi
    # keep mode: what already exists stays, everything else still arrives
    xt_dst="$TMP/xt-keep-$loc"; rm -rf "$xt_dst"; mkdir -p "$xt_dst"
    ( LC_ALL=C; printf 'mine\n' > "$xt_dst/$(printf 'Jos\xe9')" )
    ms_lib 'safe_extract "$1" "$2" keep' "$TMP/xt.tar.gz" "$xt_dst"; xt_rc=$?
    xt_kept=$( LC_ALL=C; cat "$xt_dst/$(printf 'Jos\xe9')" )
    if [ "$xt_rc" -eq 0 ] && [ "$xt_kept" = "mine" ] && [ "$(xt_hashes "$xt_dst" | wc -l)" -eq "$xt_want" ]; then
        pass "safe_extract keep [$loc]: the existing file is kept and the other 7 arrive"
    else
        fail "safe_extract keep [$loc]: rc=$xt_rc, kept=[$xt_kept], $(xt_hashes "$xt_dst" | wc -l) of $xt_want files"
    fi
done
# The byte-wise reading must stay inside ms_merge_tree: the caller's locale is untouched.
MS_ENV=("${xt_saved[@]}" "LC_ALL=C.UTF-8")
xt_dst="$TMP/xt-leak"; mkdir -p "$xt_dst"
xt_loc=$(ms_lib 'safe_extract "$1" "$2" >/dev/null; printf %s "$LC_ALL"' "$TMP/xt.tar.gz" "$xt_dst")
if [ "$xt_loc" = "C.UTF-8" ]; then pass "safe_extract: the caller's LC_ALL is left as it was"
else fail "safe_extract: LC_ALL leaked to the caller (got [$xt_loc])"; fi
MS_ENV=("${xt_saved[@]}")

# --- safe_extract: read-only folders in the copy -----------------------------------------
# A staged folder without write access cannot be moved to another parent (rename rewrites its
# "..") nor emptied, and one without read access lists as empty: the restore failed with
# "Permission denied" or lost its content, and rm could not empty the stage left in the
# destination. Root ignores those permissions, so this only tells apart for a normal user.
# The archive is built with exact modes (tar cannot read a 000 folder to pack it).
if [ "$(id -u)" -eq 0 ]; then echo "SKIP: safe_extract with read-only folders (needs an unprivileged user)"
elif ! command -v python3 >/dev/null 2>&1; then echo "SKIP: safe_extract with read-only folders (needs python3 to build the archive)"
else
    python3 - "$TMP/ro.tar.gz" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as t:
    def d(name, mode):
        i = tarfile.TarInfo(name); i.type = tarfile.DIRTYPE; i.mode = mode; t.addfile(i)
    def f(name, data):
        i = tarfile.TarInfo(name); i.size = len(data); i.mode = 0o644; t.addfile(i, io.BytesIO(data))
    d("cfg", 0o755)
    for name, mode, leaf in (("ro", 0o555, "file"), ("both", 0o555, "new.txt"), ("closed", 0o000, "data"),
                             ("blind", 0o300, "z"), ("noexec", 0o600, "y"), ("sealed", 0o000, "x"),
                             ("writable", 0o755, "file")):
        d("cfg/" + name, mode); f("cfg/%s/%s" % (name, leaf), (name + "\n").encode())
        if name == "ro":   # members of a folder stay together, as tar c lists them
            d("cfg/ro/sub", 0o555); f("cfg/ro/sub/deep", b"deep\n")
            d("cfg/ro/vault", 0o000); f("cfg/ro/vault/v", b"v\n")
PY
    ro_dst="$TMP/ro-dst"; rm -rf "$ro_dst"; for ro_n in both closed blind noexec; do
        mkdir -p "$ro_dst/cfg/$ro_n"; printf 'old\n' > "$ro_dst/cfg/$ro_n/old.txt"
    done
    ms_lib 'safe_extract "$1" "$2"' "$TMP/ro.tar.gz" "$ro_dst" 2>"$TMP/ro.err"; ro_rc=$?
    ro_have=$(cd "$ro_dst/cfg" && for f in ro/file ro/sub/deep both/new.txt both/old.txt closed/data closed/old.txt blind/z blind/old.txt noexec/y noexec/old.txt writable/file; do [ -f "$f" ] && printf '%s ' "$f"; done)
    if [ "$ro_rc" -eq 0 ] && [ "$ro_have" = "ro/file ro/sub/deep both/new.txt both/old.txt closed/data closed/old.txt blind/z blind/old.txt noexec/y noexec/old.txt writable/file " ] \
        && [ -r "$ro_dst/cfg/ro/file" ]; then
        pass "safe_extract: read-only and unreadable folders of the copy are merged into an existing destination (rc 0, existing files kept)"
    else fail "safe_extract read-only folders (rc=$ro_rc, arrived: [$ro_have], stderr: $(head -c 150 "$TMP/ro.err"))"; fi
    ro_modes=$(cd "$ro_dst/cfg" && stat -c '%n=%a' ro sealed writable ro/vault | tr '\n' ' ')
    if [ "$ro_modes" = "ro=555 sealed=0 writable=755 ro/vault=0 " ]; then pass "safe_extract: a folder moved whole keeps its stored mode (555, 000, also nested; a writable one is untouched)"
    else fail "safe_extract: modes after the move (got: $ro_modes)"; fi
    if [ ! -s "$TMP/ro.err" ] && [ -z "$(find "$ro_dst" -maxdepth 1 -name '*mstmp*' -print -quit)" ]; then
        pass "safe_extract: that restore prints no error and leaves no staging folder"
    else fail "safe_extract read-only folders: stderr [$(head -c 150 "$TMP/ro.err")], stage left: [$(find "$ro_dst" -maxdepth 1 -name '*mstmp*' -print -quit)]"; fi
    # A folder of the copy that clashes with a file: nothing can merge it, and the stage that
    # still holds it must go anyway.
    ro_dst2="$TMP/ro-dst2"; rm -rf "$ro_dst2"; mkdir -p "$ro_dst2/cfg"; printf 'a file\n' > "$ro_dst2/cfg/ro"
    ro_out=$(ms_lib 'safe_extract "$1" "$2" 2>/dev/null; echo "rc=$? partial=$SAFE_EXTRACT_PARTIAL"' "$TMP/ro.tar.gz" "$ro_dst2")
    if [ "$ro_out" = "rc=1 partial=1" ] && [ -z "$(find "$ro_dst2" -maxdepth 1 -name '*mstmp*' -print -quit)" ]; then
        pass "safe_extract: a clash with a read-only folder in the stage is reported (rc 1, partial) and the stage is removed"
    else fail "safe_extract clash with read-only folders (got: $ro_out, stage left: [$(find "$ro_dst2" -maxdepth 1 -name '*mstmp*' -print -quit)])"; fi
    # The cleanup at exit (the EXIT trap) empties them too.
    ro_dst3="$TMP/ro-dst3"; rm -rf "$ro_dst3"; mkdir -p "$ro_dst3"
    ms_lib 'ms_mktemp d "$1/x" d; mkdir "$d/ro"; : > "$d/ro/f"; chmod 555 "$d/ro"' "$ro_dst3" 2>/dev/null
    ok "a temporary folder holding a read-only folder is removed when the program exits" test -z "$(find "$ro_dst3" -mindepth 1 -print -quit)"
    ro_dst4="$TMP/ro-dst4"; rm -rf "$ro_dst4"; mkdir -p "$ro_dst4"
    ok "ms_tmp_discard empties a temporary folder holding a read-only folder" \
        ms_lib 'ms_mktemp d "$1/x" d; mkdir "$d/ro"; : > "$d/ro/f"; chmod 555 "$d/ro"; ms_tmp_discard "$d"; [ ! -e "$d" ]' "$ro_dst4"
    chmod -R u+rwX "$ro_dst" "$ro_dst2" "$ro_dst3" "$ro_dst4" 2>/dev/null
fi
# --- end: safe_extract read-only folders

# --- ms_mktemp: names with no room for the temporary's own suffix ------------------------
# A temporary is named ".<name>.mstmp.XXXXXX": up to 14 bytes more than the name (17 for the
# ".mint-old." folder of an export). A name of 242 to 255 bytes is valid on its own, but its
# temporary was not (ENAMETOOLONG), so every write to it failed. Names longer than 100 bytes now
# use their first 100 bytes, with everything outside [A-Za-z0-9._-] turned into "_" (a multibyte
# character cut in half would be a name some filesystems refuse); ordinary names are untouched.
MT_DIR="$TMP/mt"; mkdir -p "$MT_DIR"
mt_name() {   # mt_name BYTES: an ASCII name of exactly BYTES bytes (letters and digits only)
    local pat=0123456789abcdefghijklmnopqrstuvwxyz s=""
    while [ "${#s}" -lt "$1" ]; do s+=$pat; done
    printf '%s' "${s:0:$1}"
}
mt_blen() { local LC_ALL=C s="$1"; printf '%s' "${#s}"; }
mt_probe() {   # mt_probe DIR NAME [d]: "<temporary basename>|<exists as file or folder>|<same folder>"
    ms_lib 'ms_mktemp t "$1/$2" ${3:+d} || { printf "rc=%s" "$?"; exit 0; }
        if [ "${3:-}" = d ]; then [ -d "$t" ] && e=1 || e=0; else [ -f "$t" ] && e=1 || e=0; fi
        [ "${t%/*}" = "$1" ] && s=same || s=other
        printf "%s|%s|%s" "${t##*/}" "$e" "$s"' "$@" 2>/dev/null
}
mt_expect() {   # mt_expect DESCRIPTION DIR NAME EXPECTED-STEM [d]: the temporary is ".<stem>.mstmp.<6 chars>"
    local desc="$1" dir="$2" name="$3" stem="$4" kind="${5:-}" got b
    got=$(mt_probe "$dir" "$name" ${kind:+"$kind"})
    b=${got%%|*}
    if [[ "$b" == ".$stem.mstmp."?????? ]] && [ "${got#*|}" = "1|same" ] \
        && [[ "${b##*.mstmp.}" =~ ^[A-Za-z0-9]{6}$ ]]; then return 0; fi
    printf 'mt_expect: %s: got [%s]\n' "$desc" "$(printf '%s' "$got" | cut -c1-160)" >&2
    return 1
}

mt_fail=0
mt_expect "plain file"      "$MT_DIR" "settings.json" "settings.json" || mt_fail=1
mt_expect "leading dot"     "$MT_DIR" ".bashrc" "bashrc" || mt_fail=1
mt_expect "accents, spaces" "$MT_DIR" "Configuración Fotos.png" "Configuración Fotos.png" || mt_fail=1
mt_expect "apostrophe"      "$MT_DIR" "Rob's pic.jpg" "Rob's pic.jpg" || mt_fail=1
mt_expect "100 bytes"       "$MT_DIR" "$(mt_name 100)" "$(mt_name 100)" || mt_fail=1
mt_expect "100 bytes, space" "$MT_DIR" "$(mt_name 99) " "$(mt_name 99) " || mt_fail=1
mt_expect "folder"          "$MT_DIR" "Copia_20261027-101500" "Copia_20261027-101500" d || mt_fail=1
if [ "$mt_fail" -eq 0 ]; then pass "ms_mktemp: ordinary names keep their temporary name (leading dot, accents, spaces, 100 bytes with or without a space, folders)"
else fail "ms_mktemp: an ordinary name changed its temporary name"; fi

mt_fail=0
mt_punct="Xy.Z_a-B$(mt_name 142)"   # 150 bytes; capitals, ".", "_" and "-" are kept by the cut
mt_expect "150 bytes with A-Z . _ -" "$MT_DIR" "$mt_punct" "${mt_punct:0:100}" || mt_fail=1
for mt_n in 101 150 241 242 243 255; do
    mt_long=$(mt_name "$mt_n")
    for mt_kind in "" d; do
        mt_expect "$mt_n bytes${mt_kind:+, folder}" "$MT_DIR" "$mt_long" "${mt_long:0:100}" $mt_kind || mt_fail=1
        mt_got=$(mt_probe "$MT_DIR" "$mt_long" $mt_kind)
        [ "$(mt_blen "${mt_got%%|*}")" -eq 114 ] || { printf 'length of the %s-byte temporary: %s\n' "$mt_n" "$(mt_blen "${mt_got%%|*}")" >&2; mt_fail=1; }
    done
done
if [ "$mt_fail" -eq 0 ]; then pass "ms_mktemp: a name of 101 to 255 bytes gets a 114-byte temporary built from its first 100 bytes (file and folder)"
else fail "ms_mktemp: a long name did not get its 114-byte temporary"; fi

# A cut inside a multibyte character, and names that are not UTF-8 at all, give plain ASCII.
mt_a99=$(mt_name 99); mt_a98=$(mt_name 98)
mt_fail=0
mt_saved=("${MS_ENV[@]}")
mt_locales=(C C.UTF-8)
for l in en_US.UTF-8 es_ES.UTF-8; do
    locale -a 2>/dev/null | grep -qix "${l%.UTF-8}.utf-\?8" && mt_locales+=("$l")
done
for mt_loc in "${mt_locales[@]}"; do
    MS_ENV=("${mt_saved[@]}" "LC_ALL=$mt_loc")
    # Valid names of 242 to 246 bytes: 99 bytes + "é" x 72 (2 bytes each, cut after the first byte
    # of the first one); 98 bytes + "😀" x 37 (4 bytes each, cut after two); 99 bytes + 143
    # Latin-1 "é" (not UTF-8); 80 "é" (160 bytes but 80 characters: the length counts bytes)
    mt_e=$(printf 'é%.0s' $(seq 1 72)); mt_g=$(printf '\xf0\x9f\x98\x80%.0s' $(seq 1 37))
    mt_l=$( LC_ALL=C; printf '\xe9%.0s' $(seq 1 143) )
    mt_e80=$(printf 'é%.0s' $(seq 1 80)); mt_u100=$(printf '_%.0s' $(seq 1 100))
    for mt_case in "é|$mt_a99|$mt_e|${mt_a99}_" "emoji|$mt_a98|$mt_g|${mt_a98}__" "latin1|$mt_a99|$mt_l|${mt_a99}_" "é x 80||$mt_e80|$mt_u100"; do
        IFS='|' read -r mt_label mt_head mt_tail mt_stem <<<"$mt_case"
        mt_bytes=$( LC_ALL=C; printf '%s%s' "$mt_head" "$mt_tail" )
        mt_got=$(ms_lib 'ms_mktemp t "$1/$2" || exit 3; b=${t##*/}; printf "%s|%s" "$b" "$([ -f "$t" ] && echo 1 || echo 0)"' "$MT_DIR" "$mt_bytes" 2>/dev/null)
        mt_b=${mt_got%%|*}
        if [ "$mt_b" = ".$mt_stem.mstmp.${mt_b##*.mstmp.}" ] && [ "${mt_got#*|}" = 1 ] && [ "$(mt_blen "$mt_b")" -eq 114 ] \
            && printf '%s' "$mt_b" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && ! printf '%s' "$mt_b" | LC_ALL=C grep -q '[^ -~]'; then :
        else printf 'multibyte cut [%s, %s]: got [%s]\n' "$mt_loc" "$mt_label" "$mt_got" >&2; mt_fail=1; fi
    done
done
MS_ENV=("${mt_saved[@]}")
if [ "$mt_fail" -eq 0 ]; then pass "ms_mktemp: a cut inside a multibyte character, or a name that is not UTF-8, gives a plain ASCII temporary (${mt_locales[*]})"
else fail "ms_mktemp: a name cut inside a multibyte character did not give a plain ASCII temporary"; fi

mt_loc=$(ms_lib 'ms_mktemp t "$1/$2" >/dev/null; printf %s "$LC_ALL"' "$MT_DIR" "$(mt_name 200)")
if [ "$mt_loc" = "C.UTF-8" ]; then pass "ms_mktemp: the caller's LC_ALL is left as it was"
else fail "ms_mktemp: LC_ALL leaked to the caller (got [$mt_loc])"; fi

# Every helper publishes a destination whose name leaves no room for the old temporary; a name
# that is too long for the filesystem still fails and leaves nothing behind (positive control).
mt_src="$TMP/mt-src"; mkdir -p "$mt_src"; printf 'payload\n' > "$mt_src/data.txt"; chmod 640 "$mt_src/data.txt"
mt_content_ok() {   # mt_content_ok OP FILE: the published file holds what the operation wrote
    case "$1" in
        tar) tar -tzf "$2" 2>/dev/null | grep -qx 'data.txt' ;;
        *)   grep -qx 'payload' "$2" ;;
    esac
}
mt_fail=0
for mt_n in 242 255 256; do
    mt_dst="$TMP/mt-dst-$mt_n"; rm -rf "$mt_dst"; mkdir -p "$mt_dst"
    mt_long=$(mt_name "$mt_n"); mt_want=0; [ "$mt_n" -le 255 ] && mt_want=1
    for mt_op in copy write capture tar; do
        case "$mt_op" in
            copy)    mt_code='atomic_copy "$1/data.txt" "$2/$3"' ;;
            write)   mt_code='printf "payload\n" | atomic_write "$2/$3"' ;;
            capture) mt_code='atomic_capture "$2/$3" printf "payload\n"' ;;
            tar)     mt_code='atomic_tar "$2/$3" -C "$1" data.txt' ;;
        esac
        ms_lib "$mt_code" "$mt_src" "$mt_dst" "$mt_long" >/dev/null 2>&1; mt_rc=$?
        mt_made=0; [ -f "$mt_dst/$mt_long" ] && mt_made=1
        mt_left=$(find "$mt_dst" -name '.*mstmp*' -print -quit)
        if [ "$mt_want" -eq 1 ]; then
            if [ "$mt_rc" -eq 0 ] && [ "$mt_made" -eq 1 ] && [ -z "$mt_left" ] && mt_content_ok "$mt_op" "$mt_dst/$mt_long"; then :
            else printf 'atomic_%s with a %s-byte name: rc=%s made=%s left=[%s]\n' "$mt_op" "$mt_n" "$mt_rc" "$mt_made" "$mt_left" >&2; mt_fail=1; fi
        else
            [ "$mt_rc" -eq 1 ] && [ "$mt_made" -eq 0 ] && [ -z "$mt_left" ] \
                || { printf 'atomic_%s with a %s-byte name (too long): rc=%s made=%s left=[%s]\n' "$mt_op" "$mt_n" "$mt_rc" "$mt_made" "$mt_left" >&2; mt_fail=1; }
        fi
    done
done
if [ "$mt_fail" -eq 0 ]; then pass "atomic_copy, atomic_write, atomic_capture and atomic_tar publish a 242 or 255-byte name; a 256-byte one fails and leaves nothing"
else fail "an atomic helper failed on a name close to the filesystem limit"; fi

# The staged folder of a save or an export, published under a name of 255 bytes.
mt_fail=0
for mt_n in 242 255; do
    mt_dst="$TMP/mt-stage-$mt_n"; rm -rf "$mt_dst"; mkdir -p "$mt_dst"; mt_long=$(mt_name "$mt_n")
    ms_lib 'ms_mktemp s "$1/$2" d && : > "$s/inside" && ms_commit "$s" "$1/$2"' "$mt_dst" "$mt_long" >/dev/null 2>&1; mt_rc=$?
    { [ "$mt_rc" -eq 0 ] && [ -f "$mt_dst/$mt_long/inside" ] && [ -z "$(find "$mt_dst" -maxdepth 1 -name '.*mstmp*' -print -quit)" ]; } \
        || { printf 'staged folder with a %s-byte name: rc=%s\n' "$mt_n" "$mt_rc" >&2; mt_fail=1; }
done
if [ "$mt_fail" -eq 0 ]; then pass "a staged folder is published under a 242 or 255-byte name"
else fail "a staged folder could not be published under a name close to the filesystem limit"; fi
# do_export_backup over an existing destination: its hidden rollback folder (".NAME.mint-old.XXXXXX",
# 17 bytes more than the name) needs room too. 20 is an ordinary name and 238 bytes the longest that
# fitted; from 239 the export stopped with "could not prepare the safe replacement" and exported
# nothing. The stub of rm refuses that folder (as when a USB cannot delete it), to see its name.
mt_fail=0
for mt_n in 20 238 239 255; do
    mt_long=$(mt_name "$mt_n"); mt_stem=${mt_long:0:100}
    for mt_refuse in 0 1; do
        mt_root="$TMP/mt-export-$mt_n-$mt_refuse"; rm -rf "$mt_root"
        mkdir -p "$mt_root/src/$mt_long" "$mt_root/dest/$mt_long"
        printf 'NAME=%q\nDATE=%q\nMODULES=%q\n' 'Long name' '2026-01-01' 'terminal' > "$mt_root/src/$mt_long/manifest.conf"
        printf 'new\n' > "$mt_root/src/$mt_long/new.txt"; printf 'old\n' > "$mt_root/dest/$mt_long/old.txt"
        if [ "$mt_refuse" -eq 1 ]; then
            ms_stub rm 'for a in "$@"; do case "$a" in *.mint-old.*) echo "rm: cannot remove $a" >&2; exit 1 ;; esac; done
exec /bin/rm "$@"'
        fi
        ZENITY_FILE="$mt_root/dest" ms_lib 'root=$1; name=$2
pick_backup_dir() { printf "%s\n" "$root/src/$name"; }
msg_info()  { printf "%s" "$1" > "$root/info"; }
msg_warn()  { printf "%s" "$1" > "$root/warn"; }
msg_error() { printf "%s" "$1" > "$root/error"; }
do_export_backup; echo "$?" > "$root/rc"' "$mt_root" "$mt_long" >/dev/null 2>&1
        /bin/rm -f "$MOCK/rm"
        mt_left=$(find "$mt_root/dest" -mindepth 1 -maxdepth 1 -name '.*' -printf '%f' 2>/dev/null)
        mt_entries=$(find "$mt_root/dest" -mindepth 1 -maxdepth 1 | wc -l)
        mt_ok=1
        [ "$(cat "$mt_root/rc" 2>/dev/null)" = 0 ] || mt_ok=0
        { [ -s "$mt_root/info" ] && [ ! -e "$mt_root/error" ] && [ ! -e "$mt_root/warn" ]; } || mt_ok=0
        [ "$(cat "$mt_root/dest/$mt_long/new.txt" 2>/dev/null)" = new ] || mt_ok=0
        [ ! -e "$mt_root/dest/$mt_long/old.txt" ] || mt_ok=0
        if [ "$mt_refuse" -eq 0 ]; then
            [ "$mt_entries" -eq 1 ] && [ -z "$mt_left" ] || mt_ok=0
        else
            [ "$mt_entries" -eq 2 ] && [ "$(mt_blen "$mt_left")" -eq $(( ${#mt_stem} + 17 )) ] || mt_ok=0
            [[ "$mt_left" == ".$mt_stem.mint-old."?????? ]] || mt_ok=0
            [ "$(cat "$mt_root/dest/$mt_left/old.txt" 2>/dev/null)" = old ] || mt_ok=0
            grep -Fq -- "$mt_root/dest/$mt_left" "$mt_root/info" 2>/dev/null || mt_ok=0
        fi
        [ "$mt_ok" -eq 1 ] || { printf 'export over a %s-byte destination (rm refused: %s): rc=[%s] entries=%s left=[%s]\n' \
            "$mt_n" "$mt_refuse" "$(cat "$mt_root/rc" 2>/dev/null)" "$mt_entries" "${mt_left:0:130}" >&2; mt_fail=1; }
    done
done
if [ "$mt_fail" -eq 0 ]; then pass "export over an existing destination with a 20, 238, 239 or 255-byte name replaces it; a copy that cannot be deleted keeps a hidden name built from the first 100 bytes and is named in the dialog"
else fail "export over an existing destination with a name close to the filesystem limit"; fi
# --- end: ms_mktemp long names

# --- dconf: crafted Desktop dumps and a failed rollback -----------------------------------
# Desktop shares /org/cinnamon/ with other modules, so the dump is checked before any reset:
# a key with a "/" lands in another module's folder, a section that CONTAINS an excluded path
# is wiped whole by "dconf reset -f", and glib accepts what the reset loops do not see (blanks
# around a header, a last line without a newline). Reproduced with a real dconf.
dg_check() {   # dg_check "description" wanted-rc 'file content (printf %b)'
    local want="$2" rc
    printf '%b' "$3" > "$TMP/dg.dconf"
    ms_lib 'dconf_desktop_file_is_safe "$1"' "$TMP/dg.dconf"; rc=$?
    if [ "$rc" = "$want" ]; then pass "desktop dump guard: $1"; else fail "desktop dump guard: $1 (rc=$rc, wanted $want)"; fi
}
dg_check "a normal dump is accepted (control)" 0 "[/]\nenabled-applets=['a@b', 'c']\n\n[applets/foo]\nk=1\n[desktop/keybindings/custom]\ncommand='/usr/bin/x'\n"
dg_check "a sibling of an excluded path is accepted (control)" 0 "[desktop/interface-extra]\nk=1\n[desktop/keybindings]\nk=1\n"
dg_check "a last line without a newline is accepted when it is fine (control)" 0 "[/]\nk=1"
dg_check "a key with a slash under [/] is refused" 1 "[/]\ndesktop/interface/font-name='x'\n"
dg_check "a key with a slash under another section is refused" 1 "[applets]\n../desktop/background/picture-uri='x'\n"
dg_check "a section that contains an excluded path is refused" 1 "[desktop]\nown=1\n"
dg_check "…also one without keys" 1 "[settings-daemon/peripherals]\n"
dg_check "an excluded section is refused" 1 "[desktop/interface]\nk=1\n"
dg_check "a section below an excluded one is refused" 1 "[desktop/interface/sub]\nk=1\n"
dg_check "a blank before a header is refused" 1 " [desktop/interface]\nk=1\n"
dg_check "a blank after a header is refused" 1 "[desktop/interface] \nk=1\n"
dg_check "a Windows line ending is refused" 1 "[applets/foo]\r\nk=1\r\n"
dg_check "a last line without a newline is still checked" 1 "[/]\nk=1\ndesktop/interface/font-name='x'"
dg_check "a line that is neither header nor key=value is refused" 1 "[/]\njunk\n"
dg_check "a comment line is refused" 1 "[/]\n#a=b\n"
# A refused dump says so (it used to fail without a word) and nothing is reset or loaded.
printf "[/]\ndesktop/interface/font-name='x'\n" > "$TMP/dg.dconf"
dg_out=$(ms_lib 'calls=$2; dconf() { echo "DCONF $*" >> "$calls"; return 0; }
    set_language en; RESTORE_CONTEXT=1; RESTORE_MODULE_FAILED=0
    dconf_load_desktop_clean /org/cinnamon/ "$1" 2>&1; echo "RC:$? FAILED:$RESTORE_MODULE_FAILED"' "$TMP/dg.dconf" "$TMP/dg.calls")
if [[ "$dg_out" == *"is damaged, incomplete or unsafe"* ]] && [[ "$dg_out" == *"RC:1 FAILED:1"* ]] && [ ! -e "$TMP/dg.calls" ]; then
    pass "desktop dump guard: the refusal is reported and dconf is not called"
else fail "desktop dump guard refusal (out: $dg_out; dconf calls: $(cat "$TMP/dg.calls" 2>/dev/null))"; fi

# A rollback that fails too must say so: the path may be left reset or half restored.
dr_run() {   # dr_run MODE FUNCTION TARGET FILE: dconf stand-in (loadfail | resetfail | first = only the first load fails)
    ms_lib 'mode=$1; shift; n=0
        dconf() { case "$1" in
            dump) printf "[x]\nk=1\n" ;;
            reset) [ "$mode" = resetfail ] && return 17; return 0 ;;
            load) cat >/dev/null; n=$((n + 1)); [ "$mode" = loadfail ] && return 17; [ "$mode" = first ] && [ "$n" -eq 1 ] && return 17; return 0 ;;
            *) return 1 ;; esac; }
        set_language en; RESTORE_CONTEXT=1; RESTORE_MODULE_FAILED=0
        "$@" 2>&1; echo "RC:$? FAILED:$RESTORE_MODULE_FAILED"' "$@"
}
printf '[applets/foo]\nk=1\n' > "$TMP/dr-section.dconf"; printf '[/]\nrootkey=1\n' > "$TMP/dr-root.dconf"
dr_check() {   # dr_check "description" expected(warn|nowarn) MODE FUNCTION TARGET FILE
    local desc="$1" want="$2" out has=nowarn; shift 2
    out=$(dr_run "$@")
    [[ "$out" == *"could not be put back"* ]] && has=warn
    if [ "$has" = "$want" ] && [[ "$out" == *"RC:1 FAILED:1"* ]]; then pass "dconf rollback: $desc"
    else fail "dconf rollback: $desc (wanted $want, got $has; out: $out)"; fi
}
dr_check "load_clean, load and rollback fail: warned" warn loadfail dconf_load_clean /org/demo/ "$TMP/dr-section.dconf"
dr_check "load_clean, the rollback works: not warned (control)" nowarn first dconf_load_clean /org/demo/ "$TMP/dr-section.dconf"
dr_check "desktop, a section reset fails and the rollback fails: warned" warn resetfail dconf_load_desktop_clean /org/cinnamon/ "$TMP/dr-section.dconf"
dr_check "desktop, a root key reset fails and the rollback fails: warned" warn resetfail dconf_load_desktop_clean /org/cinnamon/ "$TMP/dr-root.dconf"
dr_check "desktop, the load fails and the rollback fails: warned" warn loadfail dconf_load_desktop_clean /org/cinnamon/ "$TMP/dr-section.dconf"
dr_check "desktop, the load fails and the rollback works: not warned (control)" nowarn first dconf_load_desktop_clean /org/cinnamon/ "$TMP/dr-section.dconf"
# --- end: dconf crafted dumps and rollback

# --- restore modules: the closing line after a failure ------------------------------------
# A module that flagged a failure (restore_problem, restore_mark_failed: what makes
# run_restore_module report it as failed) closed with "... restored" right under its own
# warnings. A module needs its folder (or, for the browsers and office suites, its archive) to
# go on; empty, it only prints its closing line, so the same call with the flag clear (control)
# and set shows the difference.
rf_empty="$TMP/rf-empty"; rm -rf "$rf_empty"; mkdir -p "$rf_empty"
ms_stub pgrep 'exit 1'   # no application is open (the default stub says every one is)
for rf_mod in desktop appearance nemo startup displays sound keyboard mouse touchpad firefox librewolf thunderbird libreoffice onlyoffice terminal; do
    mkdir -p "$rf_empty/$rf_mod"
    case "$rf_mod" in
        firefox|librewolf|thunderbird) tar czf "$rf_empty/$rf_mod/$rf_mod-profiles.tar.gz" -T /dev/null ;;
        libreoffice|onlyoffice) tar czf "$rf_empty/$rf_mod/$rf_mod-config.tar.gz" -T /dev/null ;;
    esac
    rf_ok=$(ms_lib 'set_language en; RESTORE_CONTEXT=1; RESTORE_MODULE_FAILED=0; "restore_$1" "$2" 2>&1' "$rf_mod" "$rf_empty")
    rf_bad=$(ms_lib 'set_language en; RESTORE_CONTEXT=1; RESTORE_MODULE_FAILED=1; "restore_$1" "$2" 2>&1' "$rf_mod" "$rf_empty")
    rf_line=$(printf '%s\n' "$rf_ok" | grep -m1 -i 'restored')
    if [ -n "$rf_line" ] && [[ "$rf_ok" != *"only partly"* ]] && [[ "$rf_bad" == *"only partly restored"* ]] && [[ "$rf_bad" != *"$rf_line"* ]]; then
        pass "restore_$rf_mod: after a flagged failure it does not say it was restored"
    else fail "restore_$rf_mod closing (clear flag: [$rf_ok] set flag: [$rf_bad])"; fi
done
ms_stub pgrep
# --- end: restore closing lines

# --- Exit status of a helper that runs as a pipeline element or a background job ---------------
# bash 5.1 (Mint 21): a pipeline element or background job with an EXIT trap ends with the status
# of its last command, not the one given to "return" (see ms_tmp_track): a failed write or module
# counted as done. The first temporary file installs that trap, so every failure below comes after
# one was registered. The 5.1 run is the Ubuntu 22.04 leg of compat.yml. Each control is the same
# call without the failure.
sx="$TMP/sx"; rm -rf "$sx"; mkdir -p "$sx/src" "$sx/dst/blocked/inside"; printf 'payload\n' > "$sx/src/data.txt"
sx_left() { find "$sx/dst" -name '.*mstmp*' -print -quit; }
sx_job() {   # sx_job BODY: status of restore_module_job, as a background job, on a module whose function is BODY
    ms_lib 'eval "restore_sx() { $2; }"; restore_module_job sx "$1" >/dev/null 2>&1 & wait $!; printf %s "$?"' "$sx/dst" "$1"
}
sx_w_ok=$(ms_lib 'printf "x\n" | atomic_write "$1/new"; printf %s "${PIPESTATUS[1]}"' "$sx/dst" 2>/dev/null)
sx_w_bad=$(ms_lib 'printf "x\n" | atomic_write "$1/blocked"; printf %s "${PIPESTATUS[1]}"' "$sx/dst" 2>/dev/null)
if [ "$sx_w_ok" = 0 ] && [ "$(cat "$sx/dst/new" 2>/dev/null)" = x ] && [ "$sx_w_bad" = 1 ] \
    && [ -d "$sx/dst/blocked/inside" ] && [ -z "$(sx_left)" ]; then
    pass "atomic_write at the end of a pipe: a failure after its temporary file exists gives 1, not 0"
else fail "atomic_write at the end of a pipe: success [$sx_w_ok], failure [$sx_w_bad] (want 0 and 1), leftovers [$(sx_left)]"; fi
sx_t_ok=$(ms_lib 'printf "" | atomic_tar "$1/dst/good.tar.gz" -C "$1/src" data.txt; printf %s "${PIPESTATUS[1]}"' "$sx" 2>/dev/null)
sx_t_bad=$(ms_lib 'printf "" | atomic_tar "$1/dst/bad.tar.gz" -C "$1/src" missing.txt; printf %s "${PIPESTATUS[1]}"' "$sx" 2>/dev/null)
if [ "$sx_t_ok" = 0 ] && tar -tzf "$sx/dst/good.tar.gz" 2>/dev/null | grep -qx data.txt \
    && [ "$sx_t_bad" = 1 ] && [ ! -e "$sx/dst/bad.tar.gz" ] && [ -z "$(sx_left)" ]; then
    pass "atomic_tar at the end of a pipe: a failure after its temporary file exists gives 1, not 0"
else fail "atomic_tar at the end of a pipe: success [$sx_t_ok], failure [$sx_t_bad] (want 0 and 1), leftovers [$(sx_left)]"; fi
sx_m_ok=$(sx_job 'local t; ms_mktemp t "$1/m" && return 0')
sx_m_code=$(sx_job 'local t; ms_mktemp t "$1/m" && return 7')
sx_m_flag=$(sx_job 'local t; ms_mktemp t "$1/m" && restore_mark_failed; return 0')
if [ "$sx_m_ok" = 0 ] && [ "$sx_m_code" = 7 ] && [ "$sx_m_flag" = 1 ]; then
    pass "restore_module_job in the background: a module that fails after registering a temporary file keeps its status (0, 7, 1)"
else fail "restore_module_job in the background: statuses [$sx_m_ok] [$sx_m_code] [$sx_m_flag], want 0, 7 and 1"; fi
# --- end: exit status of pipeline and background helpers

# --- Dialogs: hostile names must never break Pango markup ---------------------
HOSTILE='Fotos & Videos <old> "q"'
ms_env_set MINT_SETUP_BACKUPS_DIR "$TMP/root & <dir>"
: > "$ZEN/markup-issues"
ms_lib '
msg_info  "$(T_FMT "Ruta: %s" "$1")"
msg_warn  "$(T_FMT "Ruta: %s" "$1")"
msg_error "$(T_FMT "Ruta: %s" "$1")"
confirm   "$(T_FMT "Ruta: %s" "$1")"
' "$HOSTILE" >/dev/null 2>&1
ok "message dialogs received the hostile text (control)" grep -Fq -- "$HOSTILE" "$ZEN/texts"
ok "msg_info/warn/error/confirm protect dynamic text from markup parsing" test ! -s "$ZEN/markup-issues"

# Advanced -> About shows the backup folder, which may contain & or <.
: > "$ZEN/markup-issues"; rm -f "$ZEN/index"
ZENITY_LIST_CHOICES=$'6' ms_lib 'do_advanced' >/dev/null 2>&1
ok "About dialog was shown (control)" grep -Eq 'Autor: Filonux|Author: Filonux' "$ZEN/texts"
ok "About dialog escapes the backup folder path" test ! -s "$ZEN/markup-issues"

# Export shows the destination in a progress dialog (that dialog ignores --no-markup).
EXPORT_DEST="$TMP/export & <dest>"
mkdir -p "$EXPORT_DEST" "$BACKUPS/Hostile_backup"
printf 'NAME=%q\nDATE=%q\nMODULES=%q\n' 'Hostile backup' '2026-01-01' 'terminal' > "$BACKUPS/Hostile_backup/manifest.conf"
ms_env_set MINT_SETUP_BACKUPS_DIR "$BACKUPS"
: > "$ZEN/markup-issues"; rm -f "$ZEN/index"
ZENITY_FILE="$EXPORT_DEST" ms_lib '
pick_backup_dir() { printf "%s\n" "$BACKUPS_ROOT/Hostile_backup"; }
do_export_backup' >/dev/null 2>&1
ok "export reached the destination (control)" test -f "$EXPORT_DEST/Hostile_backup/manifest.conf"
ok "export progress dialog escapes the destination path" test ! -s "$ZEN/markup-issues"

# --- Main menu: no graphical session --------------------------------------------
# A real Zenity answers status 1 and prints nothing both when the user presses
# Cancel and when it cannot open the display; only the environment tells them
# apart. Cancel with a display must still exit 0 (positive control).
menu_run() {   # menu_run [ENV=VALUE...]  ->  menu_rc, menu_out, menu_err
    local saved=("${MS_ENV[@]}") kv
    rm -f "$ZEN/index"   # the scripted Zenity answers by call number
    for kv in "$@"; do ms_env_set "${kv%%=*}" "${kv#*=}"; done
    menu_out=$("${MS_ENV[@]}" bash "$SCRIPT" 2>"$TMP/menu.err"); menu_rc=$?
    menu_err=$(cat "$TMP/menu.err")
    MS_ENV=("${saved[@]}")
}
check_menu() {   # check_menu "description" expected_rc "stderr regex or -" [ENV=VALUE...]
    local desc="$1" want_rc="$2" want_err="$3"
    shift 3
    menu_run "$@"
    if [ "$menu_rc" -ne "$want_rc" ]; then
        fail "$desc (exit $menu_rc, expected $want_rc)"
    elif [ "$want_err" = - ] && [ -n "$menu_err" ]; then
        fail "$desc (unexpected stderr: $menu_err)"
    elif [ "$want_err" != - ] && ! grep -Eq -- "$want_err" <<<"$menu_err"; then
        fail "$desc (stderr was: $menu_err)"
    elif [ -n "$menu_out" ]; then
        fail "$desc (unexpected stdout: $menu_out)"
    else
        pass "$desc"
    fi
}

ZENITY_LIST_CHOICES='5' menu_run
if [ "$menu_rc" -eq 0 ] && [ -z "$menu_err" ]; then pass "menu: Exit chosen without a display exits 0 silently (control)"; else fail "menu: Exit control failed (rc=$menu_rc, stderr=$menu_err)"; fi

ZENITY_LIST_CHOICES='' menu_run
if [ "$menu_rc" -eq 0 ] && [ -z "$menu_err" ]; then pass "menu: empty answer with status 0 and no display is not an error (control)"; else fail "menu: empty-answer control failed (rc=$menu_rc, stderr=$menu_err)"; fi

ms_stub zenity 'echo 5; exit 1'
check_menu "menu: an answer printed by Zenity wins over its status (control)" 0 -
ms_stub zenity 'exit 1'
check_menu "menu: Cancel with DISPLAY set exits 0 silently (control)"         0 -  DISPLAY=:99
check_menu "menu: Cancel with WAYLAND_DISPLAY set exits 0 silently (control)" 0 -  WAYLAND_DISPLAY=wayland-0
check_menu "menu: no graphical session exits 1 with a warning on stderr (EN)" 1 'no graphical session.*DISPLAY and WAYLAND_DISPLAY'
ms_lib 'set_language es'
check_menu "menu: no graphical session exits 1 with a warning on stderr (ES)" 1 'no hay sesión gráfica.*DISPLAY y WAYLAND_DISPLAY'
ms_lib 'set_language en'

# --- --toggle-language: configuration that cannot be written -------------------
# A regular file where the configuration directory belongs makes mkdir fail even
# for root. The warning must name the path, reach stderr (Zenity is unusable
# here) and use the language still in effect, since nothing was saved.
: > "$TMP/config-blocker"
toggle_run() {   # toggle_run [ENV=VALUE...]  ->  toggle_rc, toggle_out, toggle_err
    local saved=("${MS_ENV[@]}") kv
    for kv in "$@"; do ms_env_set "${kv%%=*}" "${kv#*=}"; done
    toggle_out=$("${MS_ENV[@]}" bash "$SCRIPT" --toggle-language 2>"$TMP/toggle.err"); toggle_rc=$?
    toggle_err=$(cat "$TMP/toggle.err")
    MS_ENV=("${saved[@]}")
}
check_toggle_fail() {   # check_toggle_fail "description" "expected stderr first line" ENV=VALUE...
    local desc="$1" want="$2"
    shift 2
    toggle_run XDG_CONFIG_HOME="$TMP/config-blocker" "$@"
    if [ "$toggle_rc" -ne 1 ]; then fail "$desc (exit $toggle_rc, expected 1)"
    elif [ "$(head -n1 <<<"$toggle_err")" != "$want" ]; then fail "$desc (stderr was: $toggle_err)"
    elif ! grep -Fq -- "$TMP/config-blocker/mint-setup" <<<"$toggle_err"; then fail "$desc (path missing: $toggle_err)"
    elif [ -n "$toggle_out" ]; then fail "$desc (unexpected stdout: $toggle_out)"
    else pass "$desc"; fi
}

rm -rf -- "$CFG/mint-setup"
toggle_run DISPLAY=:99
if [ "$toggle_rc" -eq 0 ] && [ -z "$toggle_err" ] && [ "$(cat "$CFG/mint-setup/language" 2>/dev/null)" = es ]; then
    pass "--toggle-language with a writable configuration saves and continues (control)"
else
    fail "--toggle-language control failed (rc=$toggle_rc, stderr=$toggle_err)"
fi
check_toggle_fail "--toggle-language warns on stderr when the setting cannot be saved (EN)" \
    "Could not save the language setting in:"
check_toggle_fail "--toggle-language warns in the language still in effect (ES)" \
    "No se pudo guardar el idioma en:" LC_ALL=es_ES.UTF-8

# --- L key of the main menu: configuration that cannot be written ---------------
# Same blocked configuration, now through the real menu. When nothing could be
# saved the session language must not change either; one error dialog names the
# path in the language still in effect and the menu goes on (here until Exit).
tl() {   # tl CONFIG_HOME  ->  "rc=N lang=xx" of toggle_language
    local saved=("${MS_ENV[@]}")
    ms_env_set XDG_CONFIG_HOME "$1"
    ms_lib 'toggle_language; echo "rc=$? lang=$APP_LANG"' 2>/dev/null
    MS_ENV=("${saved[@]}")
}
rm -rf -- "$CFG/mint-setup"
got=$(tl "$CFG")
if [ "$got" = "rc=0 lang=es" ]; then pass "toggle_language saves and switches (control)"; else fail "toggle_language control failed ($got)"; fi
got=$(tl "$TMP/config-blocker")
if [ "$got" = "rc=1 lang=en" ]; then pass "toggle_language fails and keeps the language when it cannot save"; else fail "toggle_language kept no language ($got)"; fi

# Scripted Zenity: --list answers come from MENU_ANSWERS by --list call number
# (other dialogs do not consume answers); menus and error dialogs are recorded.
ms_stub zenity '
d=${ZENITY_CAPTURE:?}; mkdir -p "$d"
case "$*" in
    *--list*)
        n=$(cat "$d/lists" 2>/dev/null || echo 0); n=$((n + 1)); printf "%s\n" "$n" > "$d/lists"
        printf "%s\n" "$*" >> "$d/menus"
        printf "%s\n" "${MENU_ANSWERS:-}" | sed -n "${n}p" ;;
    *--error*) printf "%s\n---\n" "$*" >> "$d/errors" ;;
esac
exit 0'
lkey_run() {   # lkey_run [ENV=VALUE...]  ->  lkey_rc; Zenity captures in $ZEN/{lists,menus,errors}
    local saved=("${MS_ENV[@]}") kv
    rm -f "$ZEN/lists" "$ZEN/menus" "$ZEN/errors"
    for kv in "$@"; do ms_env_set "${kv%%=*}" "${kv#*=}"; done
    ms_env_set DISPLAY :99
    ms_env_set MENU_ANSWERS $'L\n5'   # L, then Exit
    "${MS_ENV[@]}" bash "$SCRIPT" >"$TMP/lkey.out" 2>"$TMP/lkey.err" </dev/null; lkey_rc=$?
    MS_ENV=("${saved[@]}")
}
lkey_langs() { grep -Eo 'Current language: [A-Z]+|Idioma actual: [A-Z]+' "$ZEN/menus" | paste -sd, -; }
check_lkey_fail() {   # check_lkey_fail "description" "dialog first line" "menu languages" [ENV=VALUE...]
    local desc="$1" want="$2" want_langs="$3" got_langs
    shift 3
    lkey_run XDG_CONFIG_HOME="$TMP/config-blocker" "$@"
    got_langs=$(lkey_langs)
    if [ "$lkey_rc" -ne 0 ]; then fail "$desc (exit $lkey_rc, expected 0: the menu goes on until Exit)"
    elif [ "$(grep -c -- '^--error' "$ZEN/errors" 2>/dev/null)" != 1 ]; then fail "$desc (expected exactly one error dialog)"
    elif ! grep -Fq -- "--text=$want" "$ZEN/errors"; then fail "$desc (dialog: $(head -n1 "$ZEN/errors"))"
    elif ! grep -Fq -- "$TMP/config-blocker/mint-setup" "$ZEN/errors"; then fail "$desc (path missing from the dialog)"
    elif [ "$got_langs" != "$want_langs" ]; then fail "$desc (menus showed [$got_langs], expected [$want_langs])"
    elif [ -s "$TMP/lkey.err" ]; then fail "$desc (unexpected stderr: $(cat "$TMP/lkey.err"))"
    else pass "$desc"; fi
}

rm -rf -- "$CFG/mint-setup"
lkey_run
if [ "$lkey_rc" -eq 0 ] && [ ! -e "$ZEN/errors" ] && [ "$(lkey_langs)" = "Current language: EN,Idioma actual: ES" ] \
    && [ "$(cat "$CFG/mint-setup/language" 2>/dev/null)" = es ]; then
    pass "menu: L with a writable configuration saves and switches the language (control)"
else
    fail "menu: L control failed (rc=$lkey_rc, menus: $(lkey_langs))"
fi
check_lkey_fail "menu: L warns and keeps the language when the setting cannot be saved (EN)" \
    "Could not save the language setting in:" "Current language: EN,Current language: EN"
check_lkey_fail "menu: L warns in the language still in effect (ES)" \
    "No se pudo guardar el idioma en:" "Idioma actual: ES,Idioma actual: ES" LC_ALL=es_ES.UTF-8

# --- -l together with a command line that gets rejected ------------------------
# -l used to save the new language before the rest of the line was validated, so a
# rejected line (--bogus -l, -l --purge...) exited 2 but left the language changed
# and reported its own error in it. One matrix drives the parser (ms_lib) and the
# real CLI, so their verdicts cannot drift apart: exit status, saved language and
# language of the output must all follow the parser.
# Rows: "VERDICT TOGGLES RUN ARGS...". VERDICT is ok or the rejection (unknown:ARG,
# both_actions, keep_purge, only_uninstall); TOGGLES is how many -l a valid line carries; RUN=1
# also runs the line (it ends without acting), RUN=0 only parses it.
cli_matrix=(
    "unknown:--bogus            -  1  --bogus -l"
    "unknown:--bogus            -  1  -l --bogus"
    "unknown:--toggle-languages -  1  -l --toggle-languages"
    "unknown:-x                 -  1  -l -x"
    "unknown:--bogus            -  1  -l --bogus --help"
    "both_actions               -  1  --install --uninstall"
    "both_actions               -  1  --uninstall --install"
    "both_actions               -  1  -l --install --uninstall --yes"
    "both_actions               -  1  --uninstall --purge --install"
    "both_actions               -  1  --install --keep-config --purge --uninstall"
    "unknown:--bogus            -  1  --install --uninstall --bogus"
    "only_uninstall             -  1  -l --purge"
    "only_uninstall             -  1  --purge -l"
    "only_uninstall             -  1  -l --keep-config"
    "only_uninstall             -  1  -l --install --purge"
    "keep_purge                 -  1  -l --keep-config --purge --uninstall"
    "keep_purge                 -  1  --uninstall --purge --keep-config -l"
    "ok                         0  1  --help"
    "ok                         0  1  --purge --help"
    "ok                         1  1  -l --help"
    "ok                         1  1  --help -l"
    "ok                         1  1  --toggle-language --help"
    "ok                         1  1  --help --bogus -l"
    "ok                         1  1  --help --toggle-language"
    "ok                         1  1  -l --purge --help"
    "ok                         2  1  -l -l --help"
    "ok                         3  1  -l --toggle-language -l --help"
    "ok                         1  0  -l --install"
    "ok                         1  0  -l --uninstall --purge"
    "ok                         1  0  --uninstall --keep-config -l"
    "ok                         1  0  -y -l --uninstall"
    "ok                         0  0  --install --install"
    "ok                         0  0  --uninstall --yes --uninstall"
    "ok                         0  1  --install --uninstall --help"
    "ok                         0  1  --help --uninstall --install"
    "ok                         1  1  -l --install --uninstall --help"
)

other_lang() { if [ "$1" = en ]; then echo es; else echo en; fi; }
cli_usage() {   # cli_usage LANG -> first line of --help
    if [ "$1" = en ]; then echo 'Usage: mint-setup.sh [options]'; else echo 'Uso: mint-setup.sh [opciones]'; fi
}
cli_msg() {   # cli_msg VERDICT LANG ARG -> first stderr line of a rejected line
    case "$1:$2" in
        unknown:en)        echo "Unknown option: $3" ;;
        unknown:es)        echo "Opción desconocida: $3" ;;
        both_actions:en)   echo '--install and --uninstall cannot be used together.' ;;
        both_actions:es)   echo '--install y --uninstall no se pueden usar juntos.' ;;
        keep_purge:en)     echo '--purge and --keep-config cannot be used together.' ;;
        keep_purge:es)     echo '--purge y --keep-config no se pueden usar juntos.' ;;
        only_uninstall:en) echo 'These options only work with --uninstall.' ;;
        only_uninstall:es) echo 'Estas opciones solo se usan con --uninstall.' ;;
    esac
}
cli_run() {   # cli_run SEED ARGS...  ->  cli_rc, cli_out, cli_err, cli_saved (SEED: - = clean, en|es = saved)
    local seed="$1" saved=("${MS_ENV[@]}")
    shift
    rm -rf -- "$TMP/cfg-cli"
    if [ "$seed" != - ]; then
        mkdir -p "$TMP/cfg-cli/mint-setup"
        printf '%s\n' "$seed" > "$TMP/cfg-cli/mint-setup/language"
    fi
    ms_env_set XDG_CONFIG_HOME "$TMP/cfg-cli"
    cli_out=$("${MS_ENV[@]}" bash "$SCRIPT" "$@" 2>"$TMP/cli.err" </dev/null); cli_rc=$?
    cli_err=$(cat "$TMP/cli.err")
    cli_saved=$(cat "$TMP/cfg-cli/mint-setup/language" 2>/dev/null || echo -)
    MS_ENV=("${saved[@]}")
}
cli_row() {   # cli_row "VERDICT TOGGLES RUN ARGS..."
    local verdict toggles run rest args=() line want got seed lang0 lang1 want_saved first i msg good=1
    read -r verdict toggles run rest <<<"$1"
    read -ra args <<<"$rest"
    line="${args[*]}"
    want=$verdict
    if [ "$verdict" = ok ]; then want="ok $toggles"; fi
    got=$(ms_lib 'cli_parse_args "$@"; if [ -z "$CLI_ERR" ]; then printf "ok %s" "$CLI_TOGGLE"
else printf "%s%s" "$CLI_ERR" "${CLI_ERR_ARG:+:$CLI_ERR_ARG}"; fi' "${args[@]}" 2>/dev/null)
    if [ "$got" != "$want" ]; then fail "-l matrix [$line]: the parser said [$got], expected [$want]"; good=0; fi
    if [ "$run" -eq 1 ]; then
        for seed in - es; do
            lang0=en; [ "$seed" = es ] && lang0=es
            cli_run "$seed" "${args[@]}"
            msg=""
            if [ "$verdict" = ok ]; then
                lang1=$lang0
                for ((i = 0; i < toggles; i++)); do lang1=$(other_lang "$lang1"); done
                want_saved=$seed
                if [ "$toggles" -gt 0 ]; then want_saved=$lang1; fi
                first=$(head -n1 <<<"$cli_out")
                if [ "$cli_rc" -ne 0 ]; then msg="exit $cli_rc, expected 0"
                elif [ "$first" != "$(cli_usage "$lang1")" ]; then msg="help was [$first], expected it in $lang1"
                elif [ "$cli_saved" != "$want_saved" ]; then msg="saved language [$cli_saved], expected [$want_saved]"
                elif [ -n "$cli_err" ]; then msg="unexpected stderr: $cli_err"
                fi
            else
                first=$(head -n1 <<<"$cli_err")
                if [ "$cli_rc" -ne 2 ]; then msg="exit $cli_rc, expected 2"
                elif [ "$cli_saved" != "$seed" ]; then msg="saved language became [$cli_saved] (was [$seed])"
                elif [ "$first" != "$(cli_msg "${verdict%%:*}" "$lang0" "${verdict#*:}")" ]; then msg="stderr was [$first], expected it in $lang0"
                elif [ -n "$cli_out" ]; then msg="unexpected stdout: $cli_out"
                fi
            fi
            if [ -n "$msg" ]; then fail "-l matrix [$line] with saved language [$seed]: $msg"; good=0; fi
        done
    fi
    if [ "$good" -eq 1 ] && [ "$verdict" = ok ]; then
        pass "-l line accepted with $toggles toggle(s): $line"
    elif [ "$good" -eq 1 ]; then
        pass "-l line rejected as ${verdict%%:*}, nothing saved: $line"
    fi
}
for row in "${cli_matrix[@]}"; do cli_row "$row"; done

# Valid lines that act: -l takes effect before the action runs.
cli_run - -l --install
if [ "$cli_rc" -eq 0 ] && [ "$cli_saved" = es ] && grep -Fq 'Instalación completada' <<<"$cli_out" \
    && [ -x "$HOME_DIR/.local/bin/mint-setup" ]; then
    pass "-l --install: saves the language and reports the installation in it"
else
    fail "-l --install (rc=$cli_rc, saved=$cli_saved, out: $cli_out, err: $cli_err)"
fi
cli_run es -l --uninstall --yes
if [ "$cli_rc" -eq 0 ] && [ "$cli_saved" = en ] && grep -Fq 'Uninstall complete. Your settings were kept:' <<<"$cli_out" \
    && [ ! -e "$HOME_DIR/.local/bin/mint-setup" ]; then
    pass "-l --uninstall --yes: saves the language and reports the uninstall in it"
else
    fail "-l --uninstall --yes (rc=$cli_rc, saved=$cli_saved, out: $cli_out, err: $cli_err)"
fi

# --install with --uninstall: the last one used to win without a word, so
# "--install --uninstall --yes" uninstalled and "--uninstall --install" installed.
# The usage line is "--install | --uninstall": a line with both is rejected (exit 2)
# and neither action runs, in either order and with the program installed or not.
cli_run - --uninstall --install
if [ "$cli_rc" -eq 2 ] && [ ! -e "$HOME_DIR/.local/bin/mint-setup" ] && [ ! -e "$HOME_DIR/.local/share/mint-setup" ]; then
    pass "--uninstall --install on a clean HOME installs nothing"
else
    fail "--uninstall --install on a clean HOME (rc=$cli_rc, out: $cli_out, err: $cli_err)"
fi
cli_run - --install
for both_line in "--install --uninstall --yes" "--uninstall --install --yes"; do
    read -ra both_args <<<"$both_line"
    before=$(cd "$HOME_DIR" && find .local -type f -exec sha256sum {} + | sort)
    cli_run en "${both_args[@]}"
    after=$(cd "$HOME_DIR" && find .local -type f -exec sha256sum {} + 2>/dev/null | sort)
    if [ "$cli_rc" -eq 2 ] && [ -n "$before" ] && [ "$before" = "$after" ] \
        && [ "$cli_err" = '--install and --uninstall cannot be used together.' ] && [ -z "$cli_out" ]; then
        pass "installed program, $both_line: rejected (exit 2), nothing removed or rewritten"
    else
        fail "installed program, $both_line (rc=$cli_rc, err: $cli_err, out: $cli_out, files changed: $([ "$before" = "$after" ] && echo no || echo yes))"
    fi
done
cli_run - --uninstall --yes   # leave the shared HOME clean for what follows

# Every option --help documents must be accepted by the parser (the usage text and
# the parser are separate lists); an option nobody documented must not be.
mapfile -t documented < <(ms_lib 'print_usage' | grep -oE '^  -[^ ,]+(, -[^ ,]+)*' | tr -d ',' | tr ' ' '\n' | grep .)
# The options travel inside the code, not as ms_lib arguments: ms_lib sources the program
# with its own arguments, and a --version among them would make it print the version and exit.
rejected=$(ms_lib "for o in $(printf '%q ' "${documented[@]}"); do cli_parse_args \"\$o\" || cli_parse_args --uninstall \"\$o\" || printf '%s ' \"\$o\"; done")
if [ "${#documented[@]}" -ge 11 ] && [ -z "$rejected" ]; then
    pass "the parser accepts every option --help documents (${#documented[@]} options)"
else
    fail "options found in --help: ${#documented[@]} (expected at least 11); rejected by the parser: [$rejected]"
fi
ok "the parser rejects an option --help does not document (control)" ms_lib '! cli_parse_args --uninstall --undocumented'

# --- The backup folder is only created when the program is going to use it -----
# --help, --version, rejected lines, --install and --uninstall used to leave
# ~/MintSetupBackups behind (and exited 1 when a plain file sat in its place): the
# block that creates it ran before run_cli_action. ms_init creates $BACKUPS up
# front, so nothing saw it; here the path points to a folder that does not exist.
bk_dir="$TMP/bk-new"
bk_run() {   # bk_run STATE ARGS...  ->  bk_rc, bk_out, bk_err (STATE: absent | file | dir755)
    local state="$1" saved=("${MS_ENV[@]}")
    shift
    rm -rf -- "$bk_dir" "$TMP/cfg-bk" "$ZEN/lists" "$ZEN/menus" "$ZEN/errors"
    case "$state" in
        file) : > "$bk_dir" ;;
        dir755) mkdir -m 755 "$bk_dir"; echo keep > "$bk_dir/keep.txt" ;;
    esac
    ms_env_set MINT_SETUP_BACKUPS_DIR "$bk_dir"
    ms_env_set XDG_CONFIG_HOME "$TMP/cfg-bk"
    bk_out=$("${MS_ENV[@]}" bash "$SCRIPT" "$@" 2>"$TMP/bk.err" </dev/null); bk_rc=$?
    bk_err=$(cat "$TMP/bk.err")
    MS_ENV=("${saved[@]}")
}
bk_menu() {   # bk_menu STATE [ENV=VALUE...]: opens the menu (Zenity scripted: Exit) and runs the program
    local state="$1" saved=("${MS_ENV[@]}") kv
    shift
    ms_env_set DISPLAY :99
    ms_env_set MENU_ANSWERS 5
    for kv in "$@"; do ms_env_set "${kv%%=*}" "${kv#*=}"; done
    bk_run "$state"
    MS_ENV=("${saved[@]}")
}

# Rows: "EXIT_CODE ARGS...". Each runs with the folder absent and with a file in its place.
bk_matrix=(
    "0 --version"
    "0 --help"
    "0 -l --help"
    "0 --purge --help"
    "2 --bogus"
    "2 -l --bogus"
    "2 --purge"
    "2 --keep-config"
    "2 --uninstall --purge --keep-config"
    "0 --install"
    "0 --uninstall --yes"
    "0 --uninstall --yes --purge"
)
for row in "${bk_matrix[@]}"; do
    read -r want_rc rest <<<"$row"
    read -ra bk_args <<<"$rest"
    msg=""
    for state in absent file; do
        bk_run "$state" "${bk_args[@]}"
        if [ "$bk_rc" -ne "$want_rc" ]; then msg="exit $bk_rc, expected $want_rc"
        elif [ "$state" = absent ] && [ -e "$bk_dir" ]; then msg="created the backup folder"
        elif [ "$state" = file ] && [ ! -f "$bk_dir" ]; then msg="replaced the file standing in its place"
        elif grep -Fq 'backup folder' <<<"$bk_err"; then msg="complained about the backup folder: $bk_err"
        fi
        if [ -n "$msg" ]; then msg="[$state] $msg"; break; fi
    done
    if [ -z "$msg" ]; then pass "backup folder: [$rest] neither creates it nor needs it"; else fail "backup folder: [$rest] $msg"; fi
done

# Controls: when the program does go on to use the backups, the folder is created
# private, an existing one keeps its content and becomes private too, and a file in
# its place is still an error.
bk_mode() { stat -c %a -- "$bk_dir" 2>/dev/null; }
bk_menu absent
if [ "$bk_rc" -eq 0 ] && [ -d "$bk_dir" ] && [ "$(bk_mode)" = 700 ]; then
    pass "backup folder: opening the program creates it with mode 700 (control)"
else
    fail "backup folder: opening the program (rc=$bk_rc, mode=$(bk_mode), err: $bk_err)"
fi
bk_menu dir755
if [ "$bk_rc" -eq 0 ] && [ "$(bk_mode)" = 700 ] && [ "$(cat "$bk_dir/keep.txt" 2>/dev/null)" = keep ]; then
    pass "backup folder: an existing one keeps its content and becomes private (control)"
else
    fail "backup folder: existing folder (rc=$bk_rc, mode=$(bk_mode), err: $bk_err)"
fi
rm -rf -- "$bk_dir"
bk_saved=("${MS_ENV[@]}")
ms_env_set MINT_SETUP_BACKUPS_DIR "$bk_dir"
ms_lib 'true' >/dev/null 2>&1; bk_rc=$?
MS_ENV=("${bk_saved[@]}")
if [ "$bk_rc" -eq 0 ] && [ "$(bk_mode)" = 700 ]; then
    pass "backup folder: loading the program as a library still creates it (same point in test mode)"
else
    fail "backup folder: library mode (rc=$bk_rc, mode=$(bk_mode))"
fi

check_bk_fail() {   # check_bk_fail "description" "dialog first line" STATE [ENV=VALUE...]
    local desc="$1" want="$2" state="$3"
    shift 3
    bk_menu "$state" "$@"
    if [ "$bk_rc" -ne 1 ]; then fail "$desc (exit $bk_rc, expected 1)"
    elif [ "$(grep -c -- '^--error' "$ZEN/errors" 2>/dev/null)" != 1 ]; then fail "$desc (expected exactly one error dialog)"
    elif ! grep -Fq -- "--text=$want" "$ZEN/errors"; then fail "$desc (dialog: $(head -n1 "$ZEN/errors"))"
    elif ! grep -Fq -- "$bk_dir" "$ZEN/errors"; then fail "$desc (path missing from the dialog)"
    elif [ -e "$ZEN/menus" ]; then fail "$desc (the menu opened anyway)"
    else pass "$desc"; fi
}
check_bk_fail "backup folder: a file in its place stops the program with one warning (EN)" \
    "Could not create (or write to) the backup folder:" file
[ -f "$bk_dir" ] || fail "backup folder: the file in its place was replaced"
check_bk_fail "backup folder: a file in its place stops the program with one warning (ES)" \
    "No se pudo crear (o escribir en) la carpeta de copias de seguridad:" file LC_ALL=es_ES.UTF-8
mkdir -p "$TMP/bin-nochmod"
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin-nochmod/chmod"; chmod +x "$TMP/bin-nochmod/chmod"
check_bk_fail "backup folder: stops with one warning when it cannot be made private (EN)" \
    "Could not ensure that the backup folder has private permissions (700):" absent "PATH=$TMP/bin-nochmod:$MOCK:$SAFE_PATH"
check_bk_fail "backup folder: stops with one warning when it cannot be made private (ES)" \
    "No se pudo asegurar que la carpeta de copias de seguridad tenga permisos privados (700):" absent \
    "PATH=$TMP/bin-nochmod:$MOCK:$SAFE_PATH" LC_ALL=es_ES.UTF-8

# --uninstall only reports "kept" for a folder that was there before the program ran.
bk_run absent --install
bk_run absent --uninstall --yes
if [ "$bk_rc" -eq 0 ] && grep -Fq 'Uninstall complete. No Mint-Setup files are left.' <<<"$bk_out" \
    && ! grep -Fq 'Kept:' <<<"$bk_out" && [ ! -e "$bk_dir" ]; then
    pass "--install then --uninstall --yes on a clean account: nothing is reported as kept"
else
    fail "--uninstall --yes on a clean account (rc=$bk_rc, out: $bk_out, err: $bk_err)"
fi
bk_run dir755 --uninstall --yes
if [ "$bk_rc" -eq 0 ] && grep -Fq 'Uninstall complete. Your settings were kept:' <<<"$bk_out" \
    && grep -Fxq "  • Kept: $bk_dir" <<<"$bk_out" && [ "$(cat "$bk_dir/keep.txt" 2>/dev/null)" = keep ]; then
    pass "--uninstall --yes keeps a backup folder that already existed and reports it (control)"
else
    fail "--uninstall --yes with an existing folder (rc=$bk_rc, out: $bk_out, err: $bk_err)"
fi

# --- Missing tools: the program stops before creating the backup folder --------
# check_dependencies used to run after ensure_backups_root, so a run that failed for
# lack of tools left the folder behind and, with a file in its place, reported the
# folder instead of the tools. Hiding a command needs a PATH without it: each
# directory below links the sandbox stubs and the host commands except the hidden
# one (- hides nothing), so the result does not depend on what the host has installed.
mk_path_without() {   # mk_path_without TOOL DIR
    rm -rf -- "$2"; mkdir -p "$2"
    find "$MOCK" /usr/bin /bin -mindepth 1 -maxdepth 1 ! -type d ! -name "$1" \
        -exec ln -s -t "$2" -- {} + 2>/dev/null || true
}
mk_path_without zenity "$TMP/bin-nozenity"
mk_path_without dconf  "$TMP/bin-nodconf"
mk_path_without -      "$TMP/bin-all"
tools_head="Required tools are missing to run Mint-Setup:"

bk_menu absent "PATH=$TMP/bin-all"
if [ "$bk_rc" -eq 0 ] && [ "$(bk_mode)" = 700 ]; then
    pass "backup folder: a PATH that hides no tool still creates it (control)"
else
    fail "backup folder: control PATH (rc=$bk_rc, mode=$(bk_mode), err: $bk_err)"
fi

# Without Zenity the warning goes to stderr: first line and the missing tool, nothing else.
bk_menu absent "PATH=$TMP/bin-nozenity"
if [ "$bk_rc" -ne 1 ]; then fail "backup folder: without Zenity (exit $bk_rc, expected 1)"
elif [ -e "$bk_dir" ]; then fail "backup folder: without Zenity the program created it"
elif [ "$(sed -n 1p <<<"$bk_err")" != "$tools_head" ] || [ "$(sed -n 2p <<<"$bk_err")" != zenity ]; then
    fail "backup folder: without Zenity (stderr: $bk_err)"
else pass "backup folder: without Zenity the program stops on the missing tool and does not create it"; fi

bk_menu file "PATH=$TMP/bin-nozenity"
if [ "$bk_rc" -ne 1 ]; then fail "backup folder: without Zenity and a file in its place (exit $bk_rc, expected 1)"
elif [ ! -f "$bk_dir" ]; then fail "backup folder: without Zenity the file standing in its place was replaced"
elif [ "$(sed -n 1p <<<"$bk_err")" != "$tools_head" ] || grep -Fq 'backup folder' <<<"$bk_err"; then
    fail "backup folder: without Zenity and a file in its place (stderr: $bk_err)"
else pass "backup folder: without Zenity the missing tool is reported before a file in its place"; fi

# With Zenity present, a different missing tool is reported in one dialog and the menu never opens.
bk_menu absent "PATH=$TMP/bin-nodconf"
if [ "$bk_rc" -ne 1 ]; then fail "backup folder: without dconf (exit $bk_rc, expected 1)"
elif [ -e "$bk_dir" ]; then fail "backup folder: without dconf the program created it"
elif [ "$(grep -c -- '^--error' "$ZEN/errors" 2>/dev/null)" != 1 ] || [ -e "$ZEN/menus" ]; then
    fail "backup folder: without dconf (expected one error dialog and no menu)"
elif ! grep -Fq -- "--text=$tools_head" "$ZEN/errors" || [ "$(sed -n 2p "$ZEN/errors")" != dconf ]; then
    fail "backup folder: without dconf (dialog: $(head -n2 "$ZEN/errors" | tr '\n' ' '))"
else pass "backup folder: without dconf one dialog names the tool and the program does not create it"; fi

# The checks that come first must not need Zenity: --help and --version still work without it.
deps_saved=("${MS_ENV[@]}")
for opt in --help --version; do
    ms_env_set PATH "$TMP/bin-nozenity"
    bk_run absent "$opt"
    MS_ENV=("${deps_saved[@]}")
    if [ "$bk_rc" -eq 0 ] && [ -n "$bk_out" ] && [ -z "$bk_err" ] && [ ! -e "$bk_dir" ]; then
        pass "backup folder: [$opt] works without Zenity and creates nothing"
    else
        fail "backup folder: [$opt] without Zenity (rc=$bk_rc, stderr: $bk_err)"
    fi
done

# --- Minimum bash version: the first command of the script ----------------------
# bash 4.3 treats an empty array as unset under "set -u", so "${a[@]}" on one aborts with
# "unbound variable" halfway through a save or restore; 4.4 fixed that. The program stops at
# its first command on anything older, and the badge, both READMEs and CONTRIBUTING say 4.4.
# The guard is plain syntax that every bash parses, and it comes before "set -u", umask and
# any file access. BASH_VERSINFO is read-only, so the guard is cut out of the script and run
# with its names swapped for plain variables: the real condition and messages, fed other
# versions. A rejection prints both messages (English, Spanish) on stderr and exits 1.
bv_code=$(awk '/^if \[ "\$\{BASH_VERSINFO\[0\]\}"/ { on = 1 } on { print } on && /^fi$/ { exit }' "$SCRIPT" \
    | sed -e 's/BASH_VERSINFO\[0\]/BV_MAJOR/g' -e 's/BASH_VERSINFO\[1\]/BV_MINOR/g' -e 's/BASH_VERSION/BV_TEXT/g')
bv_run() {   # bv_run MAJOR MINOR TEXT: runs the guard as that bash; sets bv_rc, bv_out and bv_err
    bv_err=$(env BV_MAJOR="$1" BV_MINOR="$2" BV_TEXT="$3" bash -c "$bv_code"$'\necho reached' 2>&1 >"$TMP/bv-out"); bv_rc=$?
    bv_out=$(cat "$TMP/bv-out")
}
if [ -n "$bv_code" ] && ! grep -q 'BASH_VERS' <<<"$bv_code" \
    && grep -q 'BV_MAJOR' <<<"$bv_code" && grep -q 'BV_MINOR' <<<"$bv_code" && grep -q 'BV_TEXT' <<<"$bv_code"; then
    pass "bash guard: found in the script, ready to run as other versions"
else fail "bash guard: block not found in script/mint-setup.sh, or it still names a real version variable"; fi
for row in "3 2 3.2.57" "4 0 4.0.44" "4 1 4.1.17" "4 2 4.2.53" "4 3 4.3.48"; do
    read -r bv_maj bv_min bv_ver <<<"$row"
    bv_run "$bv_maj" "$bv_min" "$bv_ver(1)-release"
    bv_want="Mint-Setup needs bash 4.4 or newer; this is bash $bv_ver(1)-release."$'\n'"Mint-Setup necesita bash 4.4 o superior; esta es bash $bv_ver(1)-release."
    if [ "$bv_rc" = 1 ] && [ -z "$bv_out" ] && [ "$bv_err" = "$bv_want" ]; then
        pass "bash guard: $bv_ver is rejected (exit 1, both messages, the script does not go on)"
    else fail "bash guard: $bv_ver: rc=$bv_rc, stdout [$bv_out], stderr [$bv_err]"; fi
done
# 4.10 is not a real release: it checks that the minor version is compared as a number.
for row in "4 4 4.4.20" "4 10 4.10.0" "5 0 5.0.17" "5 1 5.1.16" "5 2 5.2.21" "5 3 5.3.0" "10 0 10.0.0"; do
    read -r bv_maj bv_min bv_ver <<<"$row"
    bv_run "$bv_maj" "$bv_min" "$bv_ver(1)-release"
    if [ "$bv_rc" = 0 ] && [ "$bv_out" = reached ] && [ -z "$bv_err" ]; then
        pass "bash guard: $bv_ver is accepted (silent, the script goes on)"
    else fail "bash guard: $bv_ver: rc=$bv_rc, stdout [$bv_out], stderr [$bv_err]"; fi
done
bv_first=$(awk '/^[[:space:]]*#/ { next } /^[[:space:]]*$/ { next } { print NR; exit }' "$SCRIPT")
bv_start=$(awk '/^if \[ "\$\{BASH_VERSINFO\[0\]\}"/ { print NR; exit }' "$SCRIPT")
bv_end=$(awk -v s="${bv_start:-0}" 'NR > s && /^fi$/ { print NR; exit }' "$SCRIPT")
bv_next=$(awk '/^(set |umask |trap )/ { print NR; exit }' "$SCRIPT")
if [ -n "$bv_start" ] && [ "$bv_first" = "$bv_start" ] && [ -n "$bv_end" ] && [ -n "$bv_next" ] && [ "$bv_end" -lt "$bv_next" ]; then
    pass "bash guard: it is the first command of the script, before set, umask and trap"
else fail "bash guard: first command at line [$bv_first], guard at [$bv_start] to [$bv_end], first set/umask/trap at [$bv_next]"; fi
# --- end: minimum bash version

# --- HOME not usable: the program stops before touching anything ----------------
# An unset HOME made bash die with "HOME: unbound variable" and an empty one let the
# program carry on with every path hanging from "/" (--uninstall --yes ran without a
# word). home_check/require_home now stop every line that goes on to use $HOME, before
# -l can write anything, and accept only an absolute path to an existing directory.
# --help, --version and rejected lines never use it, so they work whatever HOME holds.
# Everything runs through the real CLI with the sandbox environment minus its HOME
# (env cannot unset a variable after an assignment, hence hm_env), from a scratch
# working directory, and each run is compared against a before/after snapshot of every
# place the program could write: that directory, HOME, the configuration and the backups.
# A saved language wins over LC_ALL, and earlier sections leave one behind: it is set aside
# here (and put back at the end) so that LC_ALL alone decides the language of each run.
hm_saved=("${MS_ENV[@]}")
cp -p "$MOCK/zenity" "$TMP/zenity.keep"
rm -rf -- "$TMP/cfg.keep"
if [ -d "$CFG/mint-setup" ]; then cp -a "$CFG/mint-setup" "$TMP/cfg.keep"; fi
rm -rf -- "$CFG/mint-setup"
HM_EXTRA=()
HM_CWD="$TMP/hm-cwd"; mkdir -p "$HM_CWD/reldir"   # reldir: a relative HOME that does exist
: > "$TMP/hm-file"
ln -s "$HOME_DIR" "$TMP/hm-link"
# Zenity records the HOME it sees and its error dialogs; HM_ZEN_RC=1 (default) behaves
# like a missing display, so startup_error falls back to stderr; 0 shows the dialog.
ms_stub zenity 'd=${ZENITY_CAPTURE:?}; mkdir -p "$d"
printf "%s\n" "${HOME-<unset>}" >> "$d/hm-home"
case "$*" in *--error*) printf "%s\n---\n" "$*" >> "$d/hm-errors" ;; esac
exit "${HM_ZEN_RC:-1}"'

hm_env() {   # hm_env unset|VALUE [ENV=VALUE...]  ->  HM_ENV: the sandbox with another HOME
    local spec="$1" e
    shift
    HM_ENV=("${MS_ENV[0]}")
    if [ "$spec" = unset ]; then HM_ENV+=(-u HOME); fi
    for e in "${MS_ENV[@]:1}"; do
        case "$e" in
            HOME=*) ;;
            XDG_CONFIG_HOME=*|MINT_SETUP_BACKUPS_DIR=*) [ "${HM_NO_XDG:-0}" = 1 ] || HM_ENV+=("$e") ;;
            *) HM_ENV+=("$e") ;;
        esac
    done
    if [ "$spec" != unset ]; then HM_ENV+=("HOME=$spec"); fi
    HM_ENV+=("$@")
}
hm_snap() {   # every writable place, with file contents
    local d
    for d in "$HM_CWD" "$HOME_DIR" "$CFG" "$BACKUPS"; do
        ms_tree "$d"
        (cd "$d" && find . -type f -exec cksum {} + 2>/dev/null | LC_ALL=C sort)
    done
}
hm_run() {   # hm_run SPEC LANG ARGS...  ->  hm_rc, hm_out, hm_err, hm_changed (SPEC: unset | value)
    local spec="$1" lang="$2" before after
    shift 2
    hm_env "$spec" "LC_ALL=$lang" ${HM_EXTRA[@]+"${HM_EXTRA[@]}"}
    before=$(hm_snap)
    hm_out=$(cd "$HM_CWD" && "${HM_ENV[@]}" bash "$SCRIPT" "$@" 2>"$TMP/hm.err" </dev/null); hm_rc=$?
    hm_err=$(cat "$TMP/hm.err")
    after=$(hm_snap)
    hm_changed=0
    if [ "$before" != "$after" ]; then hm_changed=1; fi
}
hm_first() {   # hm_first KIND LANG -> expected first line of the warning
    case "$1:$2" in
        empty:en)    echo 'HOME is not set (or is empty), so Mint-Setup does not know which folder is your home.' ;;
        empty:es)    echo 'HOME no está definida (o está vacía), así que Mint-Setup no sabe cuál es tu carpeta personal.' ;;
        relative:en) echo 'HOME is not an absolute path:' ;;
        relative:es) echo 'HOME no es una ruta absoluta:' ;;
        not_dir:en)  echo 'HOME does not point to an existing folder:' ;;
        not_dir:es)  echo 'HOME no apunta a una carpeta existente:' ;;
    esac
}
hm_last() {   # hm_last KIND LANG -> expected last line of the warning
    case "$1:$2" in
        empty:en)  echo 'Run it as your normal user, from a session where HOME points to your home folder.' ;;
        empty:es)  echo 'Ejecútalo como tu usuario normal, desde una sesión en la que HOME apunte a tu carpeta personal.' ;;
        *:en)      echo 'Run Mint-Setup as your normal user, from a session where HOME points to your home folder.' ;;
        *:es)      echo 'Ejecuta Mint-Setup como tu usuario normal, desde una sesión en la que HOME apunte a tu carpeta personal.' ;;
    esac
}
check_home() {   # check_home "description" KIND SPEC LANGS ARGS...  (stderr channel)
    local desc="$1" kind="$2" spec="$3" langs="$4" code lang
    shift 4
    for code in $langs; do
        case "$code" in en) lang=en_US.UTF-8 ;; *) lang=es_ES.UTF-8 ;; esac
        hm_run "$spec" "$lang" "$@"
        if [ "$hm_rc" -ne 1 ]; then fail "$desc [$code] (exit $hm_rc, expected 1; stderr: $hm_err)"
        elif [ "$(sed -n 1p <<<"$hm_err")" != "$(hm_first "$kind" "$code")" ]; then fail "$desc [$code] (stderr: $hm_err)"
        elif [ "$kind" != empty ] && [ "$(sed -n 2p <<<"$hm_err")" != "$spec" ]; then fail "$desc [$code] (the HOME value is not shown: $hm_err)"
        elif [ "$(tail -n1 <<<"$hm_err")" != "$(hm_last "$kind" "$code")" ]; then fail "$desc [$code] (last line: $(tail -n1 <<<"$hm_err"))"
        elif [ -n "$hm_out" ]; then fail "$desc [$code] (unexpected stdout: $hm_out)"
        elif [ "$hm_changed" -ne 0 ]; then fail "$desc [$code] (it wrote something)"
        else pass "$desc [$code]"; fi
    done
}

# Every kind of unusable HOME, in both languages, through --uninstall --yes (the line
# that used to run on "/" without a word).
hm_states=(
    "unset|empty|unset"
    "empty|empty|"
    "dot|relative|."
    "tilde|relative|~"
    "existing relative folder|relative|reldir"
    "missing folder|not_dir|/nonexistent-mint-setup-home"
    "regular file|not_dir|$TMP/hm-file"
)
for row in "${hm_states[@]}"; do
    IFS='|' read -r label kind spec <<<"$row"
    check_home "HOME $label stops --uninstall --yes with the $kind warning" "$kind" "$spec" "en es" --uninstall --yes
done

# Every line that goes on to use $HOME stops, whatever the action (the first two kinds
# of HOME and an existing relative one, in English).
for spec in unset "" reldir; do
    case "$spec" in unset) kind=empty ;; "") kind=empty ;; *) kind=relative ;; esac
    for act in "" "--install" "--uninstall" "--uninstall --purge --yes" "--uninstall --keep-config" "-l" "--toggle-language" "-l --help"; do
        # shellcheck disable=SC2086  # $act is a list of options on purpose
        check_home "HOME [${spec:-empty}] stops [${act:-no options}]" "$kind" "$spec" en $act
    done
done

# Without XDG_CONFIG_HOME and MINT_SETUP_BACKUPS_DIR every path hangs from $HOME (with
# them set, $HOME is not even expanded). An unset HOME used to die right there with
# "HOME: unbound variable"; -l would save under it, and with an existing relative HOME
# that is inside the scratch directory, so a guard that let it through is caught here.
HM_NO_XDG=1 check_home "HOME unset without XDG variables: stopped with the warning" empty unset "en es" --uninstall --yes
HM_NO_XDG=1 check_home "HOME unset without XDG variables: the menu is not reached" empty unset en
HM_NO_XDG=1 check_home "HOME relative without XDG variables: -l saves nothing" relative reldir "en es" -l
ok "no configuration appeared under the relative HOME" test ! -e "$HM_CWD/reldir/.config"

# -l with a configuration directory that does work: the saved language must stay.
mkdir -p "$CFG/mint-setup"; printf 'es\n' > "$CFG/mint-setup/language"
hm_run "" en_US.UTF-8 -l
if [ "$hm_rc" -eq 1 ] && [ "$(cat "$CFG/mint-setup/language")" = es ] && [ "$hm_changed" -eq 0 ]; then
    pass "-l with an empty HOME keeps the saved language"
else fail "-l with an empty HOME changed the language (rc=$hm_rc, saved=$(cat "$CFG/mint-setup/language"))"; fi
rm -rf -- "$CFG/mint-setup"

# --help, --version and rejected lines do not use HOME: same verdict as with a good one.
# Rows: "EXIT KIND LINE...", KIND = help | version | rejected.
hm_free=(
    "0 help     --help"
    "0 help     --purge --help"
    "0 version  --version"
    "2 rejected --bogus"
    "2 rejected --purge"
    "2 rejected --keep-config"
    "2 rejected --uninstall --keep-config --purge"
    "2 rejected -l --bogus"
    "2 rejected --bogus -l"
)
for spec in unset "" reldir /nonexistent-mint-setup-home; do
    for row in "${hm_free[@]}"; do
        read -r want_rc kind line <<<"$row"
        # shellcheck disable=SC2086  # $line is a list of options on purpose
        hm_run "$spec" en_US.UTF-8 $line
        good=1
        case "$kind" in
            help)     [ "$(head -n1 <<<"$hm_out")" = 'Usage: mint-setup.sh [options]' ] || good=0 ;;
            version)  grep -Eq '^Mint-Setup [0-9]+\.[0-9]+\.[0-9]+$' <<<"$hm_out" || good=0 ;;
            rejected) [ -z "$hm_out" ] && [ -n "$hm_err" ] || good=0 ;;
        esac
        if [ "$hm_rc" -ne "$want_rc" ] || [ "$good" -ne 1 ]; then
            fail "[$line] with HOME [${spec:-empty}] (exit $hm_rc, expected $want_rc; out: $hm_out; err: $hm_err)"
        elif grep -q 'HOME' <<<"$hm_out$hm_err"; then fail "[$line] with HOME [${spec:-empty}] mentions HOME: $hm_out$hm_err"
        elif [ "$hm_changed" -ne 0 ]; then fail "[$line] with HOME [${spec:-empty}] wrote something"
        else pass "[$line] works with HOME [${spec:-empty}] and writes nothing"; fi
    done
done

# The warning also reaches the user as a dialog, shown without HOME: GTK keeps its cache
# under it and, empty or relative, would create ".cache" in the current directory.
for spec in unset "" reldir /nonexistent-mint-setup-home; do
    rm -f "$ZEN/hm-home" "$ZEN/hm-errors"
    HM_EXTRA=(HM_ZEN_RC=0)
    hm_run "$spec" en_US.UTF-8
    HM_EXTRA=()
    if [ "$hm_rc" -ne 1 ] || [ -n "$hm_err" ] || [ -n "$hm_out" ]; then
        fail "dialog with HOME [${spec:-empty}] (exit $hm_rc; stdout: $hm_out; stderr: $hm_err)"
    elif [ "$(grep -c -- '^--error' "$ZEN/hm-errors" 2>/dev/null)" != 1 ] || ! grep -Fq -- '--no-markup' "$ZEN/hm-errors"; then
        fail "dialog with HOME [${spec:-empty}] (expected one --no-markup error dialog: $(head -n1 "$ZEN/hm-errors" 2>/dev/null))"
    elif [ "$(cat "$ZEN/hm-home")" != '<unset>' ]; then fail "dialog with HOME [${spec:-empty}]: Zenity saw HOME=$(cat "$ZEN/hm-home")"
    elif [ "$hm_changed" -ne 0 ]; then fail "dialog with HOME [${spec:-empty}] wrote something"
    else pass "HOME [${spec:-empty}]: one dialog, shown without HOME, stderr empty, nothing written"; fi
done

# Controls: a usable HOME is not stopped (a plain folder, a link to one, a trailing slash).
for spec in "$HOME_DIR" "$TMP/hm-link" "$HOME_DIR/"; do
    hm_run "$spec" en_US.UTF-8 --uninstall --yes
    if [ "$hm_rc" -eq 0 ] && [ "$(head -n1 <<<"$hm_out")" = 'Nothing to uninstall: Mint-Setup is not installed.' ] \
        && ! grep -q 'HOME' <<<"$hm_err"; then
        pass "control: HOME [${spec//"$TMP"/<tmp>}] is accepted"
    else fail "control: HOME [$spec] (exit $hm_rc; out: $hm_out; err: $hm_err)"; fi
done

# home_check itself, without the CLI: verdict and kind. "/" is absolute and exists, so it
# is accepted on purpose (a normal user with HOME=/ gets permission errors, not guesses).
hc() {   # hc VALUE|unset -> "rc=N err=KIND"
    if [ "$1" = unset ]; then ms_lib 'unset HOME; home_check; echo "rc=$? err=$HOME_ERR"' 2>&1
    else ms_lib 'HOME=$1; home_check; echo "rc=$? err=$HOME_ERR"' "$1" 2>&1; fi
}
while IFS='|' read -r spec want; do
    got=$(hc "$spec")
    name=${spec//"$TMP"/<tmp>}   # the sandbox path changes on every run
    if [ "$got" = "$want" ]; then pass "home_check [$name] -> $want"; else fail "home_check [$name]: got [$got], expected [$want]"; fi
done <<EOT
unset|rc=1 err=empty
|rc=1 err=empty
.|rc=1 err=relative
~|rc=1 err=relative
reldir|rc=1 err=relative
$TMP/hm-file|rc=1 err=not_dir
/nonexistent-mint-setup-home|rc=1 err=not_dir
$HOME_DIR|rc=0 err=
$HOME_DIR/|rc=0 err=
$TMP/hm-link|rc=0 err=
/|rc=0 err=
EOT

# Loaded as a library (MINT_SETUP_TEST=1) the guard does not act, like the root guard,
# and sourcing never dies on an unset HOME. The shift matters: a sourced file without
# arguments sees the caller's, and the script path would count as an unknown option,
# which keeps the guard from acting whether or not the test-mode exception exists.
for spec in unset "" reldir /nonexistent-mint-setup-home; do
    hm_env "$spec" MINT_SETUP_TEST=1
    got=$(cd "$HM_CWD" && "${HM_ENV[@]}" bash -c 'f=$1; shift; source "$f" && echo sourced' _ "$SCRIPT" 2>&1)
    if [ "$got" = sourced ]; then pass "MINT_SETUP_TEST=1 loads the script with HOME [${spec:-empty}]"
    else fail "MINT_SETUP_TEST=1 with HOME [${spec:-empty}]: $got"; fi
done

MS_ENV=("${hm_saved[@]}")
cp -p "$TMP/zenity.keep" "$MOCK/zenity"
rm -rf -- "$CFG/mint-setup"
if [ -d "$TMP/cfg.keep" ]; then cp -a "$TMP/cfg.keep" "$CFG/mint-setup"; fi

# --- LUKS header backup ----------------------------------------------------------
# cryptsetup refuses to write over a file that already exists, and creates what
# it writes 0400. The stand-in below keeps both behaviours (the header of a
# device is its content), so a program that points it at a pre-created temporary
# file fails here exactly as it does on a real disk.
# ROOT_ONLY=1 models a device only root can open (a /dev/sdXN, 0660 root:disk):
# the stand-in refuses to touch LK_DEV unless the call came through pkexec
# (which sets FAKE_ROOT). A file with a "UUID=..." line reports that UUID; one
# with a "NOT-LUKS" line is not a LUKS header (luksDump fails on it). INFO_FAIL=1 makes
# luksDump of LK_DEV itself (the text dump of the header) fail, not that of a copy.
# RESTORE_CORRUPT=1 makes every restore write garbage; RESTORE_BAD_SRC=FILE only
# the restore of that file (so the rollback to the recovery copy can work).
# RESTORE_FAIL_SRC=FILE makes the restore of that file fail (exit 5, device
# untouched); RESTORE_BAD_PRE=1 makes the restore of a recovery copy write garbage
# and still exit 0. PK_DENY_FIRST=1 refuses the first pkexec call of a run (the
# administrator password dialog cancelled). The stand-in drops the
# --disable-internal-agent flag that prun adds, and $PK_LOG.calls (not reset
# between runs) keeps, per call, whether it had the flag.
lk_saved=("${MS_ENV[@]}")
REAL_CRYPTSETUP=$(PATH="/usr/sbin:/sbin:$SAFE_PATH" command -v cryptsetup 2>/dev/null || true)
ms_env_set MINT_SETUP_BACKUPS_DIR "$TMP/luks-bk"
LK_HEADERS="$TMP/luks-bk/LuksHeaders"; LK_DEV="$TMP/luks-dev.img"; LK_LOG="$TMP/luks-dialogs"; PK_LOG="$TMP/luks-pkexec"
printf 'CURRENT-HEADER\n' > "$LK_DEV"
ms_stub pkexec 'if [ "${1:-}" = --disable-internal-agent ]; then shift; flag=flag; else flag=noflag; fi
[ -n "${PK_LOG:-}" ] && printf "%s %s\n" "$flag" "${1##*/} ${2:-}" >> "$PK_LOG.calls"
[ -n "${PK_LOG:-}" ] && printf "%s\n" "${1##*/} ${2:-}" >> "$PK_LOG"
if [ -n "${PK_DENY_FIRST:-}" ] && [ ! -e "$PK_LOG.denied" ]; then : > "$PK_LOG.denied"; exit 126; fi
FAKE_ROOT=1 exec "$@"'
ms_stub lsblk '[ "$1" = "-no" ] && [ "$2" = UUID ] && printf "%s\n" "${LUKS_UUID:-}"; exit 0'
ms_stub cryptsetup '
action=""; dev=""; file=""
while [ $# -gt 0 ]; do
    case "$1" in
        luksDump|luksHeaderBackup|luksHeaderRestore) action=$1; dev=${2:-}; shift ;;
        --header-backup-file) file=${2:-}; shift ;;
    esac
    shift
done
if [ -n "${ROOT_ONLY:-}" ] && [ "$dev" = "${LK_DEV:-}" ] && [ -z "${FAKE_ROOT:-}" ]; then
    echo "Cannot open device $dev: Permission denied" >&2; exit 1
fi
case "$action" in
    luksDump) [ -n "${DUMP_FAIL:-}" ] && exit 1
        [ -n "${INFO_FAIL:-}" ] && [ "$dev" = "${LK_DEV:-}" ] && exit 1
        if grep -q "^NOT-LUKS" "$dev" 2>/dev/null; then echo "Device $dev is not a valid LUKS device." >&2; exit 1; fi
        u=$(sed -n "s/^UUID=//p" "$dev" 2>/dev/null | head -n1); printf "UUID: %s\n" "${u:-${LUKS_UUID:-none}}" ;;
    luksHeaderBackup)
        [ -n "${CRYPT_FAIL:-}" ] && { echo "Device $dev is not a valid LUKS device." >&2; exit 1; }
        if [ -e "$file" ] || [ -L "$file" ]; then echo "Requested header backup file $file already exists." >&2; exit 1; fi
        ( umask 277; cat -- "$dev" > "$file" ) ;;
    luksHeaderRestore)
        if [ "$file" = "${RESTORE_FAIL_SRC:-/nonexistent}" ]; then echo "Cannot write to $dev" >&2; exit 5; fi
        case "${file##*/}" in luks-header-recovery_*) [ -n "${RESTORE_BAD_PRE:-}" ] && { echo CORRUPT > "$dev"; exit 0; } ;; esac
        if [ -n "${RESTORE_CORRUPT:-}" ] || [ "$file" = "${RESTORE_BAD_SRC:-/nonexistent}" ]; then echo CORRUPT > "$dev"; else cat -- "$file" > "$dev"; fi ;;
esac
exit 0'
ms_stub zenity '
kind=""; text=""
for a in "$@"; do
    case "$a" in
        --question|--info|--error|--warning) kind=${a#--} ;;
        --text=*) text=${a#--text=} ;;
    esac
done
case "$*" in *--entry*) kind=entry ;; esac
[ -n "$kind" ] && printf "%s|%s\n" "$kind" "$(printf "%s" "$text" | tr "\n" " ")" >> "$LK_LOG"
case "$*" in
    *--entry*) printf "%s\n" "${ZENITY_TYPED:-}" ;;
    *--file-selection*) printf "%s\n" "${ZENITY_BACKUP:-}" ;;
esac
case "$kind" in question) exit "${QUESTION_RC:-0}" ;; esac
exit 0'
lk_run() {   # lk_run 'code' [NAME=VALUE...]  ->  lk_rc, lk_err, lk_out; the dialogs of the run go to $LK_LOG as "kind|text"
    local code="$1" kv
    shift
    : > "$LK_LOG"; : > "$PK_LOG"; rm -f -- "$PK_LOG.denied"
    ( for kv in "$@"; do export "${kv?}"; done; export LK_LOG LK_DEV PK_LOG; ms_lib "set_language ${LK_LANG:-en}; luks_pick_device() { printf '%s' \"\$LK_DEV\"; }; $code" ) >"$TMP/lk.out" 2>"$TMP/lk.err"
    lk_rc=$?
    lk_err=$(cat "$TMP/lk.err")
    lk_out=$(cat "$TMP/lk.out")
}
lk_imgs() { find "$LK_HEADERS" -maxdepth 1 -name 'luks-header_*.img' 2>/dev/null | LC_ALL=C sort; }
lk_count() { lk_imgs | grep -c .; }
lk_dialog() { grep -c -- "$1" "$LK_LOG"; }   # number of dialogs matching a basic regex ("kind|text" lines)

# First copy: it must be created, owned by the user, private, readable as LUKS and
# without a second-copy question (control).
lk_run do_luks_header_backup LUKS_UUID=aaaa-1111
first=$(lk_imgs | head -n1)
if [ "$lk_rc" -eq 0 ] && [ -z "$lk_err" ] && [ "$(lk_count)" -eq 1 ] && [ -n "$first" ] \
    && cmp -s -- "$first" "$LK_DEV"; then pass "luks backup: the first copy is created and holds the header"
else fail "luks backup: first copy (rc=$lk_rc, err=$lk_err, files: $(lk_imgs | tr '\n' ' '))"; fi
if [ -O "$first" ] && [ "$(stat -c %a -- "$first")" = 600 ] && [ -s "${first%.img}.txt" ]; then pass "luks backup: the copy belongs to the user, is private (600) and has its text dump"
else fail "luks backup: ownership or mode of the copy"; fi
ok "luks backup: success dialog shown, no second-copy question, no error" \
    bash -c '[ "$(grep -c "^info|LUKS header backup created successfully" "$1")" -eq 1 ] && ! grep -Eq "^(error|question\|There)" "$2" 2>/dev/null' _ "$LK_LOG" "$LK_LOG"
ok "luks backup: no temporary file is left behind" test -z "$(find "$LK_HEADERS" -name '.*mstmp*' -print -quit)"
ok "luks backup: the copy reads back as LUKS (what the program verifies)" ms_lib 'cryptsetup luksDump "$1"' "$first"

# A copy of this disk already exists: offer a second one, saved apart as copy 2.
before_sum=$(sha256sum -- "$first")
lk_run do_luks_header_backup LUKS_UUID=aaaa-1111
second=$(lk_imgs | grep '_copy2\.img$')
if [ "$lk_rc" -eq 0 ] && [ -n "$second" ] && [ "$(lk_count)" -eq 2 ] && cmp -s -- "$second" "$LK_DEV" \
    && [ -s "${second%.img}.txt" ]; then pass "luks backup: with a copy already there a second one is saved apart as _copy2"
else fail "luks backup: second copy (rc=$lk_rc, files: $(lk_imgs | tr '\n' ' '))"; fi
if [ "$(lk_dialog '^question|There is already a LUKS header backup of')" -eq 1 ] && [ "$(sha256sum -- "$first")" = "$before_sum" ]; then
    pass "luks backup: the second copy is offered first and the previous one is not touched"
else fail "luks backup: second-copy offer (dialogs: $(cut -c1-70 "$LK_LOG" | tr '\n' ';'))"; fi

lk_run do_luks_header_backup LUKS_UUID=aaaa-1111
if [ "$lk_rc" -eq 0 ] && lk_imgs | grep -q '_copy3\.img$' && [ "$(lk_dialog '^question|There are already 2 LUKS header backups of')" -eq 1 ]; then
    pass "luks backup: the third copy is _copy3 and the question counts the previous ones"
else fail "luks backup: third copy (files: $(lk_imgs | tr '\n' ' '), dialogs: $(cut -c1-70 "$LK_LOG" | tr '\n' ';'))"; fi

LK_LANG=es lk_run do_luks_header_backup LUKS_UUID=aaaa-1111
if [ "$(lk_dialog '^question|Ya existen 3 copias del header LUKS de')" -eq 1 ] && lk_imgs | grep -q '_copy4\.img$'; then
    pass "luks backup: the second-copy question is translated (ES)"
else fail "luks backup: ES question (dialogs: $(cut -c1-70 "$LK_LOG" | tr '\n' ';'))"; fi

# Declining the offer changes nothing and is not an error.
n_before=$(lk_count)
QUESTION_RC=1 lk_run do_luks_header_backup LUKS_UUID=aaaa-1111
if [ "$lk_rc" -eq 0 ] && [ "$(lk_count)" -eq "$n_before" ] && ! grep -q '^error|' "$LK_LOG"; then pass "luks backup: declining the second copy creates nothing and shows no error"
else fail "luks backup: declining (rc=$lk_rc, files: $(lk_count) vs $n_before)"; fi

# Copies of another disk and recovery copies are not "copies of this disk".
printf 'x\n' > "$LK_HEADERS/luks-header_sdb1-bbbb-2222_20260101-000000.img"
printf 'x\n' > "$LK_HEADERS/luks-header-recovery_sdc1-cccc-3333_20260101-000000.img"
lk_run do_luks_header_backup LUKS_UUID=cccc-3333
ok "luks backup: another disk's copy and recovery copies do not count (no question, no suffix)" \
    bash -c '! grep -q "^question|There" "$1" && [ "$(find "$2" -name "luks-header_*cccc-3333_2*.img" ! -name "*_copy*" | wc -l)" -eq 1 ]' _ "$LK_LOG" "$LK_HEADERS"

# The same disk under another device name (sda3 -> sdb3 after a reboot) is still the same disk.
printf 'x\n' > "$LK_HEADERS/luks-header_sdz9-dddd-4444_20260101-000000.img"
lk_run do_luks_header_backup LUKS_UUID=dddd-4444
if [ "$lk_rc" -eq 0 ] && [ "$(lk_dialog '^question|There is already a LUKS header backup of')" -eq 1 ] \
    && [ "$(find "$LK_HEADERS" -name 'luks-header_luks-dev_img-dddd-4444_*_copy2.img' | wc -l)" -eq 1 ]; then
    pass "luks backup: a copy made under another device name is found by UUID and counts as the first"
else fail "luks backup: renamed device (rc=$lk_rc, files: $(lk_imgs | tr '\n' ' '))"; fi

# Without a UUID the whole label (device name) is used, so two disks stay apart.
lk_run do_luks_header_backup LUKS_UUID=
lk_run do_luks_header_backup LUKS_UUID=
ok "luks backup: without UUID the second run of the same device is still a second copy" \
    bash -c '[ "$(find "$1" -name "luks-header_luks-dev_img-sinuuid_*_copy2.img" | wc -l)" -eq 1 ]' _ "$LK_HEADERS"

# Failure paths: an error dialog with the detail, nothing published, nothing left.
rm -rf -- "$LK_HEADERS"
lk_run do_luks_header_backup LUKS_UUID=aaaa-1111 CRYPT_FAIL=1
if [ "$lk_rc" -eq 1 ] && [ "$(lk_count)" -eq 0 ] && [ -z "$(find "$LK_HEADERS" -name '.*mstmp*' -print -quit)" ] \
    && grep -q '^error|Could not back up the header .*Details: Device .* is not a valid LUKS device' "$LK_LOG"; then
    pass "luks backup: a cryptsetup failure reports its detail and leaves nothing behind"
else fail "luks backup: failure path (rc=$lk_rc, dialogs: $(cut -c1-120 "$LK_LOG" | tr '\n' ';'))"; fi

lk_run do_luks_header_backup LUKS_UUID=aaaa-1111 DUMP_FAIL=1
if [ "$lk_rc" -eq 1 ] && [ "$(lk_count)" -eq 0 ] && grep -q 'The generated copy cannot be read as a valid LUKS header' "$LK_LOG"; then
    pass "luks backup: a copy that does not read back as LUKS is rejected and not published"
else fail "luks backup: unreadable copy (rc=$lk_rc, files: $(lk_count))"; fi

# 12.56: the text dump of the header fails but the binary copy is made. The warning that says so went
# through T() (which does not expand line breaks) and entered the success dialog as DATA (%s) of T_FMT,
# so it showed a literal "\n\n" in front of it. lk_run flattens the dialogs (a real line break reads as
# a space; a literal "\n" keeps its backslash). The expected texts are written out in full, independent
# of the catalog. The control is the same run with a working text dump.
lk_w=$'⚠️'
lk_starts() { [ "${1#"$2"}" != "$1" ]; }   # lk_starts TEXT PREFIX: TEXT begins with PREFIX, taken literally
for lk_lang in en es; do
    if [ "$lk_lang" = en ]; then
        lk_head='LUKS header backup created successfully:'
        lk_dump='A text dump of the LUKS header metadata (UUID, encryption, keyslots...) was also saved to:'
        lk_dump_end='This file alone CANNOT unlock the disk: it is only an additional reference in case the binary backup becomes corrupted.'
        lk_nodump="$lk_w The metadata text dump could not be saved (the binary backup above was completed successfully and is the one required for restoration)."
        lk_next="$lk_w Also keep a copy OUTSIDE this computer"
    else
        lk_head='Copia del header LUKS creada correctamente:'
        lk_dump='También se ha guardado un volcado de texto con los metadatos del header (UUID, cifrado, keyslots...) en:'
        lk_dump_end='Este archivo por sí solo NO permite desbloquear el disco: es solo referencia adicional por si la copia binaria se corrompiera.'
        lk_nodump="$lk_w No se ha podido guardar el volcado de metadatos en texto (la copia binaria de arriba sí se completó y es la que hace falta para restaurar)."
        lk_next="$lk_w Guarda también una copia FUERA de este equipo"
    fi
    rm -f -- "$LK_HEADERS"/luks-header_*
    LK_LANG=$lk_lang lk_run do_luks_header_backup LUKS_UUID=aaaa-1111
    lk_img=$(lk_imgs | head -n1); lk_info=$(grep '^info|' "$LK_LOG")
    if [ "$lk_rc" -eq 0 ] && [ -s "${lk_img%.img}.txt" ] \
        && lk_starts "$lk_info" "info|$lk_head $lk_img  $lk_dump ${lk_img%.img}.txt  $lk_dump_end  $lk_next" \
        && ! grep -q "[\\]" "$LK_LOG"; then
        pass "luks backup ($lk_lang): the note of a saved text dump has its own paragraph, with no literal \\n"
    else fail "luks backup ($lk_lang): note of the saved text dump (rc=$lk_rc, dialogs: $(cut -c1-300 "$LK_LOG" | tr '\n' ';'))"; fi
    rm -f -- "$LK_HEADERS"/luks-header_*
    LK_LANG=$lk_lang lk_run do_luks_header_backup LUKS_UUID=aaaa-1111 INFO_FAIL=1
    lk_img=$(lk_imgs | head -n1); lk_info=$(grep '^info|' "$LK_LOG")
    if [ "$lk_rc" -eq 0 ] && [ "$(lk_count)" -eq 1 ] && [ ! -e "${lk_img%.img}.txt" ] \
        && [ -z "$(find "$LK_HEADERS" -name '.*mstmp*' -print -quit)" ] \
        && lk_starts "$lk_info" "info|$lk_head $lk_img  $lk_nodump  $lk_next" \
        && ! grep -q "[\\]" "$LK_LOG"; then
        pass "luks backup ($lk_lang): a failed text dump keeps the binary copy and warns in its own paragraph, with no literal \\n"
    else fail "luks backup ($lk_lang): failed text dump (rc=$lk_rc, files: $(lk_imgs | tr '\n' ' '), dialogs: $(cut -c1-300 "$LK_LOG" | tr '\n' ';'))"; fi
done
rm -f -- "$LK_HEADERS"/luks-header_*

# Verification used by the restore: equal header -> match; different -> no match.
printf 'CURRENT-HEADER\n' > "$TMP/luks-expected.img"; printf 'OTHER\n' > "$TMP/luks-other.img"
ok "luks verify: the device header equal to the copy matches" ms_lib 'luks_header_matches_backup "$1" "$2"' "$LK_DEV" "$TMP/luks-expected.img"
ok "luks verify: a different copy does not match" ms_lib '! luks_header_matches_backup "$1" "$2"' "$LK_DEV" "$TMP/luks-other.img"
ok "luks verify: leaves no temporary file next to the copy" test -z "$(find "$TMP" -maxdepth 1 -name '.*verify*' -print -quit)"

# Restore: the pre-restore copy has to be creatable (it failed the same way) and
# the final verification has to succeed; a restore that cannot be verified keeps
# the recovery copy.
printf 'CURRENT-HEADER\n' > "$LK_DEV"; printf 'BACKUP-HEADER\n' > "$TMP/luks-restore-src.img"
lk_run do_luks_header_restore LUKS_UUID=aaaa-1111 ZENITY_TYPED=RESTORE ZENITY_BACKUP="$TMP/luks-restore-src.img"
if [ "$lk_rc" -eq 0 ] && [ "$(cat "$LK_DEV")" = BACKUP-HEADER ] && grep -q '^info|LUKS header restored to' "$LK_LOG" \
    && [ -z "$(find "$LK_HEADERS" -name 'luks-header-recovery_*' -print -quit 2>/dev/null)" ]; then
    pass "luks restore: with a faithful cryptsetup the restore is written, verified and the recovery copy removed"
else fail "luks restore: success path (rc=$lk_rc, device: $(cat "$LK_DEV"), dialogs: $(cut -c1-90 "$LK_LOG" | tr '\n' ';'))"; fi

printf 'CURRENT-HEADER\n' > "$LK_DEV"
lk_run do_luks_header_restore LUKS_UUID=aaaa-1111 ZENITY_TYPED=RESTORE ZENITY_BACKUP="$TMP/luks-restore-src.img" RESTORE_CORRUPT=1
kept=$(find "$LK_HEADERS" -name 'luks-header-recovery_*.img' -print -quit 2>/dev/null)
if [ "$lk_rc" -eq 1 ] && [ -n "$kept" ] && [ "$(cat "$kept")" = CURRENT-HEADER ] && grep -q '^error|A recovery copy of the current header has been kept at' "$LK_LOG"; then
    pass "luks restore: a restore that fails verification keeps the recovery copy with the previous header"
else fail "luks restore: failed verification (rc=$lk_rc, kept: ${kept:-none}, dialogs: $(cut -c1-90 "$LK_LOG" | tr '\n' ';'))"; fi

# Device only root can open: the verification reads it as root, like the write.
# An unprivileged luksDump of the device gave nothing there and a correct
# restore was reported as failed.
printf 'UUID=aaaa-1111\nCURRENT-HEADER\n' > "$LK_DEV"; printf 'UUID=aaaa-1111\nBACKUP-HEADER\n' > "$TMP/luks-same.img"
lk_run do_luks_header_restore ROOT_ONLY=1 ZENITY_TYPED=RESTORE ZENITY_BACKUP="$TMP/luks-same.img"
if [ "$lk_rc" -eq 0 ] && [ "$(tail -n1 "$LK_DEV")" = BACKUP-HEADER ] && grep -q '^info|LUKS header restored to' "$LK_LOG" \
    && ! grep -q '^error|' "$LK_LOG"; then
    pass "luks restore (root-only device): a correct restore is verified and reported as done"
else fail "luks restore (root-only device): success path (rc=$lk_rc, device: $(tail -n1 "$LK_DEV"), dialogs: $(cut -c1-90 "$LK_LOG" | tr '\n' ';'))"; fi

printf 'UUID=aaaa-1111\nCURRENT-HEADER\n' > "$LK_DEV"
lk_run do_luks_header_restore ROOT_ONLY=1 RESTORE_CORRUPT=1 ZENITY_TYPED=RESTORE ZENITY_BACKUP="$TMP/luks-same.img"
if [ "$lk_rc" -eq 1 ] && grep -q '^error|' "$LK_LOG" && ! grep -q '^info|LUKS header restored to' "$LK_LOG"; then
    pass "luks restore (root-only device): a restore that does not verify is still reported as failed"
else fail "luks restore (root-only device): failed verification (rc=$lk_rc, dialogs: $(cut -c1-90 "$LK_LOG" | tr '\n' ';'))"; fi

# A copy that does not read as LUKS is never reported as restored, even when the
# write itself went through: the previous header comes back.
rm -f -- "$LK_HEADERS"/luks-header-recovery_*.img   # the one kept by the failed-verification test above
printf 'UUID=aaaa-1111\nCURRENT-HEADER\n' > "$LK_DEV"; printf 'NOT-LUKS\n' > "$TMP/luks-bad.img"
lk_run do_luks_header_restore ZENITY_TYPED=RESTORE ZENITY_BACKUP="$TMP/luks-bad.img"
if [ "$lk_rc" -eq 1 ] && [ "$(tail -n1 "$LK_DEV")" = CURRENT-HEADER ] && ! grep -q '^info|LUKS header restored to' "$LK_LOG" \
    && grep -q '^error|The previous header was recovered successfully' "$LK_LOG" \
    && [ -z "$(find "$LK_HEADERS" -name 'luks-header-recovery_*' -print -quit 2>/dev/null)" ]; then
    pass "luks restore: a copy that is not a LUKS header is not reported as restored and the previous header comes back"
else fail "luks restore: non-LUKS copy (rc=$lk_rc, device: $(tail -n1 "$LK_DEV"), dialogs: $(cut -c1-90 "$LK_LOG" | tr '\n' ';'))"; fi

# The UUID of a root-only device is read as root, so the check against the copy
# warns correctly (it said "could not be read" and let a foreign header through
# with no mention of the mismatch). A device the user can open is read without
# a password prompt.
rm -f -- "$LK_HEADERS"/luks-header-recovery_*.img
printf 'UUID=aaaa-1111\nCURRENT-HEADER\n' > "$LK_DEV"; printf 'UUID=zzzz-9999\nFOREIGN-HEADER\n' > "$TMP/luks-foreign.img"
lk_run do_luks_header_restore ROOT_ONLY=1 ZENITY_TYPED=RESTORE ZENITY_BACKUP="$TMP/luks-foreign.img"
if grep -q '^entry|.*WARNING: the backup UUID (zzzz-9999) does NOT match .*(aaaa-1111)' "$LK_LOG" \
    && ! grep -q '^entry|.*could not be read' "$LK_LOG" && ! grep -q '^entry|.*backup UUID matches' "$LK_LOG"; then
    pass "luks restore (root-only device): a copy of another disk shows the UUID mismatch warning"
else fail "luks restore (root-only device): foreign copy warning ($(grep '^entry|' "$LK_LOG" | cut -c1-260))"; fi
printf 'UUID=aaaa-1111\nCURRENT-HEADER\n' > "$LK_DEV"   # the run above restored the foreign header
lk_run do_luks_header_restore ROOT_ONLY=1 ZENITY_TYPED=RESTORE ZENITY_BACKUP="$TMP/luks-same.img"
ok "luks restore (root-only device): a copy of the same disk shows the UUID match" \
    grep -q '^entry|.*The backup UUID matches' "$LK_LOG"
ok "luks restore (root-only device): four password prompts (UUID, recovery copy, write, verification), no more" \
    test "$(grep -c . "$PK_LOG")" -eq 4
printf 'UUID=aaaa-1111\nCURRENT-HEADER\n' > "$LK_DEV"
lk_run do_luks_header_restore ZENITY_TYPED=RESTORE ZENITY_BACKUP="$TMP/luks-same.img"
ok "luks restore (readable device): the UUID is read without a prompt (three prompts: recovery copy, write, verification)" \
    bash -c '! grep -q "luksDump" "$1" && [ "$(grep -c . "$1")" -eq 3 ]' _ "$PK_LOG"

# A damaged header (nothing can read its UUID, not even root) must not block the
# emergency restore: warning that it cannot be verified, no recovery copy, done.
printf 'NOT-LUKS\n' > "$LK_DEV"
lk_run do_luks_header_restore ROOT_ONLY=1 ZENITY_TYPED=RESTORE ZENITY_BACKUP="$TMP/luks-same.img"
if [ "$lk_rc" -eq 0 ] && [ "$(tail -n1 "$LK_DEV")" = BACKUP-HEADER ] && grep -q '^entry|.*current UUID of .* could not be read' "$LK_LOG" \
    && grep -q '^info|LUKS header restored to' "$LK_LOG" && [ "$(grep -c 'luksDump' "$PK_LOG")" -eq 1 ]; then
    pass "luks restore: a damaged header is not blocked (warns it cannot be verified, restores, one root read attempt)"
else fail "luks restore: damaged header (rc=$lk_rc, device: $(tail -n1 "$LK_DEV"), dialogs: $(cut -c1-90 "$LK_LOG" | tr '\n' ';'))"; fi

# With the UUID known the recovery copy is made also for a root-only device (it
# was skipped), so a failed restore can be undone: the previous header comes back
# verified as root, or the copy is kept and its path shown.
rm -f -- "$LK_HEADERS"/luks-header-recovery_*.img
printf 'UUID=aaaa-1111\nCURRENT-HEADER\n' > "$LK_DEV"
lk_run do_luks_header_restore ROOT_ONLY=1 RESTORE_BAD_SRC="$TMP/luks-same.img" ZENITY_TYPED=RESTORE ZENITY_BACKUP="$TMP/luks-same.img"
if [ "$lk_rc" -eq 1 ] && [ "$(tail -n1 "$LK_DEV")" = CURRENT-HEADER ] \
    && grep -q '^error|The previous header was recovered successfully' "$LK_LOG" \
    && [ -z "$(find "$LK_HEADERS" -name 'luks-header-recovery_*' -print -quit 2>/dev/null)" ]; then
    pass "luks restore (root-only device): a restore that fails verification is rolled back from the recovery copy"
else fail "luks restore (root-only device): rollback (rc=$lk_rc, device: $(tail -n1 "$LK_DEV"), dialogs: $(cut -c1-110 "$LK_LOG" | tr '\n' ';'))"; fi

printf 'UUID=aaaa-1111\nCURRENT-HEADER\n' > "$LK_DEV"
lk_run do_luks_header_restore ROOT_ONLY=1 RESTORE_CORRUPT=1 ZENITY_TYPED=RESTORE ZENITY_BACKUP="$TMP/luks-same.img"
kept=$(find "$LK_HEADERS" -name 'luks-header-recovery_*.img' -print -quit 2>/dev/null)
if [ "$lk_rc" -eq 1 ] && [ -n "$kept" ] && [ "$(tail -n1 "$kept")" = CURRENT-HEADER ] && [ "$(stat -c %a -- "$kept")" = 600 ] \
    && grep -q "^error|A recovery copy of the current header has been kept at: $kept" "$LK_LOG"; then
    pass "luks restore (root-only device): when the rollback fails too the recovery copy is kept and its path is shown"
else fail "luks restore (root-only device): kept copy (rc=$lk_rc, kept: ${kept:-none}, dialogs: $(cut -c1-110 "$LK_LOG" | tr '\n' ';'))"; fi

# The write itself fails: the recovery copy is put back and verified as root, or
# kept (with its path) when what was put back does not read as the previous header.
rm -f -- "$LK_HEADERS"/luks-header-recovery_*.img
printf 'UUID=aaaa-1111\nCURRENT-HEADER\n' > "$LK_DEV"
lk_run do_luks_header_restore ROOT_ONLY=1 RESTORE_FAIL_SRC="$TMP/luks-same.img" ZENITY_TYPED=RESTORE ZENITY_BACKUP="$TMP/luks-same.img"
if [ "$lk_rc" -eq 1 ] && [ "$(tail -n1 "$LK_DEV")" = CURRENT-HEADER ] && grep -q '^error|Could not restore the header' "$LK_LOG" \
    && grep -q 'The previous header was recovered successfully' "$LK_LOG" \
    && [ -z "$(find "$LK_HEADERS" -name 'luks-header-recovery_*' -print -quit 2>/dev/null)" ]; then
    pass "luks restore (root-only device): a failed write is undone from the recovery copy, verified as root"
else fail "luks restore (root-only device): failed write (rc=$lk_rc, device: $(tail -n1 "$LK_DEV"), dialogs: $(cut -c1-110 "$LK_LOG" | tr '\n' ';'))"; fi

printf 'UUID=aaaa-1111\nCURRENT-HEADER\n' > "$LK_DEV"
lk_run do_luks_header_restore ROOT_ONLY=1 RESTORE_FAIL_SRC="$TMP/luks-same.img" RESTORE_BAD_PRE=1 ZENITY_TYPED=RESTORE ZENITY_BACKUP="$TMP/luks-same.img"
kept=$(find "$LK_HEADERS" -name 'luks-header-recovery_*.img' -print -quit 2>/dev/null)
if [ "$lk_rc" -eq 1 ] && [ -n "$kept" ] && [ "$(tail -n1 "$kept")" = CURRENT-HEADER ] \
    && grep -q "A recovery copy of the current header has been kept at: $kept" "$LK_LOG" \
    && ! grep -q 'The previous header was recovered successfully' "$LK_LOG"; then
    pass "luks restore (root-only device): a failed write whose undo does not verify keeps the recovery copy and shows its path"
else fail "luks restore (root-only device): failed write, bad undo (rc=$lk_rc, kept: ${kept:-none}, dialogs: $(cut -c1-110 "$LK_LOG" | tr '\n' ';'))"; fi

rm -f -- "$LK_HEADERS"/luks-header-recovery_*.img
printf 'UUID=aaaa-1111\nCURRENT-HEADER\n' > "$LK_DEV"
lk_run do_luks_header_restore ROOT_ONLY=1 CRYPT_FAIL=1 ZENITY_TYPED=RESTORE ZENITY_BACKUP="$TMP/luks-same.img"
if [ "$lk_rc" -eq 1 ] && [ "$(tail -n1 "$LK_DEV")" = CURRENT-HEADER ] && grep -q '^error|Could not create a recovery copy of the current header. Nothing will be written to' "$LK_LOG" \
    && [ -z "$(find "$LK_HEADERS" -name 'luks-header-recovery_*' -print -quit 2>/dev/null)" ]; then
    pass "luks restore (root-only device): without a recovery copy nothing is written to the device"
else fail "luks restore (root-only device): no recovery copy (rc=$lk_rc, device: $(tail -n1 "$LK_DEV"), dialogs: $(cut -c1-110 "$LK_LOG" | tr '\n' ';'))"; fi

# No recovery copy exists when the current UUID cannot be read (a damaged header, or
# the administrator password cancelled for that read). A restore that then fails
# verification cannot be undone, and the dialog has to say so: it used to say that a
# recovery copy "has been kept at: " with an empty path, and the console line promised
# an automatic recovery that could not happen. Each scenario also checks that the
# write did happen (the device holds the bad header, so the failure is the verification),
# that nothing is left behind and that the dialog is the only error. The control
# (with a copy) keeps the negative checks from passing on an empty output.
mkdir -p "$TMP/lk-tmp"
printf 'UUID=aaaa-1111\nBACKUP-HEADER\n' > "$TMP/luks-same.img"
nocopy_check() {   # nocopy_check "description" "error text" "text that must not be shown" "line that must not be printed" [NAME=VALUE...]
    local desc="$1" want="$2" nokept="$3" nopromise="$4" left
    shift 4
    rm -f -- "$LK_HEADERS"/luks-header-recovery_*.img "$TMP/lk-tmp"/* 2>/dev/null
    lk_run do_luks_header_restore ROOT_ONLY=1 RESTORE_CORRUPT=1 TMPDIR="$TMP/lk-tmp" ZENITY_BACKUP="$TMP/luks-same.img" "$@"
    left=$(find "$TMP/lk-tmp" -type f | wc -l)
    if [ "$lk_rc" -eq 1 ] && [ "$(lk_dialog '^error|')" -eq 1 ] && grep -Fq -- "error|$want" "$LK_LOG" \
        && ! grep -Fq -- "$nokept" "$LK_LOG" && ! grep -q '^info|' "$LK_LOG" \
        && [ "$(tail -n1 "$LK_DEV")" = CORRUPT ] \
        && [ -z "$(find "$LK_HEADERS" -name 'luks-header-recovery_*' -print -quit 2>/dev/null)" ] \
        && [ "$left" -eq 0 ] && ! grep -Fq -- "$nopromise" <<<"$lk_out"; then pass "$desc"
    else fail "$desc (rc=$lk_rc, dialogs: $(cut -c1-150 "$LK_LOG" | tr '\n' ';'), console: $lk_out, temp files left: $left)"; fi
}
printf 'NOT-LUKS\n' > "$LK_DEV"
nocopy_check "luks restore (no recovery copy, damaged header): a failed verification says there was no copy, not a copy kept at an empty path" \
    "The restore did not pass the post-write verification and there was no recovery copy of the previous header" \
    "kept at" "An attempt will be made to automatically recover" ZENITY_TYPED=RESTORE
printf 'NOT-LUKS\n' > "$LK_DEV"
LK_LANG=es nocopy_check "luks restore (no recovery copy, damaged header) [ES]: the failed verification is explained in Spanish" \
    "La restauración no ha pasado la verificación posterior y no había copia de recuperación del header anterior" \
    "conservado" "Se intentará recuperar automáticamente" ZENITY_TYPED=RESTAURAR
printf 'UUID=aaaa-1111\nCURRENT-HEADER\n' > "$LK_DEV"
nocopy_check "luks restore (no recovery copy, password cancelled for the UUID read): a failed verification says there was no copy" \
    "The restore did not pass the post-write verification and there was no recovery copy of the previous header" \
    "kept at" "An attempt will be made to automatically recover" ZENITY_TYPED=RESTORE PK_DENY_FIRST=1
if [ "$(head -n1 "$PK_LOG")" = "cryptsetup luksDump" ] && [ -e "$PK_LOG.denied" ] && grep -q '^entry|.*current UUID of .* could not be read' "$LK_LOG"; then
    pass "luks restore (password cancelled): the scenario is real (the denied call was the UUID read, and the warning says it could not be read)"
else fail "luks restore (password cancelled): scenario (first call: $(head -n1 "$PK_LOG"), denied: $([ -e "$PK_LOG.denied" ] && echo yes || echo no))"; fi

rm -f -- "$LK_HEADERS"/luks-header-recovery_*.img
printf 'UUID=aaaa-1111\nCURRENT-HEADER\n' > "$LK_DEV"
lk_run do_luks_header_restore ROOT_ONLY=1 RESTORE_CORRUPT=1 ZENITY_TYPED=RESTORE ZENITY_BACKUP="$TMP/luks-same.img"
kept=$(find "$LK_HEADERS" -name 'luks-header-recovery_*.img' -print -quit 2>/dev/null)
if [ "$lk_rc" -eq 1 ] && [ -n "$kept" ] && grep -Fq 'An attempt will be made to automatically recover the previous header' <<<"$lk_out" \
    && grep -Fq -- "kept at: $kept" "$LK_LOG"; then
    pass "luks restore (with a recovery copy): the console announces the automatic recovery and the dialog shows the kept path (control)"
else fail "luks restore (with a recovery copy): control (rc=$lk_rc, kept: ${kept:-none}, console: $lk_out, dialogs: $(cut -c1-150 "$LK_LOG" | tr '\n' ';'))"; fi

# End to end with the real cryptsetup on a LUKS container kept in a file (only
# where it is installed and can format one): the stand-in above could drift from
# the real tool, this cannot.
rm -rf -- "$TMP/luks-bk"
LK_REAL="$TMP/real-luks.img"
if [ -n "$REAL_CRYPTSETUP" ] && truncate -s 20M "$LK_REAL" \
    && printf 'pw' | "$REAL_CRYPTSETUP" luksFormat -q --pbkdf pbkdf2 --pbkdf-force-iterations 1000 "$LK_REAL" - >/dev/null 2>&1; then
    ms_stub cryptsetup "exec $REAL_CRYPTSETUP \"\$@\""
    real_uuid=$("$REAL_CRYPTSETUP" luksUUID "$LK_REAL")
    "$REAL_CRYPTSETUP" luksHeaderBackup "$LK_REAL" --header-backup-file "$TMP/real-ref.img" >/dev/null 2>&1
    LK_DEV="$LK_REAL"
    lk_run do_luks_header_backup LUKS_UUID="$real_uuid"
    r1=$(lk_imgs | head -n1)
    if [ "$lk_rc" -eq 0 ] && [ -n "$r1" ] && cmp -s -- "$r1" "$TMP/real-ref.img" && [ -O "$r1" ] && [ "$(stat -c %a -- "$r1")" = 600 ]; then
        pass "luks real cryptsetup: the backup is created, identical to the header and private"
    else fail "luks real cryptsetup: backup (rc=$lk_rc, err=$lk_err, dialogs: $(cut -c1-110 "$LK_LOG" | tr '\n' ';'))"; fi
    lk_run do_luks_header_backup LUKS_UUID="$real_uuid"
    if [ "$lk_rc" -eq 0 ] && [ "$(lk_count)" -eq 2 ] && lk_imgs | grep -q '_copy2\.img$'; then
        pass "luks real cryptsetup: a second run saves copy 2"
    else fail "luks real cryptsetup: second copy (rc=$lk_rc, files: $(lk_imgs | tr '\n' ' '))"; fi
    lk_run do_luks_header_restore LUKS_UUID="$real_uuid" ZENITY_TYPED=RESTORE ZENITY_BACKUP="$r1"
    if [ "$lk_rc" -eq 0 ] && grep -q '^info|LUKS header restored to' "$LK_LOG" \
        && printf 'pw' | "$REAL_CRYPTSETUP" open --test-passphrase "$LK_REAL" - >/dev/null 2>&1 \
        && [ -z "$(find "$LK_HEADERS" -name 'luks-header-recovery_*' -print -quit)" ]; then
        pass "luks real cryptsetup: the restore is verified, the disk still unlocks and no recovery copy is left"
    else fail "luks real cryptsetup: restore (rc=$lk_rc, dialogs: $(cut -c1-110 "$LK_LOG" | tr '\n' ';'))"; fi
    ok "luks real cryptsetup: no temporary file is left behind" test -z "$(find "$TMP/luks-bk" -name '.*mstmp*' -print -quit)"
else
    printf 'SKIP: luks end to end with the real cryptsetup (not installed, or it cannot format a file here)\n'
fi

# Every privileged call of the LUKS functions goes through prun, so pkexec always
# got --disable-internal-agent. Without it a call can fall to pkexec's own text
# prompt on the terminal. The three kinds of call (root-side script, luksDump read,
# luksHeaderRestore write) must all have been seen, or the check would be empty.
lk_calls="$PK_LOG.calls"
if [ -s "$lk_calls" ] && ! grep -q '^noflag ' "$lk_calls" \
    && grep -q '^flag bash -c' "$lk_calls" && grep -q '^flag cryptsetup luksDump' "$lk_calls" \
    && grep -q '^flag cryptsetup -q' "$lk_calls"; then
    pass "luks: every privileged call goes through prun (pkexec always got --disable-internal-agent; $(grep -c . "$lk_calls") calls)"
else fail "luks: a privileged call reached pkexec without --disable-internal-agent, or a kind of call was never made ($(sort "$lk_calls" | uniq -c | tr '\n' ';'))"; fi

MS_ENV=("${lk_saved[@]}")
ms_stub pkexec

# --- prun: a privileged call never falls back to pkexec's text prompt ----------
# With no graphical agent registered, pkexec asks for the password on the controlling
# terminal (</dev/null does not stop it) and that prompt never validates. prun passes
# --disable-internal-agent, so that case is a plain failure ("No authentication agent
# found.", 127). Once an agent has answered, the failure is transient and is retried
# (bounded); so is "Not authorized" (127, seen in a real restore in a VM: polkitd reports it
# when the agent closes the request without authenticating, a cancel being 126). A cancelled
# dialog (126) and the command's own status never are. The stand-in pkexec follows $PKX/plan (one outcome per call, the
# last one repeats) and records its arguments, and whether stdin was /dev/null.
PKX="$TMP/pkx"; pk_saved=("${MS_ENV[@]}"); ms_env_set PKX_DIR "$PKX"
ms_stub pkexec '
d=$PKX_DIR; n=0; [ -f "$d/n" ] && n=$(cat "$d/n"); n=$((n + 1)); echo "$n" > "$d/n"
printf "%s\n" "$*" >> "$d/args"
if [ "$(readlink /proc/$$/fd/0 2>/dev/null)" = /dev/null ]; then echo null >> "$d/stdin"; else echo other >> "$d/stdin"; fi
step=$(sed -n "${n}p" "$d/plan"); [ -n "$step" ] || step=$(tail -n 1 "$d/plan")
case "$step" in
    noagent)   echo "Error executing command as another user: No authentication agent found." >&2; exit 127 ;;
    denied)    echo "Error executing command as another user: Not authorized" >&2; printf "\nThis incident has been reported.\n" >&2; exit 127 ;;
    dismissed) exit 126 ;;
    ok)        [ "$1" = --disable-internal-agent ] && shift; exec "$@" ;;
esac
exit 99'
ms_stub sleep 'printf "%s\n" "${1:-}" >> "$PKX_DIR/sleep"'

pk_run() {   # pk_run "outcomes" 'code' -> pk_rc pk_out pk_err pk_n pk_sleeps (the code runs after PKEXEC_AGENT_WAIT=0 PKEXEC_DENIED_WAIT=0)
    rm -rf "$PKX"; mkdir -p "$PKX"; printf '%s\n' "$1" | tr ' ' '\n' > "$PKX/plan"
    pk_rc=0
    pk_out=$(ms_lib "PKEXEC_AGENT_WAIT=0; PKEXEC_DENIED_WAIT=0; $2" 2>"$PKX/err" <<<"not /dev/null") || pk_rc=$?
    pk_err=$(<"$PKX/err")
    pk_n=$(cat "$PKX/n" 2>/dev/null || echo 0)
    pk_sleeps=$(cat "$PKX/sleep" 2>/dev/null | wc -l)
}
PK_NOAGENT='Error executing command as another user: No authentication agent found.'

# prun creates its lock folder the first time it runs. The LUKS tests above already
# made ~/.cache/mint-setup (700), so start from a home without ~/.cache: the mode
# checked below is then the one prun gave it.
rm -rf -- "$HOME_DIR/.cache"
pk_run "ok" "prun bash -c 'echo out; echo cmderr >&2'"
if [ "$pk_rc" = 0 ] && [ "$pk_out" = out ] && [ "$pk_err" = cmderr ] && [ "$pk_n" = 1 ]; then
    pass "prun: authorized call (control): status 0, stdout intact, the command's stderr replayed, one call"
else fail "prun control (rc=$pk_rc out=[$pk_out] err=[$pk_err] calls=$pk_n)"; fi
if [ "$(head -n 1 "$PKX/args")" = "--disable-internal-agent bash -c echo out; echo cmderr >&2" ]; then
    pass "prun: pkexec gets --disable-internal-agent before the command, arguments intact"
else fail "prun arguments (got: $(head -n 1 "$PKX/args"))"; fi
ok "prun: pkexec reads stdin from /dev/null" test "$(cat "$PKX/stdin")" = null
ok "prun: the lock folder is created private (700)" test "$(stat -c %a "$HOME_DIR/.cache/mint-setup")" = 700
# The program runs under umask 077, which alone would make the folder 700: with a
# permissive umask only prun's own chmod keeps it private.
rm -rf -- "$HOME_DIR/.cache"
pk_run "ok" "umask 022; prun true"
ok "prun: the lock folder is private (700) even under a permissive umask" test "$(stat -c %a "$HOME_DIR/.cache/mint-setup")" = 700

# Which folder holds the lock: $XDG_RUNTIME_DIR when it is an existing folder, else
# $XDG_CACHE_HOME/mint-setup, else ~/.cache/mint-setup. The program reads the variables
# when it is sourced, so they go in the environment of each run, started from a home
# without ~/.cache so that anything created there shows.
pk_sel() {   # pk_sel [VAR=VALUE...]: one prun with those variables; $TMP/sel/run (folder) and $TMP/sel/file (regular file) always exist
    chmod -R u+rwx "$TMP/sel" 2>/dev/null; rm -rf -- "$HOME_DIR/.cache" "$TMP/sel"; mkdir -p "$TMP/sel/run"; : > "$TMP/sel/file"
    [ -z "${PK_SEL_SETUP:-}" ] || eval "$PK_SEL_SETUP"
    local saved=("${MS_ENV[@]}") kv
    for kv in "$@"; do ms_env_set "${kv%%=*}" "${kv#*=}"; done
    pk_run "ok" "prun true"
    MS_ENV=("${saved[@]}")
}
PK_LOCK_NAME=.Mint-Setup-pkexec.lock
pk_sel XDG_RUNTIME_DIR="$TMP/sel/run" XDG_CACHE_HOME="$TMP/sel/cache"
if [ "$pk_rc" = 0 ] && [ -e "$TMP/sel/run/$PK_LOCK_NAME" ] && [ ! -e "$HOME_DIR/.cache" ] && [ ! -e "$TMP/sel/cache" ]; then
    pass "prun: a usable XDG_RUNTIME_DIR holds the lock, ahead of XDG_CACHE_HOME and ~/.cache"
else fail "prun lock with XDG_RUNTIME_DIR set (rc=$pk_rc, lock in runtime dir: $([ -e "$TMP/sel/run/$PK_LOCK_NAME" ] && echo yes || echo no))"; fi
pk_sel XDG_CACHE_HOME="$TMP/sel/cache"
if [ "$pk_rc" = 0 ] && [ -e "$TMP/sel/cache/mint-setup/$PK_LOCK_NAME" ] && [ "$(stat -c %a "$TMP/sel/cache/mint-setup")" = 700 ] \
    && [ ! -e "$HOME_DIR/.cache" ] && [ -z "$(ls -A "$TMP/sel/run")" ]; then
    pass "prun: without XDG_RUNTIME_DIR the lock is in XDG_CACHE_HOME/mint-setup (700), not in ~/.cache"
else fail "prun lock with XDG_CACHE_HOME set (rc=$pk_rc)"; fi
pk_sel XDG_RUNTIME_DIR="$TMP/sel/missing"
if [ "$pk_rc" = 0 ] && [ -e "$HOME_DIR/.cache/mint-setup/$PK_LOCK_NAME" ] && [ "$(stat -c %a "$HOME_DIR/.cache/mint-setup")" = 700 ] \
    && [ ! -e "$TMP/sel/missing" ]; then
    pass "prun: an XDG_RUNTIME_DIR that is not a folder is ignored (lock in ~/.cache/mint-setup, nothing created there)"
else fail "prun lock with a missing XDG_RUNTIME_DIR (rc=$pk_rc)"; fi
pk_sel XDG_RUNTIME_DIR="$TMP/sel/file"
if [ "$pk_rc" = 0 ] && [ -e "$HOME_DIR/.cache/mint-setup/$PK_LOCK_NAME" ] && [ -f "$TMP/sel/file" ]; then
    pass "prun: an XDG_RUNTIME_DIR that is a regular file is ignored (lock in ~/.cache/mint-setup)"
else fail "prun lock with a file as XDG_RUNTIME_DIR (rc=$pk_rc)"; fi
pk_sel XDG_CACHE_HOME=
if [ "$pk_rc" = 0 ] && [ -e "$HOME_DIR/.cache/mint-setup/$PK_LOCK_NAME" ]; then
    pass "prun: an empty XDG_CACHE_HOME counts as unset (lock in ~/.cache/mint-setup)"
else fail "prun lock with an empty XDG_CACHE_HOME (rc=$pk_rc)"; fi
# Root can write anywhere, so a read-only runtime folder only tells apart for a normal user.
if [ "$(id -u)" -ne 0 ]; then
    PK_SEL_SETUP='chmod 500 "$TMP/sel/run"' pk_sel XDG_RUNTIME_DIR="$TMP/sel/run"
    if [ "$pk_rc" = 0 ] && [ -e "$HOME_DIR/.cache/mint-setup/$PK_LOCK_NAME" ] && [ -z "$(ls -A "$TMP/sel/run")" ]; then
        pass "prun: an XDG_RUNTIME_DIR without write permission is ignored (lock in ~/.cache/mint-setup)"
    else fail "prun lock with a read-only XDG_RUNTIME_DIR (rc=$pk_rc)"; fi
    chmod 700 "$TMP/sel/run"
else echo "SKIP: prun lock with a read-only XDG_RUNTIME_DIR (needs an unprivileged user)"; fi

pk_run "noagent ok" "prun true"
if [ "$pk_rc" = 127 ] && [ "$pk_n" = 1 ] && [ "$pk_err" = "$PK_NOAGENT" ] && [ "$pk_sleeps" = 0 ]; then
    pass "prun: no agent and none seen yet: fails at once with 127 and pkexec's message, no retry"
else fail "prun no agent, none seen (rc=$pk_rc calls=$pk_n sleeps=$pk_sleeps err=[$pk_err])"; fi

pk_run "ok noagent noagent ok" "prun true; prun bash -c 'echo out'"
if [ "$pk_rc" = 0 ] && [ "$pk_out" = out ] && [ "$pk_n" = 4 ] && [ "$pk_sleeps" = 2 ] && [ -z "$pk_err" ] \
    && [ "$(sort -u "$PKX/sleep")" = 0 ]; then
    pass "prun: after an authorization, a transient \"no agent\" is retried (waiting PKEXEC_AGENT_WAIT) until it works"
else fail "prun transient no agent (rc=$pk_rc out=[$pk_out] calls=$pk_n sleeps=$pk_sleeps err=[$pk_err])"; fi

pk_run "ok noagent" "PKEXEC_AGENT_RETRIES=3; prun true; prun true"
if [ "$pk_rc" = 127 ] && [ "$pk_n" = 5 ] && [ "$pk_sleeps" = 3 ] && [ "$pk_err" = "$PK_NOAGENT" ]; then
    pass "prun: a persistent \"no agent\" is retried PKEXEC_AGENT_RETRIES times and then fails with its message"
else fail "prun persistent no agent (rc=$pk_rc calls=$pk_n sleeps=$pk_sleeps err=[$pk_err])"; fi

pk_run "ok dismissed ok" "prun true; prun true"
if [ "$pk_rc" = 126 ] && [ "$pk_n" = 2 ] && [ "$pk_sleeps" = 0 ]; then
    pass "prun: a cancelled dialog (126) is never retried"
else fail "prun dismissed (rc=$pk_rc calls=$pk_n sleeps=$pk_sleeps)"; fi

# "Not authorized" (127): the agent closed the request without authenticating and without a
# cancel (a real restore in a VM lost Network to it while the next calls worked).
pk_run "ok denied ok" "prun true; prun bash -c 'echo out'"
if [ "$pk_rc" = 0 ] && [ "$pk_out" = out ] && [ "$pk_n" = 3 ] && [ "$pk_sleeps" = 1 ] && [ -z "$pk_err" ]; then
    pass "prun: after an authorization, a transient \"Not authorized\" is retried and works (no leftover message)"
else fail "prun transient not authorized (rc=$pk_rc out=[$pk_out] calls=$pk_n sleeps=$pk_sleeps err=[$pk_err])"; fi

pk_run "ok denied" "prun true; prun true"
if [ "$pk_rc" = 127 ] && [ "$pk_n" = 4 ] && [ "$pk_sleeps" = 2 ] && grep -q 'Not authorized' <<<"$pk_err" \
    && grep -q 'This incident has been reported' <<<"$pk_err" && ! grep -q 'No authentication agent' <<<"$pk_err"; then
    pass "prun: a persistent \"Not authorized\" is retried PKEXEC_DENIED_RETRIES (2) times and then fails with its message"
else fail "prun persistent not authorized (rc=$pk_rc calls=$pk_n sleeps=$pk_sleeps err=[$pk_err])"; fi

pk_run "denied ok" "prun true"
if [ "$pk_rc" = 127 ] && [ "$pk_n" = 1 ] && [ "$pk_sleeps" = 0 ] && grep -q 'Not authorized' <<<"$pk_err"; then
    pass "prun: \"Not authorized\" with no agent seen yet (nothing was ever authorized) is not retried"
else fail "prun not authorized, none seen (rc=$pk_rc calls=$pk_n sleeps=$pk_sleeps err=[$pk_err])"; fi

pk_run "ok denied denied" "PKEXEC_DENIED_WAIT=7; PKEXEC_DENIED_RETRIES=1; prun true; prun true"
if [ "$pk_rc" = 127 ] && [ "$pk_n" = 3 ] && [ "$pk_sleeps" = 1 ] && [ "$(cat "$PKX/sleep")" = 7 ]; then
    pass "prun: the \"Not authorized\" retries wait PKEXEC_DENIED_WAIT and are capped by PKEXEC_DENIED_RETRIES"
else fail "prun not authorized wait/cap (rc=$pk_rc calls=$pk_n sleeps=$pk_sleeps waited=[$(tr '\n' ' ' < "$PKX/sleep" 2>/dev/null)])"; fi

# The tests above set the wait to 0; a default of 0 would retry before a closing dialog is gone.
ok "prun: the default wait between \"Not authorized\" retries is at least 1 s" test "$(ms_lib 'printf %s "$PKEXEC_DENIED_WAIT"')" -ge 1

pk_run "ok denied ok denied ok" "PKEXEC_DENIED_RETRIES=1; prun true; prun true; prun true"
if [ "$pk_rc" = 0 ] && [ "$pk_n" = 5 ] && [ "$pk_sleeps" = 2 ]; then
    pass "prun: the \"Not authorized\" retry budget is per call (two calls each use their one retry)"
else fail "prun not authorized budget per call (rc=$pk_rc calls=$pk_n sleeps=$pk_sleeps)"; fi

pk_run "ok noagent denied ok" "prun true; prun bash -c 'echo out'"
if [ "$pk_rc" = 0 ] && [ "$pk_out" = out ] && [ "$pk_n" = 4 ] && [ "$pk_sleeps" = 2 ] && [ -z "$pk_err" ]; then
    pass "prun: \"no agent\" and \"Not authorized\" are retried one after the other in the same call"
else fail "prun no agent then not authorized (rc=$pk_rc out=[$pk_out] calls=$pk_n sleeps=$pk_sleeps err=[$pk_err])"; fi

pk_run "ok denied dismissed ok" "prun true; prun true"
if [ "$pk_rc" = 126 ] && [ "$pk_n" = 3 ] && [ "$pk_sleeps" = 1 ]; then
    pass "prun: a dialog cancelled (126) during a \"Not authorized\" retry ends the call"
else fail "prun denied then dismissed (rc=$pk_rc calls=$pk_n sleeps=$pk_sleeps)"; fi

pk_run "ok" "prun true; prun bash -c 'exit 127'"
if [ "$pk_rc" = 127 ] && [ "$pk_n" = 2 ] && [ "$pk_sleeps" = 0 ]; then
    pass "prun: the command's own 127 (not found) is not mistaken for \"no agent\""
else fail "prun own 127 (rc=$pk_rc calls=$pk_n sleeps=$pk_sleeps)"; fi

pk_run "ok" "prun bash -c 'exit 3'"
ok "prun: the command's exit status is returned as is" test "$pk_rc" = 3

# Without mktemp the stderr cannot be inspected: no retry, but the call still goes through.
ms_stub mktemp 'exit 1'
pk_run "ok" "prun bash -c 'echo out; echo cmderr >&2'"
if [ "$pk_rc" = 0 ] && [ "$pk_out" = out ] && [ "$pk_err" = cmderr ] && [ "$pk_n" = 1 ] \
    && [ "$(head -n 1 "$PKX/args" | cut -c1-24)" = "--disable-internal-agent" ]; then
    pass "prun: without a temporary file the call still runs with the flag and the same output"
else fail "prun without mktemp (rc=$pk_rc out=[$pk_out] err=[$pk_err] calls=$pk_n)"; fi
pk_run "denied" "prun true"
if [ "$pk_rc" = 127 ] && [ "$pk_n" = 1 ] && grep -q 'Not authorized' <<<"$pk_err"; then
    pass "prun: without a temporary file the status and pkexec's message are still passed on"
else fail "prun without mktemp, denied (rc=$pk_rc calls=$pk_n err=[$pk_err])"; fi
rm -f "$MOCK/mktemp"
ok "prun: no stderr capture file is left behind" test -z "$(find "$HOME_DIR/.cache/mint-setup" -name '*pkexec-err*' -print -quit 2>/dev/null)"

# Two simultaneous calls take turns (one polkit dialog at a time).
rm -f "$MOCK/sleep"
pk_run "ok" 'f=$PKX_DIR/turns
prun bash -c '"'"'echo start >> "$1"; sleep 0.3; echo end >> "$1"'"'"' _ "$f" &
prun bash -c '"'"'echo start >> "$1"; sleep 0.3; echo end >> "$1"'"'"' _ "$f" &
wait'
if [ "$(tr '\n' ' ' < "$PKX/turns")" = "start end start end " ]; then
    pass "prun: simultaneous calls are serialized"
else fail "prun serialization (got: $(tr '\n' ' ' < "$PKX/turns" 2>/dev/null))"; fi

# A TERM, HUP or INT while pkexec waits must not leave the stderr capture file behind. The file
# has to exist while pkexec runs (control), and the signal goes then; bash runs the trap
# once the foreground call returns, hence the one-second command.
# A background job starts with INT ignored and an ignored signal cannot be trapped, so the
# INT round gives the program its default disposition back (env --default-signal, coreutils 8.31+).
for pk_sig in TERM:143 HUP:129 INT:130; do
    if [ "${pk_sig%%:*}" = INT ] && ! env --default-signal=INT true 2>/dev/null; then
        echo "SKIP: prun INT while pkexec waits (needs env --default-signal)"; continue
    fi
    pk_env=("${MS_ENV[@]}"); [ "${pk_sig%%:*}" != INT ] || MS_ENV=(env --default-signal=INT "${MS_ENV[@]:1}")
    rm -rf -- "$HOME_DIR/.cache" "$PKX"; mkdir -p "$PKX"; echo ok > "$PKX/plan"
    ms_lib 'echo $$ > "$PKX_DIR/pid"; prun /bin/sleep 1' >/dev/null 2>&1 &
    pk_job=$!; pk_seen=no
    for _ in $(seq 1 60); do
        [ -z "$(find "$HOME_DIR/.cache/mint-setup" -name '*pkexec-err*' -print -quit 2>/dev/null)" ] || { pk_seen=yes; break; }
        sleep 0.05
    done
    kill -"${pk_sig%%:*}" "$(cat "$PKX/pid" 2>/dev/null)" 2>/dev/null   # the program's own process, not the job's subshell
    pk_rc=0; wait "$pk_job" || pk_rc=$?
    MS_ENV=("${pk_env[@]}")
    pk_left=$(find "$HOME_DIR/.cache/mint-setup" -name '*pkexec-err*' -print 2>/dev/null)
    if [ "$pk_seen" = yes ] && [ "$pk_rc" = "${pk_sig##*:}" ] && [ -z "$pk_left" ]; then
        pass "prun: ${pk_sig%%:*} while pkexec waits ends it (${pk_sig##*:}) and leaves no stderr capture file"
    else fail "prun ${pk_sig%%:*} while pkexec waits (capture file seen: $pk_seen, rc=$pk_rc, left: [$pk_left])"; fi
done
MS_ENV=("${pk_saved[@]}")
ms_stub pkexec

# --- Save: progress dialog and its pipe ------------------------------------------
# Zenity --auto-close quits (and closes the pipe) as soon as it reads 100. The
# percentage must therefore be that of the modules already saved: sent ahead of
# the last module it closed the window while that module was still running, and
# the next write failed with "printf: write error: Broken pipe".
ms_stub zenity '
case "$*" in
    *--list*)  printf "desktop,appearance,nemo\n" ;;
    *--entry*) printf "Progress test\n" ;;
    *--progress*)
        while IFS= read -r l; do
            printf "RX:%s\n" "$l" >> "$ORDER_FILE"
            [ "$l" = 100 ] && exit 0                       # --auto-close
            [ -n "${CLOSE_AT_ONCE:-}" ] && exit 1          # window closed by the user
        done ;;
esac
exit 0'
sv_run() {   # sv_run [CLOSE_AT_ONCE=1]  ->  sv_err, sv_trace (progress numbers and saved modules, in order)
    local want_close="${1:-}"
    : > "$TMP/sv.order"
    sv_err=$(CLOSE_AT_ONCE="$want_close" ORDER_FILE="$TMP/sv.order" ms_lib '
run_save_module() { sleep 0.3; printf "SAVED:%s\n" "$1" >> "$ORDER_FILE"; mkdir -p "$2/$1"; : > "$2/$1/f"; }
do_save' 2>&1 >/dev/null)
    sv_trace=$(grep -E '^(RX:[0-9]+|SAVED:)' "$TMP/sv.order" | tr '\n' ' ')
}
sv_run
if [ "$sv_trace" = "RX:0 SAVED:desktop RX:33 SAVED:appearance RX:66 SAVED:nemo RX:100 " ]; then
    pass "save: the progress bar reaches 100 only after the last module is saved"
else fail "save: progress order (got: $sv_trace)"; fi
if [ -z "$sv_err" ]; then pass "save: a dialog that auto-closes at 100 leaves stderr empty"
else fail "save: stderr after auto-close: $sv_err"; fi
ok "save: the finished backup was published (control)" test -f "$(find "$BACKUPS" -maxdepth 2 -name manifest.conf -print -quit)"

sv_run 1
if [ -z "$sv_err" ]; then pass "save: closing the progress window halfway leaves stderr empty"
else fail "save: stderr after closing the window: $sv_err"; fi
if [ "$(grep -c '^SAVED:' <<<"$(tr ' ' '\n' <<<"$sv_trace")")" -eq 3 ]; then pass "save: closing the window does not interrupt the modules (control)"
else fail "save: modules after closing the window (got: $sv_trace)"; fi

ms_finish
