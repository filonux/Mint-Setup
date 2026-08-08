#!/bin/bash
# Copyright (C) 2026 Filonux
#
# Licencia:
#   Mint-Setup es software libre distribuido bajo los términos de la
#   GNU General Public License versión 3 (GPLv3).
#   Consulte el archivo LICENSE para obtener el texto completo de la
#   licencia.
###############################################################################
# Mint-Setup
# Autor: Filonux
#
# Guarda y restaura la configuración del entorno de usuario en Linux Mint
# (Cinnamon): escritorio, apariencia, Nemo, aplicaciones instaladas,
# aplicaciones de inicio, pantallas, sonido, red, bluetooth, teclado, ratón,
# touchpad, y la configuración propia de aplicaciones concretas: Firefox,
# LibreWolf, Thunderbird, LibreOffice, ONLYOFFICE, VS Code, Docker y la
# terminal.
#
# No sustituye a Timeshift ni a MintBackup. Los complementa:
#   - Timeshift recupera el sistema.
#   - MintBackup recupera archivos personales.
#   - Mint-Setup reconstruye el entorno de trabajo.
#
# Filosofía: el programa no copia el sistema, describe cómo está configurado
# (usando dconf, gsettings, apt-mark, flatpak, listas de extensiones...) y, al
# restaurar, vuelve a aplicar esa configuración sobre una instalación nueva de
# Linux Mint.
#
# Cada módulo (Escritorio, Apariencia, Nemo, Aplicaciones... y cada aplicación
# concreta) es independiente: Guardar y Restaurar muestran un checklist para
# elegir exactamente qué módulos tocar en cada operación.
#
# Configuración avanzada añade, aparte de los módulos anteriores, copia de
# seguridad y restauración de emergencia del header LUKS de discos cifrados:
# a diferencia de los módulos, no es una configuración de usuario sino una
# copia ligada a un disco físico concreto.
#
# Los módulos Red y Bluetooth piden permisos de administrador vía pkexec
# tanto al guardar como al restaurar (leen/escriben rutas que solo puede
# tocar root) y pueden contener credenciales (contraseñas Wi-Fi en texto
# plano, claves de emparejamiento). El módulo Docker pide permisos de
# administrador solo para la parte del daemon (/etc/docker/daemon.json) y
# para añadir el usuario al grupo docker; su configuración de usuario
# (~/.docker) no los necesita.
#
# Requiere: zenity, dconf, gsettings, apt-get, tar (obligatorios). Son
# opcionales y se comprueban por separado: flatpak, pkexec, pactl, iconv,
# gio, fc-cache, xdg-user-dir, pgrep, code (VS Code) y cryptsetup (header
# LUKS); si falta alguno, el paso que lo usa se omite o avisa (si falta
# pgrep, se asume por precaución que la aplicación sí podría estar
# abierta), sin interrumpir el resto del guardado/restaurado.
###############################################################################

set -uo pipefail

# Todo archivo/carpeta que cree este script a partir de ahora nace sin
# permisos para "grupo" ni "otros". Varios módulos pueden contener
# credenciales (Wi-Fi, emparejamiento Bluetooth); esto evita que quede
# expuesto ni un instante, en vez de depender solo del chmod final de
# do_save().
umask 077

# El diálogo de progreso de Restaurar (ver do_restore) escribe directamente
# a una tubería con nombre conectada a zenity, fuera de cualquier subshell.
# Si el usuario cierra esa ventana a mitad de la operación, el siguiente
# "echo" a la tubería rota generaría SIGPIPE; ignorarla evita que eso mate
# el script entero en vez de solo fallar esa escritura puntual.
trap '' PIPE

# Este script está pensado para ejecutarse como el usuario normal de
# escritorio: los pasos que necesitan privilegios (Red, Bluetooth,
# instalar paquetes...) ya piden permisos puntuales con pkexec cuando hace
# falta. Ejecutar el script ENTERO como root/con sudo es un error fácil de
# cometer viendo tantos avisos de "permisos de administrador", pero rompe
# el programa: $HOME pasaría a ser el de root, así que guardaría/leería la
# configuración equivocada sin avisar de ello.
APP_NAME="Mint-Setup"
APP_VERSION="3.0.0"

# --version se resuelve antes que cualquier otra cosa (incluida la
# comprobación de root de abajo), para que se pueda consultar la versión
# instalada desde otro script sin disparar diálogos de zenity ni el aviso
# de "no ejecutes esto como root".
for arg in "$@"; do
    [ "$arg" = "--version" ] && { echo "$APP_NAME $APP_VERSION"; exit 0; }
done

if [ "$(id -u)" -eq 0 ]; then
    root_guard_msg="No ejecutes $APP_NAME completo como root ni con sudo.\n\nLos módulos que necesitan permisos de administrador (Red, Bluetooth, Aplicaciones) ya los piden puntualmente mediante pkexec cuando corresponde. Ejecutar todo el script como root haría que se guardase o restaurase la configuración de la cuenta de root en vez de la tuya.\n\nVuelve a ejecutarlo como tu usuario normal."
    if command -v zenity >/dev/null 2>&1; then
        zenity --error --title="$APP_NAME" --text="$root_guard_msg" --width=420 2>/dev/null
    else
        echo -e "$root_guard_msg" >&2
    fi
    exit 1
fi

# =============================================================================
# VARIABLES
# =============================================================================

BACKUPS_ROOT="${MINT_SETUP_BACKUPS_DIR:-$HOME/MintSetupBackups}"
if ! mkdir -p "$BACKUPS_ROOT" 2>/dev/null || [ ! -w "$BACKUPS_ROOT" ]; then
    backups_root_err="No se pudo crear (o escribir en) la carpeta de copias de seguridad:\n$BACKUPS_ROOT\n\nComprueba la ruta y los permisos, o define otra carpeta en la variable de entorno MINT_SETUP_BACKUPS_DIR."
    if command -v zenity >/dev/null 2>&1; then
        zenity --error --title="$APP_NAME" --text="$backups_root_err" --width=420 2>/dev/null
    else
        echo -e "$backups_root_err" >&2
    fi
    exit 1
fi
# Restringido por si el usuario ya tenía esta carpeta creada de antes (con
# permisos por defecto) de una versión anterior del script; umask 077 ya
# cubre el caso de que se cree ahora por primera vez.
chmod 700 "$BACKUPS_ROOT" 2>/dev/null || true

# Carpeta para las copias del header LUKS (ver sección correspondiente más
# abajo). No se crea aquí, solo cuando el usuario usa esa función por
# primera vez, para no generar una carpeta vacía a quien no cifra ningún
# disco.
LUKS_HEADERS_DIR="$BACKUPS_ROOT/LuksHeaders"

# Lista única de módulos disponibles (clave -> descripción). Se usa tanto
# para el checklist de "Guardar" (todos) como el de "Restaurar" (solo los
# que existan en la configuración elegida), de forma que dar de alta un
# módulo nuevo solo implica añadir sus funciones save_/restore_ y una línea
# aquí, sin tener que acordarse de tocar cada checklist por separado.
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

# Versión corta de cada etiqueta (sin la descripción entre paréntesis), para
# mostrar listas compactas como el resumen de confirmación de Restaurar.
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
# FUNCIONES COMUNES
# =============================================================================

msg_info()  { zenity --info --title="$APP_NAME" --text="$1" --width=380 2>/dev/null; }
msg_error() { zenity --error --title="$APP_NAME" --text="$1" --width=380 2>/dev/null; }
msg_warn()  { zenity --warning --title="$APP_NAME" --text="$1" --width=420 2>/dev/null; }

# Devuelve 0 si el usuario confirma, 1 si cancela
confirm() {
    zenity --question --title="$APP_NAME" --text="$1" --width=380 2>/dev/null
}

# Da formato breve en español a un nº de segundos ("~45 s", "~3 min",
# "~1 h 5 min"). Usado por la barra de progreso de Restaurar para el
# tiempo restante estimado.
fmt_eta() {
    local s="$1"
    if   [ "$s" -lt 60 ];   then printf '~%d s' "$s"
    elif [ "$s" -lt 3600 ]; then printf '~%d min' "$(( (s + 30) / 60 ))"
    else                         printf '~%d h %d min' "$(( s / 3600 ))" "$(( (s % 3600) / 60 ))"
    fi
}

# Da formato al sufijo " · quedan ~Ns" de la barra de Restaurar a partir de
# los segundos que quedarían según la última estimación ($1, puede ser
# negativo si ya se ha superado esa estimación). Aparte se mueve por sí
# sola en tiempo real (ver do_restore) en vez de quedarse clavada en el
# valor calculado la última vez que terminó un módulo.
fmt_eta_txt() {
    local remaining="$1"
    if   [ "$remaining" -ge 1 ];  then printf ' · quedan %s' "$(fmt_eta "$remaining")"
    elif [ "$remaining" -ge -3 ]; then printf ' · terminando...'
    else                                printf ' · tardando más de lo previsto (+%s)' "$(fmt_eta $(( -remaining )))"
    fi
}

check_dependencies() {
    local missing=() cmd
    for cmd in zenity dconf gsettings apt-get tar; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        local text="Faltan herramientas necesarias para ejecutar $APP_NAME:\n${missing[*]}\n\nInstálalas con:\nsudo apt install ${missing[*]}"
        if command -v zenity >/dev/null 2>&1; then
            zenity --error --title="$APP_NAME" --text="$text" --width=420 2>/dev/null
        else
            echo -e "$text" >&2
        fi
        exit 1
    fi
    # El resto de herramientas que usa el programa son opcionales; cada
    # módulo comprueba su propia presencia por separado (ver cabecera).
}

# Comprueba si hay un proceso con ese nombre exacto en ejecución. Se usa
# antes de guardar/restaurar perfiles de aplicaciones basadas en archivos
# (Firefox, LibreWolf, Thunderbird, LibreOffice, ONLYOFFICE): tocar esos
# archivos mientras la aplicación está abierta puede dejar el perfil
# inconsistente o corrupto (bases de datos SQLite a medio escribir, etc.).
is_running() {
    # Si pgrep no está instalado no podemos comprobarlo con seguridad. Devolvemos
    # "sí podría estar en ejecución" (en vez de "no lo está") para que los módulos
    # que llaman a esta función pequen de cautos y no arriesguen corromper un
    # perfil por una falsa sensación de seguridad. pgrep viene con procps, que
    # está presente de fábrica en Mint, así que esto solo entra en juego en
    # instalaciones muy recortadas.
    if ! command -v pgrep >/dev/null 2>&1; then
        return 0
    fi
    pgrep -x "$1" >/dev/null 2>&1
}

# Devuelve la ruta real de una carpeta estándar del usuario ($1: DESKTOP,
# PICTURES...) usando xdg-user-dir, que funciona sea cual sea el idioma del
# sistema (Escritorio, Desktop, Bureau, Schreibtisch...). Si xdg-user-dir no
# está instalado, o esa carpeta no está definida (xdg-user-dir devuelve
# $HOME en ese caso), se usa $2 como valor de respaldo.
xdg_dir() {
    local kind="$1" fallback="$2" out
    if command -v xdg-user-dir >/dev/null 2>&1; then
        out=$(xdg-user-dir "$kind" 2>/dev/null)
        [ -n "$out" ] && [ "$out" != "$HOME" ] && { printf '%s' "$out"; return 0; }
    fi
    printf '%s' "$fallback"
}

# Empaqueta la carpeta $1 (ruta absoluta) en el archivo $2 (.tar.gz), solo si
# $1 existe y contiene algo. Se usa para las carpetas "opcionales" (temas,
# iconos, fuentes, lanzadores...) que pueden no existir en todos los equipos.
pack_dir() {
    local src="$1" dest="$2"
    [ -d "$src" ] || return 0
    [ -n "$(ls -A "$src" 2>/dev/null)" ] || return 0
    tar czf "$dest" -C "$(dirname "$src")" "$(basename "$src")" 2>/dev/null || true
}

# Extrae el archivo $1 (.tar.gz) dentro de la carpeta padre $2, si $1 existe.
# $2 debe ser la carpeta que CONTIENE a la carpeta original (p. ej. si se
# empaquetó ~/.themes, aquí se pasa "$HOME" para que se recree ~/.themes).
unpack_dir() {
    local archive="$1" parent="$2"
    [ -f "$archive" ] || return 0
    mkdir -p "$parent"
    tar xzf "$archive" -C "$parent" 2>/dev/null || true
}

# Guarda en $1 el archivo de imagen real al que apunta la clave de fondo de
# pantalla $2 (picture-uri o picture-uri-dark), con nombre "wallpaper$3-*",
# para que sobreviva a una instalación limpia aunque la ruta original ya no
# exista. $3 es un sufijo ("" para claro, "-dark" para oscuro) que evita que
# ambos fondos choquen si son imágenes distintas.
save_wallpaper_uri() {
    local dir="$1" key="$2" suffix="$3" uri path
    uri=$(gsettings get org.cinnamon.desktop.background "$key" 2>/dev/null | sed -e "s/^'//" -e "s/'\$//")
    [[ "$uri" == file://* ]] || return 0
    path="${uri#file://}"
    path=$(printf '%b' "${path//%/\\x}")
    if [ -f "$path" ]; then
        cp "$path" "$dir/wallpaper${suffix}-$(basename "$path")" 2>/dev/null || true
        basename "$path" > "$dir/wallpaper${suffix}.filename"
    fi
}

# Percent-codifica una ruta para poder usarla como file:// URI (RFC 3986).
# LC_ALL=C fuerza a bash a iterar byte a byte (no carácter UTF-8), que es
# justo lo que hace falta para codificar cada byte de un nombre con tildes.
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

# Inverso de save_wallpaper_uri(): si $1/wallpaper$3.filename existe, copia la
# imagen guardada a ~/Imágenes/MintSetupWallpapers y apunta la clave $2 ahí.
# El nombre se percent-codifica al construir el URI (espacios, tildes...);
# sin esto, un fondo con espacios en el nombre dejaba un file:// inválido.
restore_wallpaper_uri() {
    local dir="$1" key="$2" suffix="$3" fname pics_dir dest
    [ -f "$dir/wallpaper${suffix}.filename" ] || return 0
    fname=$(cat "$dir/wallpaper${suffix}.filename")
    [ -f "$dir/wallpaper${suffix}-$fname" ] || return 0
    pics_dir="$(xdg_dir PICTURES "$HOME/Pictures")/MintSetupWallpapers"
    mkdir -p "$pics_dir"
    dest="$pics_dir/$fname"
    cp "$dir/wallpaper${suffix}-$fname" "$dest" 2>/dev/null || true
    gsettings set org.cinnamon.desktop.background "$key" "file://$(uri_encode_path "$dest")" 2>/dev/null || true
}

# "dconf load" es ADITIVO: solo escribe las claves presentes en el volcado y
# deja intactas las que ya hubiera en el sistema. Si una clave (p. ej. el
# color de un perfil de terminal) se cambió DESPUÉS de guardar, restaurar no
# la revierte, porque el valor viejo nunca aparece en el archivo. Por eso
# antes de cargar se resetea la ruta, para que la restauración sea exacta.
# Solo se usa con rutas de propiedad EXCLUSIVA de un módulo.
dconf_load_clean() {
    local target="$1" file="$2"
    [ -f "$file" ] || return 0
    dconf reset -f "$target" 2>/dev/null || true
    dconf load "$target" < "$file"
}

# Subrutas de /org/cinnamon/ que ya guarda por su cuenta otro módulo
# (Apariencia, Sonido, Teclado, Ratón, Touchpad, Pantallas). dconf load solo
# toca las secciones presentes en el archivo que carga y deja intactas las
# demás (a cualquier profundidad), así que basta con no incluirlas al guardar
# Escritorio para que restaurarlo sin esos otros módulos no los sobrescriba
# también con lo que hubiera en ese momento.
CINNAMON_DESKTOP_EXCLUDE_PATHS=(
    desktop/interface desktop/wm/preferences desktop/screensaver
    desktop/background desktop/sound settings-daemon/peripherals/keyboard
    settings-daemon/peripherals/mouse settings-daemon/peripherals/touchpad
    settings-daemon/plugins/xrandr
)

# Igual que dconf_load_clean(), pero para /org/cinnamon/ (Escritorio), que
# comparte raíz con los módulos de arriba. Un "dconf reset -f" de toda la
# ruta borraría también su configuración aunque no se estén restaurando
# ahora, así que en vez de eso se resetea solo lo que el propio volcado va a
# sobrescribir: cada subcarpeta que contiene (nunca son las excluidas, porque
# el volcado ya se generó sin ellas) y, clave a clave, las sueltas de la raíz
# (paneles, applets, atajos...), sin tocar el resto del árbol.
dconf_load_desktop_clean() {
    local target="$1" file="$2" line section
    [ -f "$file" ] || return 0
    section=""
    while IFS= read -r line; do
        case "$line" in
            \[*\])
                section="${line#[}"; section="${section%]}"
                [ "$section" = "/" ] && section=""
                [ -n "$section" ] && { dconf reset -f "${target}${section}/" 2>/dev/null || true; }
                ;;
            *=*)
                if [ -z "$section" ]; then
                    dconf reset "${target}${line%%=*}" 2>/dev/null || true
                fi
                ;;
        esac
    done < "$file"
    dconf load "$target" < "$file"
}

# Patrones de exclusión comunes al empaquetar perfiles de aplicaciones
# basadas en Mozilla (Firefox, LibreWolf, Thunderbird): cachés y datos
# regenerables que solo aumentan el tamaño de la copia sin aportar
# configuración real, y archivos de bloqueo que no deben restaurarse (el
# perfil se guarda con la aplicación cerrada, así que no deberían existir,
# pero si quedaron de una sesión anterior no queremos arrastrarlos).
MOZILLA_PROFILE_EXCLUDES=(
    --exclude='cache2' --exclude='startupCache' --exclude='shader-cache'
    --exclude='thumbnails' --exclude='crashes' --exclude='minidumps'
    --exclude='saved-telemetry-pings' --exclude='lock' --exclude='.parentlock'
    --exclude='*.sqlite-wal' --exclude='*.sqlite-shm'
)

# Muestra un selector con las configuraciones guardadas (más reciente
# primero) y devuelve por stdout la ruta elegida, o nada si se cancela.
pick_backup_dir() {
    local title="$1" options=() d size NAME DATE
    while IFS= read -r d; do
        [ -f "$d/manifest.conf" ] || continue
        NAME=""; DATE=""
        # shellcheck disable=SC1090,SC1091
        source "$d/manifest.conf"
        size=$(du -sh "$d" 2>/dev/null | cut -f1)
        [ -z "$size" ] && size="tamaño desconocido"
        options+=("$d" "${NAME} — ${DATE} (${size})")
    done < <(find "$BACKUPS_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)

    if [ ${#options[@]} -eq 0 ]; then
        msg_error "Todavía no hay ninguna configuración guardada."
        return 1
    fi

    zenity --list --title="$title" \
        --text="Selecciona una configuración guardada:" \
        --width=520 --height=360 \
        --column="Ruta" --column="Configuración" \
        --hide-column=1 --print-column=1 \
        "${options[@]}" 2>/dev/null
}

# Igual que pick_backup_dir, pero con checklist para elegir varias copias
# a la vez (usado por "Eliminar configuraciones guardadas"). Cada línea de
# salida es una ruta.
pick_backup_dirs_multi() {
    local title="$1" options=() d size NAME DATE
    while IFS= read -r d; do
        [ -f "$d/manifest.conf" ] || continue
        NAME=""; DATE=""
        # shellcheck disable=SC1090,SC1091
        source "$d/manifest.conf"
        size=$(du -sh "$d" 2>/dev/null | cut -f1)
        [ -z "$size" ] && size="tamaño desconocido"
        options+=(FALSE "$d" "${NAME} — ${DATE} (${size})")
    done < <(find "$BACKUPS_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)

    if [ ${#options[@]} -eq 0 ]; then
        msg_error "Todavía no hay ninguna configuración guardada."
        return 1
    fi

    zenity --list --title="$title" \
        --text="Marca una o varias configuraciones guardadas:" \
        --checklist --width=560 --height=380 \
        --column="Sel" --column="Ruta" --column="Configuración" \
        --hide-column=2 --print-column=2 --separator=$'\n' \
        "${options[@]}" 2>/dev/null
}

# Devuelve éxito si algún módulo de "$2..." aparece en la lista $1
# (separada por espacios). La usan tanto los avisos/confirmaciones como
# root_preauth() para saber si hace falta contraseña de administrador.
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

# Refresco periódico (segundos) de la autorización de PolicyKit mientras
# dura una operación larga. La política por defecto (auth_admin_keep)
# caduca a los pocos minutos de inactividad; sin este refresco, instalar
# muchos paquetes o transferir Red/Bluetooth podría hacer que se pidiera
# la contraseña una segunda vez a mitad de la operación.
ROOT_KEEPALIVE_INTERVAL=180
ROOT_KEEPALIVE_PID=""

# Todas las llamadas a pkexec pasan por aquí. flock serializa los pkexec
# simultáneos (ver do_restore, que lanza varios módulos con permisos de
# administrador a la vez) para reutilizar el permiso ya concedido por
# root_preauth en vez de duplicar el diálogo. </dev/null bloquea además el
# prompt de texto de pkexec en la terminal si no hay agente gráfico: sin
# tty legible falla limpio, en vez de pedir ahí una contraseña que nunca
# valida (siempre da "authentication failure" en ese contexto).
PKEXEC_LOCK="${XDG_RUNTIME_DIR:-/tmp}/.${APP_NAME}-pkexec.lock"
prun() { flock "$PKEXEC_LOCK" pkexec "$@" </dev/null; }

root_keepalive_start() {
    [ -n "$ROOT_KEEPALIVE_PID" ] && return 0
    command -v pkexec >/dev/null 2>&1 || return 0
    ( while sleep "$ROOT_KEEPALIVE_INTERVAL"; do prun true 2>/dev/null || exit 0; done ) &
    ROOT_KEEPALIVE_PID=$!
    disown "$ROOT_KEEPALIVE_PID" 2>/dev/null || true
}

root_keepalive_stop() {
    [ -n "$ROOT_KEEPALIVE_PID" ] && kill "$ROOT_KEEPALIVE_PID" 2>/dev/null
    ROOT_KEEPALIVE_PID=""
}
# Red de seguridad: si el script termina por cualquier vía sin haber
# llamado a root_keepalive_stop explícitamente, esto evita dejar un
# "pkexec true" en segundo plano que reaparezca minutos después.
trap 'root_keepalive_stop' EXIT

# Pide la contraseña de administrador UNA sola vez para todos los módulos
# de "$2..." que la necesiten (root_keys en "$1"), antes de abrir la
# barra de progreso, y mantiene la autorización viva (ver arriba) hasta
# que el llamador invoque root_keepalive_stop. Devuelve 1 solo si hacía
# falta y el usuario la denegó/canceló.
root_preauth() {
    local root_keys="$1"; shift
    modules_need_root "$root_keys" "$@" || return 0
    command -v pkexec >/dev/null 2>&1 || return 0
    prun true 2>/dev/null || return 1
    # Margen antes de que los módulos lancen su propio pkexec en paralelo:
    # si arrancan demasiado pegados a esta autenticación, el agente
    # gráfico puede mostrar un diálogo fantasma (aparece y se cierra solo)
    # mientras PolicyKit termina de registrar el permiso concedido.
    sleep 1.5
    root_keepalive_start
}

# =============================================================================
# MÓDULO: ESCRITORIO CINNAMON
# (paneles, menú, applets, desklets, extensiones, workspaces, esquinas
# activas, comportamiento de ventanas)
# =============================================================================

save_desktop() {
    local dir="$1/desktop"
    mkdir -p "$dir"

    echo "Guardando árbol de configuración de Cinnamon..."
    # Se excluyen las secciones que ya guardan por su cuenta Apariencia,
    # Sonido, Teclado, Ratón, Touchpad y Pantallas (ver
    # CINNAMON_DESKTOP_EXCLUDE_PATHS) para que Escritorio quede
    # verdaderamente independiente de esos módulos. favorite-apps (los
    # lanzadores favoritos del panel) se conserva: vive en la raíz.
    dconf dump /org/cinnamon/ 2>/dev/null | awk -v list="${CINNAMON_DESKTOP_EXCLUDE_PATHS[*]}" '
        BEGIN { n = split(list, excl, " ") }
        /^\[.*\]$/ {
            sect = substr($0, 2, length($0) - 2)
            skip = 0
            for (i = 1; i <= n; i++) if (sect == excl[i] || index(sect, excl[i] "/") == 1) { skip = 1; break }
        }
        !skip
    ' > "$dir/cinnamon.dconf"

    echo "Guardando applets/desklets/extensiones instalados por el usuario..."
    pack_dir "$HOME/.local/share/cinnamon/applets"    "$dir/user-applets.tar.gz"
    pack_dir "$HOME/.local/share/cinnamon/desklets"   "$dir/user-desklets.tar.gz"
    pack_dir "$HOME/.local/share/cinnamon/extensions" "$dir/user-extensions.tar.gz"

    # Los ajustes propios de cada instancia de applet/desklet (p. ej. el
    # icono del menú, texto de un applet, o la ubicación de uno de clima) no
    # viven en dconf: Cinnamon los guarda como JSON en ~/.cinnamon/configs/.
    echo "Guardando ajustes de applets/desklets (icono del menú y demás)..."
    pack_dir "$HOME/.cinnamon/configs" "$dir/configs.tar.gz"

    # Cuando el icono del menú se elige como "archivo personalizado" (en vez
    # de un icono del tema), Cinnamon lo copia suelto en la raíz de
    # ~/.cinnamon/ (p. ej. .menu.svg), fuera de configs/. Sin esto se pierde
    # ese icono al restaurar aunque el JSON de arriba siga apuntando a él.
    echo "Guardando icono de menú personalizado (si lo hay)..."
    if [ -d "$HOME/.cinnamon" ] && [ -n "$(find "$HOME/.cinnamon" -maxdepth 1 -type f -print -quit 2>/dev/null)" ]; then
        find "$HOME/.cinnamon" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null \
            | tar czf "$dir/cinnamon-root-files.tar.gz" -C "$HOME/.cinnamon" -T - 2>/dev/null || true
    fi

    echo "Escritorio Cinnamon guardado."
}

restore_desktop() {
    local dir="$1/desktop"
    if [ ! -d "$dir" ]; then
        echo "No hay datos de escritorio en esta configuración guardada."
        return 0
    fi

    mkdir -p "$HOME/.local/share/cinnamon"
    [ -f "$dir/user-applets.tar.gz" ]    && { echo "Restaurando applets..."; tar xzf "$dir/user-applets.tar.gz" -C "$HOME/.local/share/cinnamon"; }
    [ -f "$dir/user-desklets.tar.gz" ]   && { echo "Restaurando desklets..."; tar xzf "$dir/user-desklets.tar.gz" -C "$HOME/.local/share/cinnamon"; }
    [ -f "$dir/user-extensions.tar.gz" ] && { echo "Restaurando extensiones..."; tar xzf "$dir/user-extensions.tar.gz" -C "$HOME/.local/share/cinnamon"; }
    [ -f "$dir/configs.tar.gz" ]         && { echo "Restaurando ajustes de applets/desklets (icono del menú y demás)..."; unpack_dir "$dir/configs.tar.gz" "$HOME/.cinnamon"; }
    [ -f "$dir/cinnamon-root-files.tar.gz" ] && { echo "Restaurando icono de menú personalizado..."; unpack_dir "$dir/cinnamon-root-files.tar.gz" "$HOME/.cinnamon"; }

    if [ -f "$dir/cinnamon.dconf" ]; then
        echo "Restaurando árbol de configuración de Cinnamon..."
        dconf_load_desktop_clean /org/cinnamon/ "$dir/cinnamon.dconf"
    fi

    echo "Escritorio Cinnamon restaurado. Puede que necesites reiniciar Cinnamon (Ctrl+Alt+Esc) o cerrar sesión."
}

# =============================================================================
# MÓDULO: APARIENCIA
# (tema, claro/oscuro, iconos, cursor, fuentes, fondo, protector de pantalla)
# =============================================================================

save_appearance() {
    local dir="$1/appearance"
    mkdir -p "$dir"

    echo "Guardando tema, iconos, cursor y fuentes..."
    dconf dump /org/cinnamon/desktop/interface/ > "$dir/interface.dconf" 2>/dev/null || true

    # "Preferir modo oscuro" (Temas) NO vive bajo /org/cinnamon/: se guarda en
    # org.x.apps.portal (lo usan Nemo, Xed y el resto de X-Apps) y, aparte,
    # hay que reflejarlo en org.gnome.desktop.interface para que apps
    # GTK4/libadwaita y Flatpak (Firefox incluido) sigan el mismo modo.
    echo "Guardando preferencia de modo claro/oscuro..."
    dconf dump /org/x/apps/portal/ > "$dir/xapps-portal.dconf" 2>/dev/null || true
    gsettings get org.gnome.desktop.interface color-scheme > "$dir/gnome-color-scheme.value" 2>/dev/null || true

    # El tema "Escritorio" (paneles, menú, applets) es un ajuste distinto al
    # de arriba: aquí se guarda una copia por si se restaura Apariencia sin
    # Escritorio. El módulo Escritorio también lo incluye (forma parte de su
    # volcado completo de /org/cinnamon/), así que restaurar cualquiera de
    # los dos ya lo aplica; guardarlo aquí solo evita depender de tener que
    # marcar ambos módulos a la vez para recuperar el aspecto completo.
    echo "Guardando tema de Cinnamon (Escritorio)..."
    dconf dump /org/cinnamon/theme/ > "$dir/cinnamon-theme.dconf" 2>/dev/null || true

    echo "Guardando tema de ventanas..."
    dconf dump /org/cinnamon/desktop/wm/preferences/ > "$dir/wm-preferences.dconf" 2>/dev/null || true

    echo "Guardando protector de pantalla..."
    dconf dump /org/cinnamon/desktop/screensaver/ > "$dir/screensaver.dconf" 2>/dev/null || true

    echo "Guardando configuración del fondo de pantalla..."
    dconf dump /org/cinnamon/desktop/background/ > "$dir/background.dconf" 2>/dev/null || true

    # Copiamos también el archivo de imagen real (claro y oscuro): tras una
    # instalación limpia la ruta guardada puede no existir todavía.
    save_wallpaper_uri "$dir" picture-uri ""
    save_wallpaper_uri "$dir" picture-uri-dark "-dark"

    echo "Guardando configuración GTK3..."
    [ -f "$HOME/.config/gtk-3.0/settings.ini" ] && cp "$HOME/.config/gtk-3.0/settings.ini" "$dir/gtk3-settings.ini"

    # Los pasos anteriores solo guardan el NOMBRE del tema/iconos/cursor (la
    # clave dconf). Si es un tema descargado por el usuario (no viene con
    # Mint de fábrica), ese nombre no sirve de nada tras una instalación
    # limpia si no existe también la carpeta del tema. Empaquetamos las
    # carpetas donde vive ese contenido, solo si existen.
    echo "Guardando archivos de temas GTK/Cinnamon instalados por el usuario..."
    pack_dir "$HOME/.themes"             "$dir/themes.tar.gz"
    pack_dir "$HOME/.local/share/themes" "$dir/themes-local.tar.gz"

    echo "Guardando archivos de temas de iconos y cursor instalados por el usuario..."
    pack_dir "$HOME/.icons"              "$dir/icons.tar.gz"
    pack_dir "$HOME/.local/share/icons"  "$dir/icons-local.tar.gz"

    echo "Guardando fuentes instaladas por el usuario..."
    pack_dir "$HOME/.fonts"              "$dir/fonts.tar.gz"
    pack_dir "$HOME/.local/share/fonts"  "$dir/fonts-local.tar.gz"

    echo "Apariencia guardada."
}

restore_appearance() {
    local dir="$1/appearance"
    if [ ! -d "$dir" ]; then
        echo "No hay datos de apariencia en esta configuración guardada."
        return 0
    fi

    # Restauramos primero los ARCHIVOS de los temas/iconos/cursor/fuentes, y
    # solo después los ajustes dconf que los nombran por clave. Si se hiciera
    # al revés, el nombre del tema quedaría fijado un instante antes de que
    # sus archivos existan realmente (aunque en la práctica Cinnamon no relee
    # el tema hasta que reinicias sesión, así que este orden es sobre todo
    # por claridad y para cubrir el caso de scripts que reinicien Cinnamon
    # justo después de restaurar).
    echo "Restaurando archivos de temas GTK/Cinnamon..."
    unpack_dir "$dir/themes.tar.gz"       "$HOME"
    unpack_dir "$dir/themes-local.tar.gz" "$HOME/.local/share"

    echo "Restaurando archivos de temas de iconos y cursor..."
    unpack_dir "$dir/icons.tar.gz"        "$HOME"
    unpack_dir "$dir/icons-local.tar.gz"  "$HOME/.local/share"

    if [ -f "$dir/fonts.tar.gz" ] || [ -f "$dir/fonts-local.tar.gz" ]; then
        echo "Restaurando fuentes instaladas por el usuario..."
        unpack_dir "$dir/fonts.tar.gz"       "$HOME"
        unpack_dir "$dir/fonts-local.tar.gz" "$HOME/.local/share"
        if command -v fc-cache >/dev/null 2>&1; then
            fc-cache -f "$HOME/.fonts" "$HOME/.local/share/fonts" >/dev/null 2>&1 || true
        else
            echo "Aviso: fc-cache no está disponible; puede que las fuentes no se vean hasta reiniciar sesión."
        fi
    fi

    [ -f "$dir/interface.dconf" ]      && { echo "Restaurando tema, iconos, cursor y fuentes..."; dconf_load_clean /org/cinnamon/desktop/interface/ "$dir/interface.dconf"; }
    if [ -f "$dir/xapps-portal.dconf" ] || [ -s "$dir/gnome-color-scheme.value" ]; then
        echo "Restaurando preferencia de modo claro/oscuro..."
        [ -f "$dir/xapps-portal.dconf" ] && dconf_load_clean /org/x/apps/portal/ "$dir/xapps-portal.dconf"
        [ -s "$dir/gnome-color-scheme.value" ] && gsettings set org.gnome.desktop.interface color-scheme "$(cat "$dir/gnome-color-scheme.value")" 2>/dev/null
    fi
    [ -f "$dir/cinnamon-theme.dconf" ] && { echo "Restaurando tema de Cinnamon (Escritorio)..."; dconf_load_clean /org/cinnamon/theme/ "$dir/cinnamon-theme.dconf"; }
    [ -f "$dir/wm-preferences.dconf" ] && { echo "Restaurando tema de ventanas..."; dconf_load_clean /org/cinnamon/desktop/wm/preferences/ "$dir/wm-preferences.dconf"; }
    [ -f "$dir/screensaver.dconf" ]    && { echo "Restaurando protector de pantalla..."; dconf_load_clean /org/cinnamon/desktop/screensaver/ "$dir/screensaver.dconf"; }

    # Cargamos primero el árbol dconf del fondo (picture-options, colores...).
    dconf_load_clean /org/cinnamon/desktop/background/ "$dir/background.dconf"

    # Y DESPUÉS corregimos picture-uri (y su variante -dark) para que apunten
    # a la copia local del wallpaper. Si esto se hiciera antes del dconf load,
    # el load sobrescribiría la ruta original guardada, que puede no existir
    # tras una instalación limpia. xdg_dir() se usa dentro del helper en vez
    # de asumir "$HOME/Imágenes", para equipos instalados en otro idioma.
    if [ -f "$dir/wallpaper.filename" ] || [ -f "$dir/wallpaper-dark.filename" ]; then
        echo "Restaurando fondo de pantalla..."
        restore_wallpaper_uri "$dir" picture-uri ""
        restore_wallpaper_uri "$dir" picture-uri-dark "-dark"
    fi

    if [ -f "$dir/gtk3-settings.ini" ]; then
        echo "Restaurando configuración GTK3..."
        mkdir -p "$HOME/.config/gtk-3.0"
        cp "$dir/gtk3-settings.ini" "$HOME/.config/gtk-3.0/settings.ini"
    fi

    echo "Apariencia restaurada."
}

# =============================================================================
# MÓDULO: NEMO
# (escritorio, accesos directos, scripts, acciones personalizadas, prefs)
# =============================================================================

save_nemo() {
    local dir="$1/nemo"
    mkdir -p "$dir"

    echo "Guardando preferencias de Nemo..."
    dconf dump /org/nemo/ > "$dir/nemo.dconf" 2>/dev/null || true

    echo "Guardando scripts de Nemo..."
    pack_dir "$HOME/.local/share/nemo/scripts" "$dir/scripts.tar.gz"

    echo "Guardando acciones personalizadas..."
    pack_dir "$HOME/.local/share/nemo/actions" "$dir/actions.tar.gz"

    echo "Guardando contenido del Escritorio (accesos directos incluidos)..."
    local desk_dir
    desk_dir=$(xdg_dir DESKTOP "$HOME/Escritorio")
    [ -d "$desk_dir" ] || desk_dir="$HOME/Desktop"
    pack_dir "$desk_dir" "$dir/desktop-files.tar.gz"

    echo "Guardando lanzadores personalizados (menú, AppImages, etc.)..."
    pack_dir "$HOME/.local/share/applications" "$dir/user-launchers.tar.gz"

    echo "Guardando marcadores de la barra lateral de Nemo..."
    [ -f "$HOME/.config/gtk-3.0/bookmarks" ] && cp "$HOME/.config/gtk-3.0/bookmarks" "$dir/bookmarks"

    echo "Nemo guardado."
    echo "Nota: la posición exacta de los iconos del escritorio depende de metadatos"
    echo "internos (gvfs) ligados a cada instalación y no se puede garantizar al 100%"
    echo "tras una instalación limpia."
}

restore_nemo() {
    local dir="$1/nemo"
    if [ ! -d "$dir" ]; then
        echo "No hay datos de Nemo en esta configuración guardada."
        return 0
    fi

    [ -f "$dir/nemo.dconf" ] && { echo "Restaurando preferencias de Nemo..."; dconf_load_clean /org/nemo/ "$dir/nemo.dconf"; }

    mkdir -p "$HOME/.local/share/nemo"
    [ -f "$dir/scripts.tar.gz" ] && { echo "Restaurando scripts de Nemo..."; tar xzf "$dir/scripts.tar.gz" -C "$HOME/.local/share/nemo"; }
    [ -f "$dir/actions.tar.gz" ] && { echo "Restaurando acciones personalizadas..."; tar xzf "$dir/actions.tar.gz" -C "$HOME/.local/share/nemo"; }

    if [ -f "$dir/desktop-files.tar.gz" ]; then
        echo "Restaurando accesos directos del Escritorio (sin sobrescribir archivos existentes)..."
        tar xzkf "$dir/desktop-files.tar.gz" -C "$HOME" 2>/dev/null || true

        # Nemo (igual que Nautilus) exige que cada .desktop del Escritorio
        # tenga permiso de ejecución Y el atributo metadata::trusted, o lo
        # muestra como "no confiable" (icono genérico, aviso al abrirlo) y
        # hay que autorizarlo a mano una vez por archivo. Reproducimos aquí
        # lo que hace Nemo cuando el usuario elige "Confiar y lanzar".
        #
        # El nombre de la carpeta (Escritorio, Desktop, Bureau...) lo leemos
        # del propio archivo en vez de suponerlo: así una copia guardada en
        # un idioma se restaura bien aunque este equipo esté en otro idioma.
        local desk_name desk_dir f
        desk_name=$(tar tzf "$dir/desktop-files.tar.gz" 2>/dev/null | head -1 | cut -d/ -f1)
        desk_dir="$HOME/${desk_name:-Escritorio}"
        if [ -d "$desk_dir" ]; then
            if command -v gio >/dev/null 2>&1; then
                echo "Marcando los accesos directos del Escritorio como de confianza..."
                local trust_failed=0
                while IFS= read -r -d '' f; do
                    chmod +x "$f" 2>/dev/null || true
                    gio set "$f" metadata::trusted true 2>/dev/null || trust_failed=1
                done < <(find "$desk_dir" -maxdepth 1 -name '*.desktop' -print0 2>/dev/null)
                [ "$trust_failed" -eq 1 ] && echo "Aviso: no se pudo marcar algún acceso directo como de confianza (esto es normal si lo ejecutas fuera de una sesión de escritorio real, p. ej. por SSH). Ábrelo una vez desde Nemo y elige 'Confiar y lanzar' si hace falta."
                echo "Nota: si el Escritorio no muestra todavía el icono como de confianza, pulsa F5 sobre él para refrescar la vista; Nemo no siempre lo redibuja solo."
            else
                echo "Aviso: gio no está disponible; puede que tengas que autorizar cada acceso directo del Escritorio manualmente (clic derecho > Permitir lanzamiento)."
            fi
        fi
    fi

    if [ -f "$dir/user-launchers.tar.gz" ]; then
        echo "Restaurando lanzadores personalizados (sin sobrescribir archivos existentes)..."
        mkdir -p "$HOME/.local/share/applications"
        tar xzkf "$dir/user-launchers.tar.gz" -C "$HOME/.local/share" 2>/dev/null || true
    fi

    if [ -f "$dir/bookmarks" ]; then
        echo "Restaurando marcadores de la barra lateral de Nemo..."
        mkdir -p "$HOME/.config/gtk-3.0"
        cp "$dir/bookmarks" "$HOME/.config/gtk-3.0/bookmarks"
    fi

    echo "Nemo restaurado."
}

# =============================================================================
# MÓDULO: APLICACIONES
# (paquetes APT del usuario, Flatpak, repositorios adicionales)
# =============================================================================

save_software() {
    local dir="$1/software"
    mkdir -p "$dir"

    echo "Guardando paquetes APT instalados manualmente..."
    apt-mark showmanual 2>/dev/null | sort > "$dir/apt-manual.list"

    if command -v flatpak >/dev/null 2>&1; then
        echo "Guardando repositorios Flatpak (remotes)..."
        flatpak remotes --columns=name,url 2>/dev/null > "$dir/flatpak-remotes.list" || true

        echo "Guardando aplicaciones Flatpak..."
        flatpak list --app --columns=application,origin 2>/dev/null > "$dir/flatpak.list" || true
    fi

    echo "Guardando repositorios adicionales..."
    pack_dir /etc/apt/sources.list.d "$dir/sources-list-d.tar.gz"
    pack_dir /etc/apt/keyrings       "$dir/keyrings.tar.gz"
    pack_dir /etc/apt/trusted.gpg.d  "$dir/trusted-gpg-d.tar.gz"

    local n
    n=$(wc -l < "$dir/apt-manual.list" 2>/dev/null || echo 0)
    echo "Aplicaciones guardadas ($n paquetes APT)."
}

restore_software() {
    local dir="$1/software"
    if [ ! -d "$dir" ]; then
        echo "No hay datos de aplicaciones en esta configuración guardada."
        return 0
    fi

    # Timeouts cortos para que un repositorio adicional caído/obsoleto (muy
    # típico al restaurar sobre una instalación nueva: PPAs que ya no
    # existen o no tienen paquete para esta versión de Mint) falle rápido
    # en vez de agotar los tiempos de espera por defecto de apt.
    local -a APT_FAST=(-o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15 -o Acquire::Retries=1)
    local apt_updated=0 apt_install_pid=""
    if [ -f "$dir/sources-list-d.tar.gz" ] || [ -f "$dir/keyrings.tar.gz" ] || [ -f "$dir/trusted-gpg-d.tar.gz" ]; then
        echo "Restaurando repositorios adicionales (se pedirá contraseña de administrador)..."
        local tmp; tmp=$(mktemp -d)
        [ -f "$dir/sources-list-d.tar.gz" ] && tar xzf "$dir/sources-list-d.tar.gz" -C "$tmp"
        [ -f "$dir/keyrings.tar.gz" ] && tar xzf "$dir/keyrings.tar.gz" -C "$tmp"
        [ -f "$dir/trusted-gpg-d.tar.gz" ] && tar xzf "$dir/trusted-gpg-d.tar.gz" -C "$tmp"
        if command -v pkexec >/dev/null 2>&1; then
            # "ec" guarda el código de salida de la copia (el paso que de
            # verdad importa); el "apt-get update" es solo mejor esfuerzo y
            # no debe decidir si se informa de fallo al restaurar los
            # repositorios. Ya no se silencia su salida (antes iba a
            # /dev/null): esa salida es la que hace avanzar el texto de la
            # barra de progreso mientras dura, en vez de dejarla clavada.
            # La ruta va como argumento posicional ($1), no interpolada en
            # la cadena, para que pkexec no pueda interpretarla como código.
            # shellcheck disable=SC2016
            if prun bash -c 'cp -rn "$1"/* /etc/apt/ 2>/dev/null; ec=$?; apt-get update "${@:2}"; exit $ec' _ "$tmp" "${APT_FAST[@]}"; then
                apt_updated=1
            else
                echo "Aviso: no se pudieron restaurar los repositorios (permisos denegados o cancelado)."
            fi
        else
            echo "Aviso: pkexec no está disponible; no se pueden restaurar los repositorios automáticamente."
        fi
        rm -rf "$tmp"
    fi

    if [ -f "$dir/apt-manual.list" ] && [ -s "$dir/apt-manual.list" ]; then
        # Solo hace falta refrescar aquí si el bloque anterior no lo hizo ya
        # (copia sin repositorios propios, o pkexec falló ahí): evita
        # llamar a "apt-get update" dos veces seguidas, que antes duplicaba
        # esta parte del tiempo de restauración sin ningún beneficio.
        if [ "$apt_updated" -eq 0 ] && command -v pkexec >/dev/null 2>&1; then
            prun apt-get update "${APT_FAST[@]}"
        fi
        echo "Comprobando qué paquetes siguen disponibles en los repositorios..."
        # apt-get install falla en bloque (sin instalar NADA) si uno solo de
        # los paquetes pedidos ya no existe (renombrado, de un PPA que ya no
        # está, etc.). Filtramos antes para que un solo paquete no
        # disponible no impida instalar el resto. Una sola llamada a
        # apt-cache pkgnames (en vez de un "apt-cache show" por paquete, que
        # con cientos de paquetes releía la caché entera cientos de veces)
        # y luego búsquedas en memoria.
        local pkg available=() unavailable=()
        local -A known_pkgs=()
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && known_pkgs["$pkg"]=1
        done < <(apt-cache pkgnames 2>/dev/null)
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            if [ -n "${known_pkgs[$pkg]+x}" ]; then
                available+=("$pkg")
            else
                unavailable+=("$pkg")
            fi
        done < "$dir/apt-manual.list"

        if [ ${#unavailable[@]} -gt 0 ]; then
            echo "Aviso: ${#unavailable[@]} paquete(s) ya no están disponibles en los repositorios actuales y se omitirán:"
            printf '  - %s\n' "${unavailable[@]}"
        fi

        if [ ${#available[@]} -gt 0 ]; then
            echo "Instalando ${#available[@]} paquete(s) APT (se pedirá contraseña de administrador)..."
            if command -v pkexec >/dev/null 2>&1; then
                prun env DEBIAN_FRONTEND=noninteractive apt-get install -y "${available[@]}" || echo "Aviso: algunos paquetes APT no se pudieron instalar."
            else
                echo "Aviso: pkexec no está disponible; instala manualmente los paquetes listados en $dir/apt-manual.list"
            fi
        else
            echo "Aviso: ninguno de los paquetes guardados está disponible para instalar."
        fi
    fi

    if command -v flatpak >/dev/null 2>&1; then
        if [ -f "$dir/flatpak-remotes.list" ] && [ -s "$dir/flatpak-remotes.list" ]; then
            echo "Añadiendo repositorios Flatpak (remotes)..."
            local rname rurl
            while IFS=$'\t' read -r rname rurl; do
                [ -z "$rname" ] || [ -z "$rurl" ] && continue
                flatpak remote-add --if-not-exists "$rname" "$rurl" 2>/dev/null || echo "Aviso: no se pudo añadir el repositorio Flatpak $rname."
            done < "$dir/flatpak-remotes.list"
        fi

        if [ -f "$dir/flatpak.list" ]; then
            echo "Instalando aplicaciones Flatpak..."
            # Agrupadas por origen (normalmente todas "flathub"): una sola
            # llamada a "flatpak install" por origen en vez de una por cada
            # app, que repetía el refresco de metadatos del remote en cada
            # invocación.
            local app origin key
            local -A by_origin=()
            while IFS=$'\t' read -r app origin; do
                [ -z "$app" ] && continue
                key="${origin:-flathub}"
                by_origin["$key"]="${by_origin[$key]:-}${by_origin[$key]:+ }$app"
            done < "$dir/flatpak.list"
            for origin in "${!by_origin[@]}"; do
                # shellcheck disable=SC2086
                flatpak install -y "$origin" ${by_origin[$origin]} 2>/dev/null \
                    || echo "Aviso: alguna app de $origin no se pudo instalar."
            done
        fi
    fi

    echo "Aplicaciones restauradas."
}

# =============================================================================
# MÓDULO: APLICACIONES DE INICIO (autostart)
# =============================================================================

save_startup() {
    local dir="$1/startup"
    mkdir -p "$dir"
    echo "Guardando aplicaciones de inicio..."
    pack_dir "$HOME/.config/autostart" "$dir/autostart.tar.gz"
    echo "Aplicaciones de inicio guardadas."
}

restore_startup() {
    local dir="$1/startup"
    if [ ! -d "$dir" ]; then
        echo "No hay datos de aplicaciones de inicio en esta configuración guardada."
        return 0
    fi
    mkdir -p "$HOME/.config"
    [ -f "$dir/autostart.tar.gz" ] && tar xzf "$dir/autostart.tar.gz" -C "$HOME/.config"
    echo "Aplicaciones de inicio restauradas."
}

# =============================================================================
# MÓDULO: PANTALLAS
# (distribución/resolución de monitores y ajustes del plugin xrandr)
# =============================================================================

save_displays() {
    local dir="$1/displays"
    mkdir -p "$dir"

    echo "Guardando distribución de monitores..."
    [ -f "$HOME/.config/monitors.xml" ] && cp "$HOME/.config/monitors.xml" "$dir/monitors.xml"

    echo "Guardando configuración del plugin xrandr..."
    dconf dump /org/cinnamon/settings-daemon/plugins/xrandr/ > "$dir/xrandr.dconf" 2>/dev/null || true

    echo "Pantallas guardadas."
}

restore_displays() {
    local dir="$1/displays"
    if [ ! -d "$dir" ]; then
        echo "No hay datos de pantallas en esta configuración guardada."
        return 0
    fi

    if [ -f "$dir/monitors.xml" ]; then
        echo "Restaurando distribución de monitores..."
        mkdir -p "$HOME/.config"
        cp "$dir/monitors.xml" "$HOME/.config/monitors.xml"
    fi

    [ -f "$dir/xrandr.dconf" ] && { echo "Restaurando configuración del plugin xrandr..."; dconf_load_clean /org/cinnamon/settings-daemon/plugins/xrandr/ "$dir/xrandr.dconf"; }

    echo "Pantallas restauradas."
    echo "Nota: monitors.xml está ligado al identificador (EDID) de cada monitor;"
    echo "si el hardware de pantalla ha cambiado, puede que tengas que reajustar"
    echo "la distribución desde Configuración > Pantallas."
}

# =============================================================================
# MÓDULO: SONIDO
# (tema de sonido/eventos y dispositivo de salida/entrada predeterminado)
# =============================================================================

save_sound() {
    local dir="$1/sound"
    mkdir -p "$dir"

    echo "Guardando tema de sonido y eventos..."
    dconf dump /org/cinnamon/desktop/sound/ > "$dir/sound.dconf" 2>/dev/null || true

    if command -v pactl >/dev/null 2>&1; then
        echo "Guardando dispositivo de salida/entrada predeterminado..."
        pactl get-default-sink   > "$dir/default-sink.txt"   2>/dev/null || true
        pactl get-default-source > "$dir/default-source.txt" 2>/dev/null || true
    else
        echo "Aviso: pactl no está instalado; solo se guarda el tema de sonido, no el dispositivo predeterminado."
    fi

    echo "Sonido guardado."
}

restore_sound() {
    local dir="$1/sound"
    if [ ! -d "$dir" ]; then
        echo "No hay datos de sonido en esta configuración guardada."
        return 0
    fi

    [ -f "$dir/sound.dconf" ] && { echo "Restaurando tema de sonido y eventos..."; dconf_load_clean /org/cinnamon/desktop/sound/ "$dir/sound.dconf"; }

    if command -v pactl >/dev/null 2>&1; then
        if [ -s "$dir/default-sink.txt" ]; then
            echo "Restaurando dispositivo de salida predeterminado..."
            pactl set-default-sink "$(cat "$dir/default-sink.txt")" 2>/dev/null || echo "Aviso: no se pudo restaurar el dispositivo de salida (puede que ya no exista)."
        fi
        if [ -s "$dir/default-source.txt" ]; then
            echo "Restaurando dispositivo de entrada predeterminado..."
            pactl set-default-source "$(cat "$dir/default-source.txt")" 2>/dev/null || echo "Aviso: no se pudo restaurar el dispositivo de entrada (puede que ya no exista)."
        fi
    else
        echo "Aviso: pactl no está instalado; no se restaura el dispositivo predeterminado."
    fi

    echo "Sonido restaurado."
}

# =============================================================================
# MÓDULO: RED
# (conexiones guardadas de NetworkManager)
# ⚠️ Requiere permisos de administrador tanto para guardar como restaurar,
# porque /etc/NetworkManager/system-connections/ solo lo puede leer root.
# ⚠️ Suele incluir contraseñas Wi-Fi en texto plano.
# =============================================================================

save_network() {
    local dir="$1/network"
    mkdir -p "$dir"

    if ! command -v pkexec >/dev/null 2>&1; then
        echo "Aviso: pkexec no está disponible; no se puede guardar la configuración de red (requiere acceso root)."
        return 0
    fi

    echo "Guardando conexiones de NetworkManager (se pedirá contraseña de administrador)..."
    if pkexec bash -c "tar czf - -C /etc/NetworkManager system-connections 2>/dev/null" > "$dir/system-connections.tar.gz" 2>/dev/null \
        && [ -s "$dir/system-connections.tar.gz" ]; then
        chmod 600 "$dir/system-connections.tar.gz"
        echo "Conexiones de red guardadas."
    else
        echo "Aviso: no se pudieron guardar las conexiones de red (permisos denegados, cancelado, o no hay ninguna)."
        rm -f "$dir/system-connections.tar.gz"
    fi
}

restore_network() {
    local dir="$1/network"
    if [ ! -f "$dir/system-connections.tar.gz" ]; then
        echo "No hay datos de red en esta configuración guardada."
        return 0
    fi

    if ! command -v pkexec >/dev/null 2>&1; then
        echo "Aviso: pkexec no está disponible; no se puede restaurar la configuración de red (requiere acceso root)."
        return 0
    fi

    echo "Restaurando conexiones de NetworkManager, sin sobrescribir las existentes (se pedirá contraseña de administrador)..."
    local tmp; tmp=$(mktemp -d)
    if ! tar xzf "$dir/system-connections.tar.gz" -C "$tmp" 2>/dev/null; then
        echo "Aviso: el archivo de conexiones de red guardado está dañado o incompleto; no se pudo restaurar."
        rm -rf "$tmp"
        return 0
    fi
    # "ec" guarda el código de salida del cp (el paso que de verdad importa);
    # chmod y el reinicio del servicio son mejor esfuerzo y no deben decidir
    # si se informa de éxito o de fallo al restaurar las conexiones. "$tmp"
    # va como argumento posicional ($1), no interpolado en la cadena.
    # shellcheck disable=SC2016
    if prun bash -c 'mkdir -p /etc/NetworkManager/system-connections; cp -rn "$1/system-connections/." /etc/NetworkManager/system-connections/ 2>/dev/null; ec=$?; chmod 600 /etc/NetworkManager/system-connections/* 2>/dev/null; systemctl restart NetworkManager 2>/dev/null; exit $ec' _ "$tmp"; then
        echo "Conexiones de red restauradas."
    else
        echo "Aviso: no se pudieron restaurar las conexiones de red (permisos denegados o cancelado)."
    fi
    rm -rf "$tmp"
}

# =============================================================================
# MÓDULO: BLUETOOTH
# (dispositivos emparejados)
# ⚠️ Requiere permisos de administrador tanto para guardar como restaurar,
# porque /var/lib/bluetooth/ solo lo puede leer root.
# =============================================================================

save_bluetooth() {
    local dir="$1/bluetooth"
    mkdir -p "$dir"

    if ! command -v pkexec >/dev/null 2>&1; then
        echo "Aviso: pkexec no está disponible; no se puede guardar la configuración de Bluetooth (requiere acceso root)."
        return 0
    fi

    echo "Guardando dispositivos Bluetooth emparejados (se pedirá contraseña de administrador)..."
    if pkexec bash -c "tar czf - -C /var/lib bluetooth 2>/dev/null" > "$dir/bluetooth.tar.gz" 2>/dev/null \
        && [ -s "$dir/bluetooth.tar.gz" ]; then
        chmod 600 "$dir/bluetooth.tar.gz"
        echo "Bluetooth guardado."
    else
        echo "Aviso: no se pudo guardar la configuración de Bluetooth (permisos denegados, cancelado, o no hay dispositivos)."
        rm -f "$dir/bluetooth.tar.gz"
    fi
}

restore_bluetooth() {
    local dir="$1/bluetooth"
    if [ ! -f "$dir/bluetooth.tar.gz" ]; then
        echo "No hay datos de Bluetooth en esta configuración guardada."
        return 0
    fi

    if ! command -v pkexec >/dev/null 2>&1; then
        echo "Aviso: pkexec no está disponible; no se puede restaurar Bluetooth (requiere acceso root)."
        return 0
    fi

    echo "Restaurando dispositivos Bluetooth emparejados, sin sobrescribir los existentes (se pedirá contraseña de administrador)..."
    local tmp; tmp=$(mktemp -d)
    if ! tar xzf "$dir/bluetooth.tar.gz" -C "$tmp" 2>/dev/null; then
        echo "Aviso: el archivo de Bluetooth guardado está dañado o incompleto; no se pudo restaurar."
        rm -rf "$tmp"
        return 0
    fi
    # "ec" guarda el código de salida del cp; el reinicio del servicio es
    # mejor esfuerzo y no debe decidir si se informa de éxito o de fallo.
    # "$tmp" va como argumento posicional ($1), no interpolado en la cadena.
    # shellcheck disable=SC2016
    if prun bash -c 'mkdir -p /var/lib/bluetooth; cp -rn "$1/bluetooth/." /var/lib/bluetooth/ 2>/dev/null; ec=$?; systemctl restart bluetooth 2>/dev/null; exit $ec' _ "$tmp"; then
        echo "Bluetooth restaurado."
    else
        echo "Aviso: no se pudo restaurar Bluetooth (permisos denegados o cancelado)."
    fi
    rm -rf "$tmp"
}

# =============================================================================
# MÓDULO: TECLADO
# (distribución(es) de teclado, opciones XKB, velocidad de repetición)
# =============================================================================

save_keyboard() {
    local dir="$1/keyboard"
    mkdir -p "$dir"

    echo "Guardando distribución(es) de teclado y opciones XKB..."
    dconf dump /org/gnome/desktop/input-sources/ > "$dir/input-sources.dconf" 2>/dev/null || true

    echo "Guardando velocidad de repetición y retardo..."
    dconf dump /org/cinnamon/settings-daemon/peripherals/keyboard/ > "$dir/keyboard.dconf" 2>/dev/null || true

    echo "Teclado guardado."
}

restore_keyboard() {
    local dir="$1/keyboard"
    if [ ! -d "$dir" ]; then
        echo "No hay datos de teclado en esta configuración guardada."
        return 0
    fi

    [ -f "$dir/input-sources.dconf" ] && { echo "Restaurando distribución(es) de teclado..."; dconf_load_clean /org/gnome/desktop/input-sources/ "$dir/input-sources.dconf"; }
    [ -f "$dir/keyboard.dconf" ]      && { echo "Restaurando velocidad de repetición y retardo..."; dconf_load_clean /org/cinnamon/settings-daemon/peripherals/keyboard/ "$dir/keyboard.dconf"; }

    echo "Teclado restaurado."
}

# =============================================================================
# MÓDULO: RATÓN
# (velocidad, aceleración, botones invertidos, scroll natural)
# =============================================================================

save_mouse() {
    local dir="$1/mouse"
    mkdir -p "$dir"
    echo "Guardando configuración del ratón..."
    dconf dump /org/cinnamon/settings-daemon/peripherals/mouse/ > "$dir/mouse.dconf" 2>/dev/null || true
    echo "Ratón guardado."
}

restore_mouse() {
    local dir="$1/mouse"
    if [ ! -d "$dir" ]; then
        echo "No hay datos de ratón en esta configuración guardada."
        return 0
    fi
    [ -f "$dir/mouse.dconf" ] && { echo "Restaurando configuración del ratón..."; dconf_load_clean /org/cinnamon/settings-daemon/peripherals/mouse/ "$dir/mouse.dconf"; }
    echo "Ratón restaurado."
}

# =============================================================================
# MÓDULO: TOUCHPAD
# (toque para pulsar, scroll de dos dedos, desactivar al escribir, gestos)
# =============================================================================

save_touchpad() {
    local dir="$1/touchpad"
    mkdir -p "$dir"
    echo "Guardando configuración del touchpad..."
    dconf dump /org/cinnamon/settings-daemon/peripherals/touchpad/ > "$dir/touchpad.dconf" 2>/dev/null || true
    echo "Touchpad guardado."
}

restore_touchpad() {
    local dir="$1/touchpad"
    if [ ! -d "$dir" ]; then
        echo "No hay datos de touchpad en esta configuración guardada."
        return 0
    fi
    [ -f "$dir/touchpad.dconf" ] && { echo "Restaurando configuración del touchpad..."; dconf_load_clean /org/cinnamon/settings-daemon/peripherals/touchpad/ "$dir/touchpad.dconf"; }
    echo "Touchpad restaurado."
}

# =============================================================================
# MÓDULO: FIREFOX
# (perfil completo: marcadores, historial, extensiones y preferencias)
# Cubre la instalación nativa vía apt, que es la que trae Linux Mint por
# defecto. La versión Flatpak guarda el perfil en otra ruta
# (~/.var/app/org.mozilla.firefox/...) y no se detecta automáticamente.
# =============================================================================

save_firefox() {
    local dir="$1/firefox"
    mkdir -p "$dir"

    if [ ! -d "$HOME/.mozilla/firefox" ]; then
        echo "Firefox no está instalado o no tiene perfiles en este equipo."
        return 0
    fi

    if is_running firefox || is_running firefox-esr; then
        echo "Aviso: Firefox está abierto. Ciérralo y vuelve a guardar para evitar una copia inconsistente del perfil."
    fi

    echo "Guardando perfil(es) de Firefox (marcadores, extensiones, preferencias)..."
    tar czf "$dir/firefox-profiles.tar.gz" -C "$HOME/.mozilla" \
        "${MOZILLA_PROFILE_EXCLUDES[@]}" firefox 2>/dev/null || true

    echo "Firefox guardado."
}

restore_firefox() {
    local dir="$1/firefox"
    if [ ! -f "$dir/firefox-profiles.tar.gz" ]; then
        echo "No hay datos de Firefox en esta configuración guardada."
        return 0
    fi

    if is_running firefox || is_running firefox-esr; then
        echo "Aviso: Firefox está abierto; ciérralo y vuelve a restaurar para evitar corromper el perfil. Este módulo se ha omitido."
        return 0
    fi

    echo "Restaurando perfil(es) de Firefox (marcadores, extensiones, preferencias)..."
    mkdir -p "$HOME/.mozilla"
    tar xzf "$dir/firefox-profiles.tar.gz" -C "$HOME/.mozilla"

    echo "Firefox restaurado. Ábrelo para comprobar que carga el perfil correctamente."
}

# =============================================================================
# MÓDULO: LIBREWOLF
# (perfil completo: marcadores, historial, extensiones y preferencias)
# Cubre la instalación nativa vía apt. La versión Flatpak guarda el perfil en
# otra ruta y no se detecta automáticamente.
# =============================================================================

save_librewolf() {
    local dir="$1/librewolf"
    mkdir -p "$dir"

    if [ ! -d "$HOME/.librewolf" ]; then
        echo "LibreWolf no está instalado o no tiene perfiles en este equipo."
        return 0
    fi

    if is_running librewolf; then
        echo "Aviso: LibreWolf está abierto. Ciérralo y vuelve a guardar para evitar una copia inconsistente del perfil."
    fi

    echo "Guardando perfil(es) de LibreWolf (marcadores, extensiones, preferencias)..."
    tar czf "$dir/librewolf-profiles.tar.gz" -C "$HOME" \
        "${MOZILLA_PROFILE_EXCLUDES[@]}" .librewolf 2>/dev/null || true

    echo "LibreWolf guardado."
}

restore_librewolf() {
    local dir="$1/librewolf"
    if [ ! -f "$dir/librewolf-profiles.tar.gz" ]; then
        echo "No hay datos de LibreWolf en esta configuración guardada."
        return 0
    fi

    if is_running librewolf; then
        echo "Aviso: LibreWolf está abierto; ciérralo y vuelve a restaurar para evitar corromper el perfil. Este módulo se ha omitido."
        return 0
    fi

    echo "Restaurando perfil(es) de LibreWolf (marcadores, extensiones, preferencias)..."
    tar xzf "$dir/librewolf-profiles.tar.gz" -C "$HOME"

    echo "LibreWolf restaurado. Ábrelo para comprobar que carga el perfil correctamente."
}

# =============================================================================
# MÓDULO: THUNDERBIRD
# (cuentas, filtros de correo, libreta de direcciones, extensiones)
# Cubre la instalación nativa vía apt. La versión Flatpak guarda el perfil en
# otra ruta y no se detecta automáticamente.
# =============================================================================

save_thunderbird() {
    local dir="$1/thunderbird"
    mkdir -p "$dir"

    if [ ! -d "$HOME/.thunderbird" ]; then
        echo "Thunderbird no está instalado o no tiene perfiles en este equipo."
        return 0
    fi

    if is_running thunderbird; then
        echo "Aviso: Thunderbird está abierto. Ciérralo y vuelve a guardar para evitar una copia inconsistente del perfil."
    fi

    echo "Guardando perfil(es) de Thunderbird (cuentas, filtros, libreta de direcciones, extensiones)..."
    tar czf "$dir/thunderbird-profiles.tar.gz" -C "$HOME" \
        "${MOZILLA_PROFILE_EXCLUDES[@]}" .thunderbird 2>/dev/null || true

    echo "Thunderbird guardado."
    echo "Nota: si alguna cuenta usa POP3 sin 'dejar copia en el servidor', el correo local guardado aquí puede ser la única copia que existe; con IMAP el correo vive en el servidor y esto es solo una caché."
}

restore_thunderbird() {
    local dir="$1/thunderbird"
    if [ ! -f "$dir/thunderbird-profiles.tar.gz" ]; then
        echo "No hay datos de Thunderbird en esta configuración guardada."
        return 0
    fi

    if is_running thunderbird; then
        echo "Aviso: Thunderbird está abierto; ciérralo y vuelve a restaurar para evitar corromper el perfil. Este módulo se ha omitido."
        return 0
    fi

    echo "Restaurando perfil(es) de Thunderbird (cuentas, filtros, libreta de direcciones, extensiones)..."
    tar xzf "$dir/thunderbird-profiles.tar.gz" -C "$HOME"

    echo "Thunderbird restaurado. Ábrelo para comprobar que carga el perfil correctamente."
}

# =============================================================================
# MÓDULO: LIBREOFFICE
# (plantillas, autocorrección, extensiones instaladas, barras de herramientas
# y atajos personalizados, documentos recientes)
# =============================================================================

save_libreoffice() {
    local dir="$1/libreoffice"
    mkdir -p "$dir"

    if [ ! -d "$HOME/.config/libreoffice" ]; then
        echo "LibreOffice no tiene configuración de usuario en este equipo."
        return 0
    fi

    if is_running soffice.bin; then
        echo "Aviso: LibreOffice está abierto (o el inicio rápido activo). Ciérralo del todo y vuelve a guardar para evitar una copia inconsistente."
    fi

    echo "Guardando configuración de usuario de LibreOffice..."
    pack_dir "$HOME/.config/libreoffice" "$dir/libreoffice-config.tar.gz"

    echo "LibreOffice guardado."
}

restore_libreoffice() {
    local dir="$1/libreoffice"
    if [ ! -f "$dir/libreoffice-config.tar.gz" ]; then
        echo "No hay datos de LibreOffice en esta configuración guardada."
        return 0
    fi

    if is_running soffice.bin; then
        echo "Aviso: LibreOffice está abierto (o el inicio rápido activo); ciérralo del todo y vuelve a restaurar. Este módulo se ha omitido."
        return 0
    fi

    echo "Restaurando configuración de usuario de LibreOffice..."
    unpack_dir "$dir/libreoffice-config.tar.gz" "$HOME/.config"

    echo "LibreOffice restaurado."
}

# =============================================================================
# MÓDULO: ONLYOFFICE
# (configuración de usuario y plugins de ONLYOFFICE Desktop Editors)
# =============================================================================

save_onlyoffice() {
    local dir="$1/onlyoffice"
    mkdir -p "$dir"

    if [ ! -d "$HOME/.config/onlyoffice" ]; then
        echo "ONLYOFFICE no tiene configuración de usuario en este equipo."
        return 0
    fi

    if is_running DesktopEditors; then
        echo "Aviso: ONLYOFFICE Desktop Editors está abierto. Ciérralo y vuelve a guardar para evitar una copia inconsistente."
    fi

    echo "Guardando configuración de usuario de ONLYOFFICE..."
    pack_dir "$HOME/.config/onlyoffice" "$dir/onlyoffice-config.tar.gz"

    # Los plugins que el usuario instala a mano (Zotero, Thesaurus, macros
    # propias...) no viven en ~/.config/onlyoffice sino aquí; sin esto se
    # perdían al restaurar en un equipo nuevo.
    if [ -d "$HOME/.local/share/onlyoffice" ]; then
        echo "Guardando plugins de ONLYOFFICE instalados por el usuario..."
        pack_dir "$HOME/.local/share/onlyoffice" "$dir/onlyoffice-plugins.tar.gz"
    fi

    echo "ONLYOFFICE guardado."
}

restore_onlyoffice() {
    local dir="$1/onlyoffice"
    if [ ! -f "$dir/onlyoffice-config.tar.gz" ]; then
        echo "No hay datos de ONLYOFFICE en esta configuración guardada."
        return 0
    fi

    if is_running DesktopEditors; then
        echo "Aviso: ONLYOFFICE Desktop Editors está abierto; ciérralo y vuelve a restaurar. Este módulo se ha omitido."
        return 0
    fi

    echo "Restaurando configuración de usuario de ONLYOFFICE..."
    unpack_dir "$dir/onlyoffice-config.tar.gz" "$HOME/.config"

    [ -f "$dir/onlyoffice-plugins.tar.gz" ] && { echo "Restaurando plugins de ONLYOFFICE..."; unpack_dir "$dir/onlyoffice-plugins.tar.gz" "$HOME/.local/share"; }

    echo "ONLYOFFICE restaurado."
}

# =============================================================================
# MÓDULO: VS CODE
# (extensiones, settings.json, keybindings.json, snippets, perfiles con
# nombre; detecta si lo instalado es la edición estable o Insiders)
# La lista de extensiones se reinstala desde el marketplace con
# "code --install-extension" en vez de copiar la carpeta
# ~/.vscode/extensions entera: pesa mucho menos y evita arrastrar binarios
# nativos compilados para una versión de VS Code o una arquitectura distinta
# a la del equipo donde se restaura.
# =============================================================================

save_vscode() {
    local dir="$1/vscode"
    mkdir -p "$dir"

    # code_user_dir depende de qué variante hay instalada: la carpeta de
    # configuración de VS Code Insiders es distinta ("Code - Insiders") a la
    # de VS Code estable ("Code"). Si solo hay Insiders, usar siempre la
    # ruta de la estable dejaba settings.json/keybindings/snippets sin
    # guardar en silencio (la lista de extensiones sí se guardaba bien,
    # porque esa parte ya usaba "$code_bin" correctamente).
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
        echo "VS Code no está instalado en este equipo."
        return 0
    fi

    if [ -n "$code_bin" ]; then
        echo "Guardando lista de extensiones instaladas..."
        "$code_bin" --list-extensions > "$dir/extensions.list" 2>/dev/null || true
        echo "$code_bin" > "$dir/variant"
    else
        echo "Aviso: no se encontró el comando 'code' en el PATH; no se puede guardar la lista de extensiones (sí se guardarán settings.json y demás)."
    fi

    if [ -n "$code_user_dir" ] && [ -d "$code_user_dir" ]; then
        echo "Guardando settings.json, keybindings.json y snippets..."
        mkdir -p "$dir/User"
        [ -f "$code_user_dir/settings.json" ]    && cp "$code_user_dir/settings.json" "$dir/User/"
        [ -f "$code_user_dir/keybindings.json" ] && cp "$code_user_dir/keybindings.json" "$dir/User/"
        pack_dir "$code_user_dir/snippets" "$dir/snippets.tar.gz"

        # Si el usuario usa la función "Perfiles" de VS Code (varios
        # settings.json/keybindings.json con nombre, para distintos
        # contextos de trabajo), cada uno vive en su propia subcarpeta
        # dentro de User/profiles/. Sin esto, restaurar solo recuperaba el
        # perfil "Default".
        if [ -d "$code_user_dir/profiles" ]; then
            echo "Guardando perfiles con nombre de VS Code..."
            pack_dir "$code_user_dir/profiles" "$dir/profiles.tar.gz"
        fi
    fi

    echo "VS Code guardado."
}

restore_vscode() {
    local dir="$1/vscode"
    if [ ! -d "$dir" ]; then
        echo "No hay datos de VS Code en esta configuración guardada."
        return 0
    fi

    # Preferimos la variante realmente instalada en ESTE equipo; si no hay
    # ninguna en el PATH (p. ej. se restaura antes de instalar VS Code),
    # recurrimos a la variante con la que se guardó ("variant"), y en
    # último caso a la carpeta de la edición estable.
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
            echo "Instalando extensiones de VS Code..."
            # Todas en una sola invocación de "code" (acepta --install-extension
            # repetido): cada arranque del proceso cuesta varios segundos, y
            # antes se pagaba ese coste una vez POR EXTENSIÓN. Ya no se
            # silencia la salida, así que el resultado de cada extensión se
            # ve en el detalle de la restauración.
            local ext; local -a ext_args=()
            while IFS= read -r ext; do
                [ -n "$ext" ] && ext_args+=(--install-extension "$ext")
            done < "$dir/extensions.list"
            if [ ${#ext_args[@]} -gt 0 ]; then
                "$code_bin" "${ext_args[@]}" --force \
                    || echo "Aviso: alguna extensión no se pudo instalar (revisa el detalle anterior); puede haberse retirado del marketplace o cambiado de identificador."
            fi
        else
            echo "Aviso: VS Code no está instalado (o 'code' no está en el PATH); instala VS Code y vuelve a restaurar este módulo para recuperar las extensiones."
        fi
    fi

    if [ -d "$dir/User" ]; then
        echo "Restaurando settings.json y keybindings.json..."
        mkdir -p "$code_user_dir"
        [ -f "$dir/User/settings.json" ]    && cp "$dir/User/settings.json" "$code_user_dir/"
        [ -f "$dir/User/keybindings.json" ] && cp "$dir/User/keybindings.json" "$code_user_dir/"
    fi

    [ -f "$dir/snippets.tar.gz" ] && { echo "Restaurando snippets..."; unpack_dir "$dir/snippets.tar.gz" "$code_user_dir"; }
    [ -f "$dir/profiles.tar.gz" ] && { echo "Restaurando perfiles con nombre de VS Code..."; unpack_dir "$dir/profiles.tar.gz" "$code_user_dir"; }

    echo "VS Code restaurado. Si estaba abierto, reinícialo para que cargue los cambios."
}

# =============================================================================
# MÓDULO: DOCKER
# (config. de usuario ~/.docker, /etc/docker/daemon.json, grupo docker)
# ⚠️ Solo la parte del daemon y el grupo docker requieren permisos de
# administrador (vía pkexec); la configuración de usuario no.
# =============================================================================

save_docker() {
    local dir="$1/docker" current_user
    mkdir -p "$dir"

    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker no está instalado en este equipo."
        return 0
    fi

    if [ -f /etc/docker/daemon.json ]; then
        echo "Guardando configuración del daemon de Docker..."
        if ! cp /etc/docker/daemon.json "$dir/daemon.json" 2>/dev/null; then
            if command -v pkexec >/dev/null 2>&1; then
                pkexec cat /etc/docker/daemon.json > "$dir/daemon.json" 2>/dev/null || true
                [ -s "$dir/daemon.json" ] || rm -f "$dir/daemon.json"
            else
                echo "Aviso: no se pudo leer /etc/docker/daemon.json (sin permisos de lectura y pkexec no disponible)."
            fi
        fi
    fi

    if [ -d "$HOME/.docker" ]; then
        echo "Guardando configuración de Docker CLI del usuario (contexts, config.json)..."
        pack_dir "$HOME/.docker" "$dir/user-docker.tar.gz"
    fi

    current_user=$(id -un)
    if getent group docker >/dev/null 2>&1 && id -nG "$current_user" 2>/dev/null | grep -qw docker; then
        echo "true" > "$dir/user-in-docker-group"
    fi

    echo "Docker guardado."
    echo "Nota: si tu ~/.docker/config.json guarda credenciales de registros sin un 'credential helper' (campo \"auths\" con contraseñas en base64 en vez de \"credsStore\"), esta copia contendrá esas credenciales. Protege bien la carpeta de copia de seguridad."
}

restore_docker() {
    local dir="$1/docker" current_user
    if [ ! -d "$dir" ]; then
        echo "No hay datos de Docker en esta configuración guardada."
        return 0
    fi

    if ! command -v docker >/dev/null 2>&1; then
        echo "Aviso: Docker no está instalado en este equipo; instálalo y vuelve a restaurar este módulo."
    fi

    if [ -f "$dir/daemon.json" ]; then
        echo "Restaurando configuración del daemon de Docker (se pedirá contraseña de administrador)..."
        if command -v pkexec >/dev/null 2>&1; then
            # "ec" guarda el código de salida del cp; el reinicio del
            # servicio es mejor esfuerzo y no debe decidir si se informa de
            # éxito o de fallo. "$dir" va como argumento posicional ($1),
            # no interpolado en la cadena.
            # shellcheck disable=SC2016
            prun bash -c 'mkdir -p /etc/docker 2>/dev/null; cp "$1/daemon.json" /etc/docker/daemon.json 2>/dev/null; ec=$?; systemctl restart docker 2>/dev/null; exit $ec' _ "$dir" \
                || echo "Aviso: no se pudo restaurar /etc/docker/daemon.json (permisos denegados o cancelado)."
        else
            echo "Aviso: pkexec no está disponible; copia manualmente $dir/daemon.json a /etc/docker/daemon.json."
        fi
    fi

    if [ -f "$dir/user-docker.tar.gz" ]; then
        echo "Restaurando configuración de Docker CLI del usuario..."
        unpack_dir "$dir/user-docker.tar.gz" "$HOME"
    fi

    if [ -f "$dir/user-in-docker-group" ]; then
        current_user=$(id -un)
        if getent group docker >/dev/null 2>&1; then
            if id -nG "$current_user" 2>/dev/null | grep -qw docker; then
                echo "Tu usuario ya pertenece al grupo docker."
            elif command -v pkexec >/dev/null 2>&1; then
                echo "Añadiendo tu usuario al grupo docker (se pedirá contraseña de administrador)..."
                prun usermod -aG docker "$current_user" \
                    && echo "Hecho. Cierra sesión y vuelve a entrar para que el cambio de grupo surta efecto." \
                    || echo "Aviso: no se pudo añadir tu usuario al grupo docker (permisos denegados o cancelado)."
            else
                echo "Aviso: pkexec no está disponible; añádete al grupo manualmente con: sudo usermod -aG docker \$USER"
            fi
        else
            echo "Aviso: el grupo 'docker' no existe todavía en este equipo; instala el paquete docker.io/docker-ce antes de añadir el usuario al grupo."
        fi
    fi

    echo "Docker restaurado."
}

# =============================================================================
# MÓDULO: TERMINAL
# (perfiles de GNOME Terminal, .bashrc/.zshrc y otros archivos de shell)
# =============================================================================

TERMINAL_SHELL_FILES=(.bashrc .bash_aliases .bash_profile .bash_logout .profile .zshrc .zprofile .tmux.conf .inputrc .dircolors)

save_terminal() {
    local dir="$1/terminal" f
    mkdir -p "$dir"

    echo "Guardando perfiles de GNOME Terminal (colores, fuente, atajos)..."
    dconf dump /org/gnome/terminal/legacy/ > "$dir/gnome-terminal.dconf" 2>/dev/null || true

    echo "Guardando archivos de configuración de la shell..."
    for f in "${TERMINAL_SHELL_FILES[@]}"; do
        [ -f "$HOME/$f" ] && cp "$HOME/$f" "$dir/$f"
    done

    if [ -f "$HOME/.config/starship.toml" ]; then
        echo "Guardando configuración de Starship..."
        mkdir -p "$dir/config"
        cp "$HOME/.config/starship.toml" "$dir/config/"
    fi
    [ -f "$HOME/.p10k.zsh" ] && cp "$HOME/.p10k.zsh" "$dir/"

    echo "Terminal guardada."
}

restore_terminal() {
    local dir="$1/terminal" f
    if [ ! -d "$dir" ]; then
        echo "No hay datos de terminal en esta configuración guardada."
        return 0
    fi

    [ -f "$dir/gnome-terminal.dconf" ] && { echo "Restaurando perfiles de GNOME Terminal (colores, fuente, atajos)..."; dconf_load_clean /org/gnome/terminal/legacy/ "$dir/gnome-terminal.dconf"; }

    echo "Restaurando archivos de configuración de la shell..."
    for f in "${TERMINAL_SHELL_FILES[@]}"; do
        [ -f "$dir/$f" ] && cp "$dir/$f" "$HOME/$f"
    done

    if [ -f "$dir/config/starship.toml" ]; then
        echo "Restaurando configuración de Starship..."
        mkdir -p "$HOME/.config"
        cp "$dir/config/starship.toml" "$HOME/.config/starship.toml"
    fi
    [ -f "$dir/.p10k.zsh" ] && cp "$dir/.p10k.zsh" "$HOME/.p10k.zsh"

    echo "Terminal restaurada. Abre una nueva pestaña o ventana para ver los cambios."
}

# =============================================================================
# INTERFAZ GRÁFICA: GUARDAR CONFIGURACIÓN
# =============================================================================

do_save() {
    local selection name timestamp safe_name backup_dir log modules total step pct mod key
    local root_keys_save
    local checklist_args=()

    for key in "${MODULE_KEYS[@]}"; do
        checklist_args+=(TRUE "$key" "${MODULE_LABELS[$key]:-$key}")
    done

    selection=$(zenity --list --title="$APP_NAME - Guardar" \
        --text="¿Qué deseas guardar?" \
        --checklist --width=580 --height=460 \
        --column="Sel" --column="Módulo" --column="Descripción" \
        --print-column=2 --separator="," \
        "${checklist_args[@]}" \
        2>/dev/null)
    [ -z "$selection" ] && return 0

    IFS=',' read -ra modules <<< "$selection"

    # Red y Bluetooth piden contraseña de administrador siempre. Docker solo
    # la necesita como respaldo si /etc/docker/daemon.json no es legible sin
    # privilegios (poco habitual: por defecto sí lo es), así que solo se
    # suma a la lista cuando hace falta de verdad, para no pedirla sin
    # necesidad. Se calcula aquí para reutilizarlo tanto en el aviso de
    # credenciales de abajo como en el preauth posterior.
    root_keys_save="network bluetooth"
    [ -f /etc/docker/daemon.json ] && [ ! -r /etc/docker/daemon.json ] && root_keys_save+=" docker"

    # Un único aviso de seguridad, en vez de una ventana por módulo, que
    # lista solo los módulos con credenciales realmente seleccionados.
    local cred_warn=""
    printf '%s\n' "${modules[@]}" | grep -qx 'network'     && cred_warn+="\n• Red — contraseñas Wi-Fi en texto plano"
    printf '%s\n' "${modules[@]}" | grep -qx 'bluetooth'   && cred_warn+="\n• Bluetooth — claves de emparejamiento de tus dispositivos"
    printf '%s\n' "${modules[@]}" | grep -qx 'docker'      && cred_warn+="\n• Docker — posibles credenciales de registro en base64"
    printf '%s\n' "${modules[@]}" | grep -qx 'thunderbird' && cred_warn+="\n• Thunderbird — contraseñas de tus cuentas de correo"
    printf '%s\n' "${modules[@]}" | grep -qx 'firefox'     && cred_warn+="\n• Firefox — contraseñas guardadas en el navegador"
    printf '%s\n' "${modules[@]}" | grep -qx 'librewolf'   && cred_warn+="\n• LibreWolf — contraseñas guardadas en el navegador"
    if [ -n "$cred_warn" ]; then
        local pw_note=""
        modules_need_root "$root_keys_save" "${modules[@]}" && pw_note="\n\nSe te pedirá la contraseña de administrador (una sola vez)."
        msg_warn "⚠️ Esta copia incluirá datos sensibles:${cred_warn}\n\nLas contraseñas de navegador/correo solo van cifradas si usas una contraseña principal. Protege bien ~/MintSetupBackups.${pw_note}"
    fi

    name=$(zenity --entry --title="$APP_NAME - Guardar" \
        --text="Nombre para esta configuración:" \
        --entry-text="$(hostname)" --width=380 2>/dev/null)
    [ -z "$name" ] && return 0

    timestamp=$(date '+%Y%m%d-%H%M%S')
    # Transcribimos tildes/ñ a ASCII (p. ej. "Configuración" -> "Configuracion")
    # antes de sanear con tr, que al trabajar byte a byte trocearía los
    # caracteres UTF-8 multibyte y dejaría guiones bajos de más. Forzamos
    # LC_ALL=C.UTF-8 (locale compilada en glibc, siempre disponible) porque
    # la transliteración de iconv depende de las tablas de la locale activa:
    # con una locale POSIX/C "a secas" sustituye cada tilde por "?" en vez
    # de por la letra sin tilde. Si iconv no está disponible, recurrimos al
    # saneado simple de antes.
    safe_name=""
    command -v iconv >/dev/null 2>&1 && safe_name=$(printf '%s' "$name" | LC_ALL=C.UTF-8 iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null | tr -c '[:alnum:]_-' '_')
    [ -z "$safe_name" ] && safe_name=$(printf '%s' "$name" | tr -c '[:alnum:]_-' '_')
    backup_dir="$BACKUPS_ROOT/${safe_name}_${timestamp}"
    mkdir -p "$backup_dir"
    log="$backup_dir/save.log"; : > "$log"

    total=${#modules[@]}

    # Se autoriza aquí, ANTES de abrir la barra de progreso, para que el
    # diálogo de PolicyKit no quede tapado detrás de ella y para que no se
    # repita módulo a módulo (ver root_preauth y root_keys_save arriba).
    root_preauth "$root_keys_save" "${modules[@]}" \
        || msg_warn "No se ha concedido la contraseña de administrador.\n\nAlgún módulo puede fallar o volver a pedirla más adelante; el resto se guardará igualmente."

    (
        step=0
        for mod in "${modules[@]}"; do
            step=$((step + 1))
            pct=$(( step * 100 / total ))
            echo "$pct"
            echo "# Guardando: $mod"
            "save_${mod}" "$backup_dir" >> "$log" 2>&1
            # Si el módulo no llegó a guardar ningún archivo (p. ej. Red o
            # Bluetooth sin pkexec, o Aplicaciones de inicio sin carpeta
            # autostart), su carpeta queda vacía. rmdir solo la borra si de
            # verdad está vacía; si tiene contenido, falla en silencio y no
            # pasa nada. Así Restaurar no ofrece luego un módulo sin datos.
            rmdir "$backup_dir/$mod" 2>/dev/null || true
        done
    # --no-cancel: a diferencia de Restaurar, aquí no hay ningún mecanismo
    # que compruebe una cancelación a mitad de módulo, así que el botón
    # Cancelar por defecto de zenity no detendría nada realmente (el
    # guardado seguiría hasta el final en segundo plano); se quita para no
    # prometer algo que el diálogo no puede cumplir.
    ) | zenity --progress --title="$APP_NAME" --text="Guardando configuración..." --auto-close --no-cancel --width=420 2>/dev/null
    root_keepalive_stop

    # Usamos printf %q (en vez de envolver el valor entre comillas dobles a
    # mano) para que el nombre que ha escrito el usuario quede correctamente
    # escapado para bash. manifest.conf se vuelve a leer con "source" cada
    # vez que se abre Restaurar/Comparar/Eliminar (ver pick_backup_dir), así
    # que si el nombre contiene comillas, "$(...)", backticks, etc. y no se
    # escapa bien, ese texto se re-interpretaría como código al sourcearlo
    # en vez de tratarse como texto. %q previene esto pase lo que pase.
    {
        printf 'NAME=%q\n' "$name"
        printf 'DATE=%q\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'MINT_RELEASE=%q\n' "$(lsb_release -ds 2>/dev/null || echo desconocida)"
        printf 'MODULES=%q\n' "$selection"
    } > "$backup_dir/manifest.conf"

    # Varios módulos (Red, Bluetooth...) pueden contener credenciales;
    # restringimos por defecto el acceso a la copia a solo tu usuario.
    chmod -R go-rwx "$backup_dir" 2>/dev/null || true

    # BACKUPS_ROOT vive dentro de $HOME por defecto (o de cualquier carpeta
    # que el usuario haya puesto en MINT_SETUP_BACKUPS_DIR). Si sigue dentro
    # de la carpeta personal, un formateo completo del disco al reinstalar
    # Mint (a diferencia de una reinstalación que conserva /home aparte) se
    # llevaría la copia por delante junto con todo lo demás. Lo avisamos
    # aquí, justo cuando el usuario tiene la copia recién hecha en mente.
    local outside_note=""
    case "$BACKUPS_ROOT" in
        "$HOME"|"$HOME"/*)
            outside_note="\n\n⚠️ Esta copia vive dentro de tu carpeta personal (${BACKUPS_ROOT}). Si en algún momento reinstalas Mint formateando TODO el disco (no solo la partición del sistema, dejando /home aparte), esta copia desaparecerá también.\n\nSácala antes a un USB, disco externo o la nube. Puedes hacerlo desde Configuración avanzada → \"Exportar copia a...\"."
            ;;
    esac

    msg_info "Configuración guardada correctamente en:\n$backup_dir${outside_note}"
}

# =============================================================================
# INTERFAZ GRÁFICA: RESTAURAR CONFIGURACIÓN
# =============================================================================

do_restore() {
    local backup_dir selection modules total pct mod log key
    local progress_fifo zenity_pid
    local checklist_args=()
    local -A mod_bytes
    local total_bytes=0 bytes_done=0 restore_start_ts elapsed eta_txt="" b
    local eta_active=0 eta_remaining=0 eta_tick_ts=0 now_ts

    backup_dir=$(pick_backup_dir "$APP_NAME - Restaurar")
    [ -z "$backup_dir" ] && return 0

    for key in "${MODULE_KEYS[@]}"; do
        [ -d "$backup_dir/$key" ] && checklist_args+=(TRUE "$key" "${MODULE_LABELS[$key]:-$key}")
    done

    if [ ${#checklist_args[@]} -eq 0 ]; then
        msg_error "Esta configuración guardada no contiene datos restaurables."
        return 0
    fi

    selection=$(zenity --list --title="$APP_NAME - Restaurar" \
        --text="¿Qué deseas restaurar?" \
        --checklist --width=580 --height=460 \
        --column="Sel" --column="Módulo" --column="Descripción" \
        --print-column=2 --separator="," \
        "${checklist_args[@]}" \
        2>/dev/null)
    [ -z "$selection" ] && return 0

    IFS=',' read -ra modules <<< "$selection"

    local mods_list="" mod_key
    for mod_key in "${modules[@]}"; do
        mods_list+="${MODULE_SHORT_LABELS[$mod_key]:-$mod_key}, "
    done
    mods_list="${mods_list%, }"

    # Si se restauran TODOS los módulos disponibles en este backup (no solo
    # una selección), avisamos de que puede tardar bastante y de que, pese al
    # preauth/keepalive de root, es posible que se pida la contraseña más de
    # una vez (p. ej. si expira entre módulos largos como Aplicaciones).
    local full_warn=""
    if [ "${#modules[@]}" -eq $(( ${#checklist_args[@]} / 3 )) ]; then
        full_warn="\n\n⚠️ Vas a restaurar TODOS los módulos: puede tardar bastante (Aplicaciones, VS Code o perfiles grandes de navegador/correo son los que más) y es posible que se te pida la contraseña de administrador más de una vez durante el proceso."
    fi

    confirm "Vas a restaurar lo siguiente sobre tu sistema actual:\n\n${mods_list}\n\nEsto sobrescribirá la configuración actual de esos módulos.${full_warn}\n\n¿Deseas continuar?" \
        || return 0

    root_preauth "network bluetooth docker software" "${modules[@]}" \
        || msg_warn "No se ha concedido la contraseña de administrador.\n\nLos módulos que la necesitan (Red, Bluetooth, Docker, Aplicaciones) pueden fallar o volver a pedirla más adelante; el resto se restaurará igualmente."

    total=${#modules[@]}
    log="$backup_dir/restore.log"; : > "$log"

    # % ponderado por tamaño real de cada módulo (ya guardado en el
    # backup, así que es un dato exacto, no una estimación) en vez de por
    # nº de módulos: con datos tan dispares —unos KB de Teclado frente a
    # cientos de MB de Firefox— contar módulos por igual dejaría la barra
    # clavada en el mismo % durante minutos en el módulo grande.
    for mod in "${modules[@]}"; do
        b=$(du -sb "$backup_dir/$mod" 2>/dev/null | cut -f1)
        b=${b:-1}
        if [ "$mod" = "software" ]; then
            # Lo que ocupa este módulo en disco (listas de texto, tarballs
            # pequeños de repositorios) no tiene relación con lo que tarda
            # en restaurarse: casi todo el tiempo es red (apt-get update,
            # instalar paquetes y Flatpaks), no copiar bytes. Sin esto, el
            # % se quedaba clavado en un valor bajo durante todo ese rato.
            local n_apt=0 n_flat=0
            [ -f "$backup_dir/software/apt-manual.list" ] && n_apt=$(wc -l < "$backup_dir/software/apt-manual.list" 2>/dev/null || echo 0)
            [ -f "$backup_dir/software/flatpak.list" ] && n_flat=$(wc -l < "$backup_dir/software/flatpak.list" 2>/dev/null || echo 0)
            b=$(( b + n_apt * 500000 + n_flat * 4000000 ))
        elif [ "$mod" = "vscode" ] && [ -f "$backup_dir/vscode/extensions.list" ]; then
            # Mismo caso que "software": cada extensión se reinstala por
            # separado desde el marketplace (red), no se copia del backup.
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

    # zenity va en segundo plano alimentado por una FIFO. --auto-close no
    # cierra el diálogo de forma fiable en todas las versiones de zenity,
    # así que además lo cerramos nosotros mismos (SIGTERM y, si hace
    # falta, SIGKILL) en cuanto el trabajo termina de verdad, sin depender
    # de que zenity reaccione solo al 100%.
    progress_fifo=$(mktemp -u)
    mkfifo -m 600 "$progress_fifo"
    zenity --progress --title="$APP_NAME" --text="Restaurando configuración..." \
        --auto-close --width=420 < "$progress_fifo" 2>/dev/null &
    zenity_pid=$!

    # Si zenity no llega a arrancar (p. ej. sin sesión gráfica), nadie abre
    # el otro extremo de la tubería y "exec 3>" se quedaría esperando para
    # siempre a un lector que nunca llega. Un pequeño margen y una
    # comprobación de vida evitan ese bloqueo indefinido.
    sleep 0.1
    if ! kill -0 "$zenity_pid" 2>/dev/null; then
        rm -f "$progress_fifo"
        msg_error "No se pudo mostrar la barra de progreso de Restaurar (¿hay una sesión gráfica activa?)."
        return 1
    fi
    exec 3> "$progress_fifo"

    # Los módulos independientes se lanzan TODOS a la vez en vez de uno a
    # uno (antes el tiempo total era la SUMA de cada módulo; ahora es,
    # aproximadamente, el del más lento). VS Code y Docker son la única
    # excepción: comprueban con "command -v" si su programa ya está
    # instalado, y ese programa puede llegar precisamente del módulo
    # Aplicaciones, así que esperan a que este termine (si Aplicaciones no
    # está entre lo seleccionado, no hay nada que esperar y se lanzan
    # también de inmediato).
    local -a phase1_mods=() deferred_mods=() running=()
    local -A mod_pid=() mod_log=()
    local logs_dir; logs_dir=$(mktemp -d)
    local needs_software=0 software_pid="" deferred_launched=0
    local completed=0 cancelled=0 interrupted_list="" status_suffix new_line list

    for mod in "${modules[@]}"; do [ "$mod" = "software" ] && needs_software=1; done
    for mod in "${modules[@]}"; do
        if [ "$needs_software" -eq 1 ] && { [ "$mod" = "vscode" ] || [ "$mod" = "docker" ]; }; then
            deferred_mods+=("$mod")
        else
            phase1_mods+=("$mod")
        fi
    done

    for mod in "${phase1_mods[@]}"; do
        mod_log[$mod]="$logs_dir/$mod.log"
        : > "${mod_log[$mod]}"
        "restore_${mod}" "$backup_dir" >> "${mod_log[$mod]}" 2>&1 &
        mod_pid[$mod]=$!
        [ "$mod" = "software" ] && software_pid=${mod_pid[$mod]}
    done
    running=("${phase1_mods[@]}")

    while [ ${#running[@]} -gt 0 ]; do
        # Si el usuario ya pulsó Cancelar, el proceso de zenity ha
        # terminado por su cuenta: kill -0 deja de verlo con vida. Se mata
        # todo lo que siga en marcha y no se lanza nada más.
        if ! kill -0 "$zenity_pid" 2>/dev/null; then
            cancelled=1
            for mod in "${running[@]}"; do
                # El propio módulo (nuestro usuario) sí se puede matar; si
                # en ese instante está esperando dentro de un pkexec, el
                # proceso elevado (root) puede quedar huérfano y seguir en
                # marcha, algo que se avisa después en el mensaje final.
                kill "${mod_pid[$mod]}" 2>/dev/null
                interrupted_list+="${MODULE_SHORT_LABELS[$mod]:-$mod}, "
            done
            break
        fi

        if [ "$deferred_launched" -eq 0 ] && { [ -z "$software_pid" ] || ! kill -0 "$software_pid" 2>/dev/null; }; then
            deferred_launched=1
            for mod in "${deferred_mods[@]}"; do
                mod_log[$mod]="$logs_dir/$mod.log"
                : > "${mod_log[$mod]}"
                "restore_${mod}" "$backup_dir" >> "${mod_log[$mod]}" 2>&1 &
                mod_pid[$mod]=$!
                running+=("$mod")
            done
        fi

        # La cuenta atrás avanza en cada vuelta (no solo cuando termina un
        # módulo): antes se quedaba clavada en el mismo nº de segundos
        # mientras un módulo largo (p. ej. Aplicaciones) no imprimía nada
        # nuevo durante un rato.
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

        # Con un solo módulo en marcha se muestra el detalle de su log
        # (igual que antes, para que los módulos largos como Aplicaciones
        # no parezcan colgados); con varios a la vez, ya la propia lista de
        # cuáles siguen en marcha deja claro que el proceso avanza.
        if [ ${#still_running[@]} -eq 1 ]; then
            mod="${still_running[0]}"
            new_line=$(tail -n 1 "${mod_log[$mod]}" 2>/dev/null)
            status_suffix="${MODULE_SHORT_LABELS[$mod]:-$mod}: ${new_line:-Restaurando...}"
        elif [ ${#still_running[@]} -gt 1 ]; then
            list=""
            for mod in "${still_running[@]}"; do list+="${MODULE_SHORT_LABELS[$mod]:-$mod}, "; done
            status_suffix="Restaurando a la vez: ${list%, }"
        fi
        [ ${#still_running[@]} -gt 0 ] && echo "# ${pct}%${eta_txt} — ${status_suffix}" >&3 2>/dev/null

        if [ ${#finished_now[@]} -gt 0 ]; then
            for mod in "${finished_now[@]}"; do
                wait "${mod_pid[$mod]}" 2>/dev/null
                cat "${mod_log[$mod]}" >> "$log"
                completed=$((completed + 1))
                bytes_done=$(( bytes_done + ${mod_bytes[$mod]:-1} ))
            done
            # El porcentaje se manda DESPUÉS de terminar cada módulo, no
            # antes: así el 100% (y el consiguiente cierre del diálogo)
            # solo llega cuando el último ya se ha restaurado de verdad.
            pct=$(( bytes_done * 100 / total_bytes ))
            [ "$pct" -gt 100 ] && pct=100
            eta_txt=""
            eta_active=0
            if [ "$completed" -lt "$total" ]; then
                elapsed=$(( $(date +%s) - restore_start_ts ))
                # Con menos de 2s de margen la velocidad medida no es
                # fiable todavía; se recalcula cada vez que termina algún
                # módulo, así que si algo tarda más o menos de lo previsto,
                # el siguiente cálculo ya lo corrige.
                if [ "$elapsed" -ge 2 ]; then
                    # Los módulos pendientes corren en paralelo, no uno
                    # detrás de otro: el tiempo que falta lo marca el más
                    # pesado de ellos (siga corriendo o esté diferido sin
                    # lanzar aún), no la suma de todos. Sumarlos multiplicaba
                    # la estimación por el nº de módulos simultáneos.
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

    exec 3>&- 2>/dev/null
    rm -f "$progress_fifo"
    rm -rf "$logs_dir"
    if kill -0 "$zenity_pid" 2>/dev/null; then
        kill "$zenity_pid" 2>/dev/null
        sleep 0.2
        kill -0 "$zenity_pid" 2>/dev/null && kill -9 "$zenity_pid" 2>/dev/null
    fi
    wait "$zenity_pid" 2>/dev/null
    root_keepalive_stop

    if [ "$cancelled" -eq 1 ]; then
        local mid_note=""
        interrupted_list="${interrupted_list%, }"
        [ -n "$interrupted_list" ] && mid_note=" Estos módulos pudieron quedar a medias: «${interrupted_list}». Si en ese momento se estaba pidiendo la contraseña de administrador, esas operaciones pueden seguir en marcha en segundo plano aunque hayas cerrado la ventana: espera un momento antes de volver a intentarlo."
        msg_warn "Restauración cancelada.\n\nSe completaron ${completed} de ${total} módulo(s).${mid_note}"
        return 0
    fi

    msg_info "Configuración restaurada.\n\nEs posible que necesites cerrar sesión o reiniciar Cinnamon (Ctrl+Alt+Esc) para ver todos los cambios."
}

# =============================================================================
# INTERFAZ GRÁFICA: COMPARAR CONFIGURACIÓN
# =============================================================================

do_compare() {
    local backup_dir report changes old_theme new_theme old_icons new_icons
    local old_bg new_bg old_applets new_applets current_pkgs old_pkgs added removed

    backup_dir=$(pick_backup_dir "$APP_NAME - Comparar")
    [ -z "$backup_dir" ] && return 0

    report=$(mktemp)
    {
        echo "Comparando el sistema actual con:"
        echo "$backup_dir"
        echo ""
        echo "Cambios detectados"
        echo "-------------------"
    } > "$report"
    changes=0

    if [ -f "$backup_dir/appearance/interface.dconf" ]; then
        old_theme=$(grep "^gtk-theme=" "$backup_dir/appearance/interface.dconf" | head -1 | cut -d= -f2-)
        new_theme=$(gsettings get org.cinnamon.desktop.interface gtk-theme 2>/dev/null)
        [ -n "$old_theme" ] && [ "$old_theme" != "$new_theme" ] && { echo "• El tema ha cambiado" >> "$report"; changes=$((changes+1)); }

        old_icons=$(grep "^icon-theme=" "$backup_dir/appearance/interface.dconf" | head -1 | cut -d= -f2-)
        new_icons=$(gsettings get org.cinnamon.desktop.interface icon-theme 2>/dev/null)
        [ -n "$old_icons" ] && [ "$old_icons" != "$new_icons" ] && { echo "• Los iconos han cambiado" >> "$report"; changes=$((changes+1)); }
    fi

    if [ -f "$backup_dir/appearance/background.dconf" ]; then
        old_bg=$(grep "^picture-uri=" "$backup_dir/appearance/background.dconf" | head -1 | cut -d= -f2-)
        new_bg=$(gsettings get org.cinnamon.desktop.background picture-uri 2>/dev/null)
        [ -n "$old_bg" ] && [ "$old_bg" != "$new_bg" ] && { echo "• Nuevo fondo de pantalla" >> "$report"; changes=$((changes+1)); }
    fi

    if [ -f "$backup_dir/desktop/cinnamon.dconf" ]; then
        old_applets=$(grep "^enabled-applets=" "$backup_dir/desktop/cinnamon.dconf" | head -1 | cut -d= -f2-)
        new_applets=$(gsettings get org.cinnamon enabled-applets 2>/dev/null)
        [ -n "$old_applets" ] && [ "$old_applets" != "$new_applets" ] && { echo "• Ha cambiado la lista de applets del panel" >> "$report"; changes=$((changes+1)); }
    fi

    if [ -f "$backup_dir/software/apt-manual.list" ]; then
        current_pkgs=$(mktemp); old_pkgs=$(mktemp)
        apt-mark showmanual 2>/dev/null | sort > "$current_pkgs"
        sort "$backup_dir/software/apt-manual.list" > "$old_pkgs"
        added=$(comm -13 "$old_pkgs" "$current_pkgs" | wc -l)
        removed=$(comm -23 "$old_pkgs" "$current_pkgs" | wc -l)
        [ "$added" -gt 0 ] && { echo "• $added paquete(s) nuevo(s) instalado(s) desde el guardado" >> "$report"; changes=$((changes+1)); }
        [ "$removed" -gt 0 ] && { echo "• $removed paquete(s) eliminado(s) desde el guardado" >> "$report"; changes=$((changes+1)); }
        rm -f "$current_pkgs" "$old_pkgs"
    fi

    [ "$changes" -eq 0 ] && { echo "" >> "$report"; echo "No se han detectado cambios relevantes en las áreas guardadas." >> "$report"; }

    zenity --text-info --title="$APP_NAME - Comparador" --filename="$report" --width=520 --height=420 2>/dev/null
    rm -f "$report"
}

# =============================================================================
# INTERFAZ GRÁFICA: EXPORTAR COPIA A OTRA UBICACIÓN
# =============================================================================

# Copia una configuración ya guardada a la carpeta que elija el usuario (USB,
# disco externo, otra partición, una carpeta sincronizada con la nube...),
# dejando intacta la copia original en BACKUPS_ROOT. Es la vía recomendada
# para que la copia sobreviva a un formateo completo del disco, ya que
# BACKUPS_ROOT vive dentro de $HOME por defecto.
do_export_backup() {
    local src dest_parent dest_dir errfile rc note MODULES cred_mods cred_list export_mods m

    src=$(pick_backup_dir "$APP_NAME - Exportar")
    [ -z "$src" ] && return 0

    dest_parent=$(zenity --file-selection --directory \
        --title="Elige dónde exportar la copia (USB, disco externo...)" \
        2>/dev/null)
    [ -z "$dest_parent" ] && return 0

    dest_dir="$dest_parent/$(basename "$src")"

    if [ -e "$dest_dir" ]; then
        confirm "Ya existe una carpeta con ese nombre en el destino:\n$dest_dir\n\n¿Sobrescribirla?" || return 0
        rm -rf "$dest_dir"
    fi

    errfile=$(mktemp)
    (
        cp -a "$src" "$dest_dir" 2>"$errfile"
        echo $? > "$errfile.rc"
    ) | zenity --progress --pulsate --auto-close \
        --title="$APP_NAME" --text="Exportando copia a:\n$dest_parent" --width=420 2>/dev/null

    rc=$(cat "$errfile.rc" 2>/dev/null)

    if [ "$rc" = "0" ]; then
        note=""
        # La copia original guarda en su manifest qué módulos contiene. Si
        # incluye alguno de los que do_save() ya trata como portador de
        # credenciales (Red, Bluetooth, Thunderbird, Docker), avisamos porque
        # el destino puede no soportar los permisos restringidos (go-rwx) que
        # las protegen — por ejemplo, un USB formateado en FAT32/exFAT no
        # tiene permisos de tipo Unix.
        MODULES=""
        # shellcheck disable=SC1090,SC1091
        source "$src/manifest.conf" 2>/dev/null
        IFS=',' read -ra export_mods <<< "$MODULES"
        cred_mods=()
        for m in "${export_mods[@]}"; do
            case "$m" in
                network)     cred_mods+=("Red") ;;
                bluetooth)   cred_mods+=("Bluetooth") ;;
                thunderbird) cred_mods+=("Thunderbird") ;;
                docker)      cred_mods+=("Docker") ;;
                firefox)     cred_mods+=("Firefox") ;;
                librewolf)   cred_mods+=("LibreWolf") ;;
            esac
        done
        if [ ${#cred_mods[@]} -gt 0 ]; then
            cred_list=$(printf '%s, ' "${cred_mods[@]}")
            cred_list="${cred_list%, }"
            note="\n\n⚠️ Esta copia incluye el módulo ${cred_list} (puede contener contraseñas Wi-Fi, claves de emparejamiento, contraseñas de correo, contraseñas guardadas en el navegador y/o credenciales de registros Docker). En destinos sin permisos de tipo Unix (por ejemplo, un USB en FAT32/exFAT) no se puede restringir el acceso a esos archivos: cualquiera con el USB en la mano podría leerlas."
        fi
        msg_info "Copia exportada correctamente a:\n$dest_dir${note}"
    elif [ -d "$dest_dir" ] && [ -n "$(ls -A "$dest_dir" 2>/dev/null)" ]; then
        msg_warn "La copia se exportó a:\n$dest_dir\n\npero algunos atributos (permisos, propietario, fecha) no se pudieron preservar del todo. Es habitual en unidades FAT32/exFAT, que no soportan permisos de tipo Unix; el contenido debería estar completo de todas formas.\n\nDetalle: $(head -c 300 "$errfile")"
    else
        msg_error "No se pudo exportar la copia. Comprueba que hay espacio suficiente en el destino y que tienes permiso de escritura.\n\nDetalle: $(head -c 300 "$errfile")"
    fi

    rm -f "$errfile" "$errfile.rc"
}

# =============================================================================
# HEADER LUKS: COPIA DE SEGURIDAD Y RESTAURACIÓN DE EMERGENCIA
# El header LUKS contiene la información de cifrado necesaria para
# desbloquear el disco (metadatos + keyslots); si se corrompe, los datos son
# irrecuperables aunque la contraseña sea correcta. No es un módulo del
# checklist de Guardar/Restaurar (no es config. de usuario, sino una copia
# ligada a un disco físico concreto), así que vive en Configuración
# avanzada.
# ⚠️ Requiere permisos de administrador: leer o escribir el dispositivo de
# bloques en crudo solo lo puede hacer root.
# =============================================================================

# Lista, sin necesitar permisos de administrador, los dispositivos con una
# cabecera LUKS detectada (lsblk lee metadatos ya cacheados por udev, no el
# dispositivo en crudo). Salida: "dispositivo|tamaño|UUID" por línea.
luks_detect_devices() {
    local name _ fstype size uuid
    while IFS=' ' read -r name _ fstype size uuid; do
        [ "$fstype" = "crypto_LUKS" ] || continue
        printf '%s|%s|%s\n' "$name" "${size:-?}" "${uuid:-sin-UUID}"
    done < <(lsblk -prno NAME,TYPE,FSTYPE,SIZE,UUID 2>/dev/null)
}

# Selector de dispositivo: lista los detectados por luks_detect_devices más
# una opción para escribir la ruta a mano (por si el disco no se detecta
# solo, p. ej. un contenedor LUKS dentro de un archivo). $1 es el texto de
# aviso sobre la lista. Devuelve la ruta elegida por stdout, o nada si se
# cancela.
luks_pick_device() {
    local warn_text="$1" options=() dev size uuid device n=0

    while IFS='|' read -r dev size uuid; do
        [ -z "$dev" ] && continue
        options+=("$dev" "$size" "$uuid")
        n=$((n + 1))
    done < <(luks_detect_devices)

    if [ "$n" -eq 0 ]; then
        confirm "No se ha detectado ningún dispositivo cifrado con LUKS en este equipo.\n\n¿Quieres indicar la ruta manualmente (p. ej. /dev/sdb1)?" || return 0
        device="Otro..."
    else
        options+=("Otro..." "" "Especificar ruta manualmente")
        device=$(zenity --list --title="$APP_NAME - Header LUKS" \
            --text="$warn_text" --width=580 --height=280 \
            --column="Dispositivo" --column="Tamaño" --column="UUID" \
            "${options[@]}" 2>/dev/null)
        [ -z "$device" ] && return 0
    fi

    if [ "$device" = "Otro..." ]; then
        device=$(zenity --entry --title="$APP_NAME - Header LUKS" \
            --text="Ruta del dispositivo (p. ej. /dev/sdb1):" --width=380 2>/dev/null)
        [ -z "$device" ] && return 0
    fi
    printf '%s' "$device"
}

# Vuelca en un archivo de texto aparte ($2) los metadatos legibles del
# header LUKS de $1 (UUID, cifrado, hash, keyslots) vía «cryptsetup
# luksDump». Es solo documentación de referencia: un volcado en texto no
# contiene el material criptográfico necesario para desbloquear el disco,
# así que no sustituye a la copia binaria ni sirve para restaurar por sí
# solo; ayuda si esa copia (el .img) se corrompe o se pierde.
luks_save_info() {
    local device="$1" outfile="$2" errfile uid gid
    uid=$(id -u); gid=$(id -g)
    errfile=$(mktemp)
    # shellcheck disable=SC2016
    if pkexec bash -c 'cryptsetup luksDump "$1" > "$2" && chown "$3:$4" "$2" && chmod 600 "$2"' \
        _ "$device" "$outfile" "$uid" "$gid" 2>"$errfile"; then
        rm -f "$errfile"
        return 0
    fi
    rm -f "$outfile" "$errfile"
    return 1
}

do_luks_header_backup() {
    local device outfile outfile_info uuid ts label errfile uid gid info_note

    if ! command -v cryptsetup >/dev/null 2>&1; then
        msg_error "cryptsetup no está instalado; no se puede hacer la copia del header.\n\nInstálalo con:\nsudo apt install cryptsetup"
        return 0
    fi
    if ! command -v pkexec >/dev/null 2>&1; then
        msg_error "pkexec no está disponible; no se puede leer el dispositivo (requiere acceso root)."
        return 0
    fi

    device=$(luks_pick_device "Elige el dispositivo cifrado cuyo header quieres respaldar:")
    [ -z "$device" ] && return 0
    # Acepta también un archivo regular (contenedor LUKS sin loop device
    # asociado), no solo dispositivos de bloques: cryptsetup opera igual
    # sobre ambos, y luks_pick_device ya ofrece la ruta manual pensando en
    # ese caso.
    [ -b "$device" ] || [ -f "$device" ] || { msg_error "«$device» no existe, o no es ni un dispositivo de bloques ni un archivo."; return 0; }

    uuid=$(lsblk -no UUID "$device" 2>/dev/null | head -n1)
    ts=$(date '+%Y%m%d-%H%M%S')
    label=$(printf '%s' "$(basename "$device")-${uuid:-sinuuid}" | tr -c '[:alnum:]_-' '_')
    outfile="$LUKS_HEADERS_DIR/luks-header_${label}_${ts}.img"
    outfile_info="${outfile%.img}.txt"

    confirm "Se va a copiar el header LUKS de:\n$device\n\na:\n$outfile\n\n(y un volcado de texto con sus metadatos, por si este archivo se corrompiera)\n\nSe te pedirá la contraseña de administrador. ¿Continuar?" || return 0

    if ! mkdir -p "$LUKS_HEADERS_DIR"; then
        msg_error "No se pudo crear la carpeta para las copias del header LUKS:\n$LUKS_HEADERS_DIR"
        return 0
    fi
    chmod 700 "$LUKS_HEADERS_DIR" 2>/dev/null || true
    uid=$(id -u); gid=$(id -g)
    errfile=$(mktemp)
    # Se hace en un solo pkexec (backup + chown + chmod) para pedir la
    # contraseña una única vez; sin el chown, el archivo quedaría propiedad
    # de root y el usuario normal no podría ni leerlo después. -q fuerza
    # modo no interactivo (por si acaso: no hay terminal detrás de pkexec
    # para responder). Si "$outfile" ya existiera, cryptsetup falla en vez
    # de sobrescribir; lo recoge el "else" de abajo.
    # "$device"/"$outfile"/"$uid"/"$gid" van como argumentos posicionales
    # ($1.."$4"), no interpolados en la cadena.
    # shellcheck disable=SC2016
    if pkexec bash -c 'cryptsetup -q luksHeaderBackup "$1" --header-backup-file "$2" && chown "$3:$4" "$2" && chmod 600 "$2"' \
        _ "$device" "$outfile" "$uid" "$gid" 2>"$errfile"; then
        if luks_save_info "$device" "$outfile_info"; then
            info_note="\n\nTambién se ha guardado un volcado de texto con los metadatos del header (UUID, cifrado, keyslots...) en:\n$outfile_info\n\nEste archivo por sí solo NO permite desbloquear el disco: es solo referencia adicional por si la copia binaria se corrompiera."
        else
            info_note="\n\n⚠️ No se ha podido guardar el volcado de metadatos en texto (la copia binaria de arriba sí se completó y es la que hace falta para restaurar)."
        fi
        msg_info "Copia del header LUKS creada correctamente:\n$outfile${info_note}\n\n⚠️ Guarda también una copia FUERA de este equipo (USB, otro disco...): si el disco entero falla, este archivo se pierde con él. Cópiala con tu gestor de archivos: Configuración avanzada → «Abrir carpeta de configuraciones guardadas» → LuksHeaders (el asistente «Exportar copia a...» no sirve aquí: solo lista configuraciones guardadas, no esta carpeta).\n\n⚠️ Este archivo, junto con tu contraseña de cifrado, permite desbloquear el disco: protégelo igual de bien que la propia contraseña."
    else
        msg_error "No se pudo hacer la copia del header (permisos denegados, cancelado, o «$device» no es un volumen LUKS válido).\n\nDetalle: $(head -c 300 "$errfile")"
        rm -f "$outfile"
    fi
    rm -f "$errfile"
}

do_luks_header_restore() {
    local backup_file device file_uuid dev_uuid note typed errfile

    if ! command -v cryptsetup >/dev/null 2>&1; then
        msg_error "cryptsetup no está instalado; no se puede restaurar el header.\n\nInstálalo con:\nsudo apt install cryptsetup"
        return 0
    fi
    if ! command -v pkexec >/dev/null 2>&1; then
        msg_error "pkexec no está disponible; no se puede escribir en el dispositivo (requiere acceso root)."
        return 0
    fi

    backup_file=$(zenity --file-selection --title="$APP_NAME - Elige la copia del header LUKS" \
        --filename="$LUKS_HEADERS_DIR/" \
        --file-filter="Copias de header LUKS | *.img" \
        --file-filter="Todos los archivos | *" 2>/dev/null)
    [ -z "$backup_file" ] && return 0
    [ -f "$backup_file" ] || { msg_error "El archivo elegido no existe."; return 0; }

    device=$(luks_pick_device "⚠️ Elige el dispositivo DESTINO sobre el que se va a escribir este header.\nElegir el dispositivo equivocado puede volver ilegibles TODOS sus datos.")
    [ -z "$device" ] && return 0
    [ -b "$device" ] || [ -f "$device" ] || { msg_error "«$device» no existe, o no es ni un dispositivo de bloques ni un archivo."; return 0; }

    # luksDump puede leer un archivo de backup de header directamente (sin
    # root, sin --header): sirve tanto para validar que es una copia válida
    # como para comparar su UUID con el del dispositivo destino antes de
    # sobrescribir nada.
    file_uuid=$(cryptsetup luksDump "$backup_file" 2>/dev/null | awk '/^UUID:/{print $2; exit}')
    dev_uuid=$(lsblk -no UUID "$device" 2>/dev/null | head -n1)

    if [ -z "$file_uuid" ]; then
        note="\n\n⚠️ No se ha podido leer «$backup_file» como una copia de header LUKS válida. Comprueba que has elegido el archivo correcto."
    elif [ -z "$dev_uuid" ]; then
        note="\n\n⚠️ No se ha podido leer el UUID actual de $device (puede ser normal si su header está dañado, que es justo el caso que resuelve esta función). No se puede verificar automáticamente que esta copia pertenezca a este disco: continúa solo si estás seguro."
    elif [ "$file_uuid" != "$dev_uuid" ]; then
        note="\n\n🛑 AVISO: el UUID de la copia (${file_uuid}) NO coincide con el de $device (${dev_uuid}). Restaurar el header de OTRO disco puede volver ilegibles TODOS los datos de este de forma permanente. Solo continúa si sabes exactamente lo que haces."
    else
        note="\n\n✅ El UUID de la copia coincide con el de $device."
    fi
    # Aviso adicional si el dispositivo destino está actualmente
    # desbloqueado (tiene un hijo dm-crypt): restaurar el header debajo de
    # un sistema de archivos montado puede dejarlo a medias.
    lsblk -rno PKNAME,TYPE 2>/dev/null | awk -v pk="$(basename "$device")" '$1==pk && $2=="crypt"{f=1} END{exit !f}' \
        && note+="\n\n⚠️ $device parece estar actualmente desbloqueado/en uso. Ciérralo (bloquéalo) antes de restaurar para no dejar el sistema de archivos a medias."

    typed=$(zenity --entry --title="$APP_NAME - Confirmación requerida" \
        --text="Vas a SOBRESCRIBIR el header de cifrado de:\n$device\n\ncon la copia:\n$(basename "$backup_file")${note}\n\nEsto es una medida de EMERGENCIA (header dañado) y no se puede deshacer. Si el header actual todavía funciona, no continúes.\n\nEscribe RESTAURAR para confirmar:" \
        --width=480 2>/dev/null)
    [ "$typed" = "RESTAURAR" ] || { msg_info "Operación cancelada. No se ha modificado nada."; return 0; }

    # -q/--batch-mode: cryptsetup pide confirmación "yes" propia antes de
    # sobrescribir un header existente; sin esto se quedaría esperando una
    # respuesta interactiva que nunca llega (no hay terminal detrás de
    # pkexec) y parecería que el script se ha colgado. Ya hemos pedido nuestra
    # propia confirmación (escribir RESTAURAR) justo arriba.
    errfile=$(mktemp)
    if pkexec cryptsetup -q luksHeaderRestore "$device" --header-backup-file "$backup_file" 2>"$errfile"; then
        msg_info "Header LUKS restaurado en $device.\n\nComprueba que el disco vuelve a desbloquearse con tu contraseña habitual."
    else
        msg_error "No se pudo restaurar el header (permisos denegados, cancelado, o error de cryptsetup).\n\nDetalle: $(head -c 300 "$errfile")"
    fi
    rm -f "$errfile"
}

# =============================================================================
# INTERFAZ GRÁFICA: CONFIGURACIÓN AVANZADA
# =============================================================================

do_advanced() {
    local choice targets t list

    choice=$(zenity --list --title="$APP_NAME - Avanzado" \
        --width=460 --height=380 \
        --column="Op" --column="Acción" --hide-header \
        1 "📂  Abrir carpeta de configuraciones guardadas" \
        2 "📤  Exportar copia a... (USB, disco externo...)" \
        3 "🗑️  Eliminar configuraciones guardadas" \
        4 "🔐  Copia de seguridad del header LUKS" \
        5 "🚑  Restaurar header LUKS (emergencia)" \
        6 "ℹ️  Acerca de $APP_NAME" \
        2>/dev/null)

    case "$choice" in
        1)
            xdg-open "$BACKUPS_ROOT" >/dev/null 2>&1 &
            ;;
        2)
            do_export_backup
            ;;
        3)
            mapfile -t targets < <(pick_backup_dirs_multi "$APP_NAME - Eliminar")
            [ ${#targets[@]} -eq 0 ] && return 0
            list=""
            for t in "${targets[@]}"; do list+="• $(basename "$t")\n"; done
            if confirm "¿Eliminar definitivamente estas ${#targets[@]} configuración(es) guardada(s)?\n\n${list}"; then
                for t in "${targets[@]}"; do rm -rf "$t"; done
                msg_info "${#targets[@]} configuración(es) eliminada(s)."
            fi
            ;;
        4)
            do_luks_header_backup
            ;;
        5)
            do_luks_header_restore
            ;;
        6)
            zenity --info --title="Acerca de $APP_NAME" \
                --text="<b>$APP_NAME</b> v$APP_VERSION\nAutor: Filonux\n\nGuarda y restaura la configuración del entorno de escritorio en Linux Mint (Cinnamon): paneles, applets, apariencia, Nemo, aplicaciones instaladas, aplicaciones de inicio, pantallas, sonido, red, bluetooth, teclado, ratón y touchpad. También guarda la configuración propia de aplicaciones concretas: Firefox, LibreWolf, Thunderbird, LibreOffice, ONLYOFFICE, VS Code, Docker y la terminal.\n\nNo sustituye a Timeshift ni a MintBackup: los complementa.\n• Timeshift recupera el sistema.\n• MintBackup recupera archivos personales.\n• $APP_NAME reconstruye el entorno de trabajo.\n\nLos módulos Red y Bluetooth piden permisos de administrador tanto al guardar como al restaurar, y pueden contener credenciales (contraseñas Wi-Fi, claves de emparejamiento). El módulo Docker los pide solo para la parte del daemon y el grupo docker.\n\nConfiguración avanzada añade copia de seguridad y restauración de emergencia del header LUKS de discos cifrados (también requiere administrador).\n\nLas configuraciones guardadas se almacenan en:\n$BACKUPS_ROOT" \
                --width=460 2>/dev/null
            ;;
    esac
}

# =============================================================================
# PROGRAMA PRINCIPAL
# =============================================================================

check_dependencies

main_menu() {
    local choice
    while true; do
        choice=$(zenity --list \
            --title="$APP_NAME" \
            --text="<b>$APP_NAME</b>\n¿Qué deseas hacer?" \
            --width=440 --height=340 \
            --column="Op" --column="Acción" --hide-header \
            1 "💾  Guardar configuración" \
            2 "♻️  Restaurar configuración" \
            3 "🔍  Comparar configuración" \
            4 "⚙️  Configuración avanzada" \
            5 "🚪  Salir" \
            2>/dev/null)

        case "$choice" in
            1) do_save ;;
            2) do_restore ;;
            3) do_compare ;;
            4) do_advanced ;;
            5|"") exit 0 ;;
        esac
    done
}

main_menu
