<img src="assets/icon.png" width="140" height="140">

# Mint-Setup

Guarda cómo tienes configurado tu Cinnamon y tus apps,  
y recupéralo entero la próxima vez que instales Mint desde cero.

[![Bash 4+](https://img.shields.io/badge/bash-%3E%3D4.0-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/) [![Linux Mint 22.3 Cinnamon](https://img.shields.io/badge/Linux%20Mint-22.3%20Cinnamon-87CF3E?logo=linuxmint&logoColor=white)](https://linuxmint.com/) [![Licencia GPLv3](https://img.shields.io/badge/licencia-GPLv3-blue)](LICENSE)

---

## El problema que resuelve

Después de reinstalar o formatear Mint, dejar el escritorio como estaba puede llevarte horas: recolocar paneles y applets, reinstalar cada aplicación una a una, volver a configurar Firefox, VS Code, Docker... Mint-Setup no copia el sistema completo —para eso ya tienes Timeshift— ni tus archivos personales —para eso está MintBackup—. En vez de eso, **describe cómo está configurado tu entorno** (con dconf, gsettings, apt-mark, flatpak, listas de extensiones...) y, sobre una instalación nueva, vuelve a aplicar exactamente esa configuración.


<img width="437" height="361" alt="1 mintsetup-menu-inicio" src="https://github.com/user-attachments/assets/62b687b7-edf5-4d65-9cf8-5ccf3e76f672" />
<img width="581" height="499" alt="2 mintsetup-guardar" src="https://github.com/user-attachments/assets/b2bebefe-0357-45c9-85da-bd1904566fa3" />
<img width="522" height="385" alt="3 mintsetup-restaurar" src="https://github.com/user-attachments/assets/b467e3c2-1671-44ae-8906-ef5522b57100" />


| Herramienta | Qué recupera |
|---|---|
| Timeshift | El sistema |
| MintBackup | Tus archivos personales |
| **Mint-Setup** | Tu entorno de trabajo: escritorio, apariencia, aplicaciones y su configuración |

Cada módulo es independiente. Tanto al guardar como al restaurar eliges, con un checklist, exactamente cuáles tocar — nunca es todo o nada.

## Qué hace

- **Guarda por módulos**: 20 módulos independientes, desde la disposición de tus paneles de Cinnamon hasta los marcadores de Firefox. Marcas solo los que quieres y el resto del sistema no se toca.
- **Restaura solo lo que esa copia tiene**: el checklist de restaurar muestra únicamente los módulos presentes en la configuración elegida, con una barra de progreso ponderada por tamaño real y una estimación del tiempo restante.
- **Compara tu sistema actual con una copia guardada**: tema, iconos, fondo de pantalla, applets del panel y paquetes APT instalados o eliminados desde entonces.
- **Avisa antes de guardar credenciales**: si marcas Red, Bluetooth, Docker, Firefox, LibreWolf o Thunderbird, te dice exactamente qué contraseñas o claves va a incluir la copia antes de continuar.
- **Pide permisos de administrador solo cuando hace falta**, una vez por operación en vez de módulo a módulo, y se niega a ejecutarse él mismo como root.
- **Incluye una red de seguridad para discos cifrados**: copia y restauración de emergencia del header LUKS, con verificación de UUID antes de sobrescribir nada.

## Módulos disponibles

| Módulo | Qué guarda |
|---|---|
| Escritorio Cinnamon | Paneles y barra de tareas, applets (incluido el icono del menú), desklets, extensiones, workspaces |
| Apariencia | Tema de Cinnamon y de ventanas, iconos, cursor, fuentes, modo claro/oscuro, fondo de pantalla, protector de pantalla |
| Nemo | Accesos directos de escritorio y menú, marcadores, scripts, acciones, preferencias |
| Aplicaciones | Paquetes APT instalados a mano, aplicaciones y repositorios Flatpak, repositorios APT adicionales |
| Aplicaciones de inicio | Programas que se lanzan automáticamente al iniciar sesión |
| Pantallas | Resolución y disposición de monitores |
| Sonido | Tema de sonido, dispositivo de salida y entrada predeterminado |
| Red ⚠️ admin | Conexiones NetworkManager — incluye contraseñas Wi-Fi en texto plano |
| Bluetooth ⚠️ admin | Dispositivos emparejados |
| Teclado | Distribución, opciones XKB, repetición y retardo |
| Ratón | Velocidad, aceleración, botones |
| Touchpad | Toque para pulsar, scroll, gestos |
| Firefox ⚠️ | Perfil completo: marcadores, extensiones, preferencias, contraseñas guardadas |
| LibreWolf ⚠️ | Igual que Firefox |
| Thunderbird ⚠️ | Cuentas, filtros, libreta de direcciones, extensiones, contraseñas de correo |
| LibreOffice | Plantillas, autocorrección, extensiones, barras de herramientas |
| ONLYOFFICE | Configuración de usuario y plugins de Desktop Editors |
| VS Code | Extensiones instaladas, settings.json, keybindings, snippets, perfiles |
| Docker ⚠️ parcial | Configuración de usuario y del daemon, pertenencia al grupo docker |
| Terminal | Perfiles de GNOME Terminal, .bashrc/.zshrc y otros archivos de shell |

⚠️ marca los módulos que piden contraseña de administrador y/o pueden contener credenciales. Mint-Setup avisa de esto antes de guardarlos (ver [Privacidad y seguridad](#privacidad-y-seguridad)).

## Instalación

No hace falta compilar nada ni instalar dependencias aparte: `zenity`, `dconf`, `gsettings`, `apt-get` y `tar` —las únicas obligatorias— ya vienen de fábrica en cualquier Linux Mint Cinnamon.

```bash
git clone https://github.com/filonux/mint-setup.git
cd mint-setup/script
chmod +x mint-setup.sh
./mint-setup.sh
```

También puedes ejecutarlo con doble clic desde Nemo, dándole antes permiso de ejecución desde Propiedades → Permisos.

## Comandos

| Comando | Qué hace |
|---|---|
| `./mint-setup.sh` | Abre el menú principal: Guardar, Restaurar, Comparar, Configuración avanzada |
| `./mint-setup.sh --version` | Muestra la versión instalada y termina |
| `MINT_SETUP_BACKUPS_DIR=/ruta ./mint-setup.sh` | Guarda y busca las copias en `/ruta` en vez de en `~/MintSetupBackups` |

## Uso

**💾 Antes de reinstalar o formatear**, abre Mint-Setup, elige **Guardar configuración**, marca los módulos que quieras y ponle un nombre a la copia.

**♻️ Después de la instalación nueva**, abre Mint-Setup, elige **Restaurar configuración**, selecciona la copia y marca qué restaurar de lo que contiene. Puede que necesites cerrar sesión o reiniciar Cinnamon (<kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>Esc</kbd>) para ver todos los cambios.

**🔍 En cualquier momento**, usa **Comparar configuración** para ver qué ha cambiado en tu sistema desde una copia guardada.

**⚙️ Configuración avanzada** reúne lo que no encaja en guardar/restaurar:

- 📂 Abrir la carpeta de configuraciones guardadas
- 📤 Exportar una copia a otra ubicación (USB, disco externo, la nube...)
- 🗑️ Eliminar configuraciones guardadas
- 🔐 Copia de seguridad del header LUKS de un disco cifrado
- 🚑 Restaurar el header LUKS en caso de emergencia (header dañado)
- ℹ️ Acerca de Mint-Setup

## Privacidad y seguridad

- El script nunca se ejecuta como root: si lo lanzas con `sudo`, se niega a continuar y te explica por qué. Los módulos que sí necesitan permisos de administrador (Red, Bluetooth y la parte del daemon de Docker) los piden puntualmente con `pkexec`, una sola vez por operación.
- Las copias se guardan con permisos restringidos (`chmod 700`, sin acceso para grupo ni otros) porque varios módulos pueden contener contraseñas Wi-Fi en texto plano, claves de emparejamiento Bluetooth o contraseñas guardadas en el navegador y el correo (cifradas solo si usas una contraseña principal en Firefox/LibreWolf, o una equivalente en Thunderbird).
- Por defecto, las copias viven dentro de `~/MintSetupBackups`. Si vas a formatear el disco entero (no solo la partición del sistema), sácalas antes a un USB o disco externo con **Exportar copia a...**: al vivir dentro de tu carpeta personal, un formateo completo se las llevaría por delante.
- Restaurar el header LUKS es una operación de emergencia pensada para un header dañado, y no se puede deshacer: el asistente compara el UUID de la copia con el del disco de destino y pide escribir una palabra de confirmación antes de sobrescribir nada.
- Durante el proceso de restauración completa de todos los módulos se requiere la contraseña en la terminal para dar permiso y que la restauración continúe. El tiempo de restauración completa variará según la cantidad de módulos a restaurar, los módulos que requieren permisos pedirán permiso con contraseña para continuar.

## Compatibilidad

Escrito y probado en **Linux Mint 22.3 Cinnamon**. Los módulos de Escritorio, Apariencia y Nemo dependen de los esquemas de dconf propios de Cinnamon y de Nemo como gestor de archivos, así que no tendrán efecto en otro entorno de escritorio (XFCE, MATE, GNOME...) ni en otra distribución. El resto de módulos —Aplicaciones, navegadores, VS Code, Docker, Terminal...— no dependen de Cinnamon y es probable que funcionen igual en cualquier base Ubuntu/Debian, aunque de momento solo está verificado en Mint/Cinnamon.

**Dependencias obligatorias** (el script no arranca si falta alguna): `zenity`, `dconf`, `gsettings`, `apt-get`, `tar`.

**Dependencias opcionales** — nada de esto es obligatorio; si falta alguna, el paso que la usa se omite o avisa, sin interrumpir el resto del guardado o restaurado:

| Herramienta | Para qué |
|---|---|
| `flatpak` | Guardar y restaurar apps y repositorios Flatpak |
| `pkexec` | Todas las operaciones que necesitan administrador (Red, Bluetooth, Docker, repositorios APT, header LUKS...) |
| `pactl` | Guardar y restaurar el dispositivo de sonido predeterminado |
| `iconv` | Nombres de copia sin tildes/ñ de forma más fiable |
| `gio` | Marcar los accesos directos del Escritorio como de confianza al restaurar (si no, Nemo bloquea su ejecución) |
| `fc-cache` | Refrescar la caché de fuentes después de restaurarlas |
| `xdg-user-dir` | Localizar tus carpetas de usuario (Escritorio, Imágenes...) sea cual sea el idioma del sistema |
| `pgrep` | Comprobar que Firefox, Thunderbird, LibreOffice... están cerrados antes de tocar su perfil |
| `code` | Guardar y restaurar la lista de extensiones de VS Code |
| `cryptsetup` | Copia de seguridad y restauración de emergencia del header LUKS |

## ¿Quieres un icono y un acceso en el menú?

Mint-Setup es un script normal: se ejecuta desde terminal como cualquier otro. Si prefieres tener un icono en el menú de Cinnamon o en el escritorio, usa [**Scriptya**](https://github.com/filonux/Scriptya), otra herramienta del mismo autor: convierte cualquier script en una app independiente con su propio icono, integrada en el menú de Cinnamon y/o en el escritorio, y de paso deja lanzarlo, actualizarlo o desinstalarlo desde un único menú.

## Sobre el idioma

Mint-Setup está en español: menús, diálogos, mensajes y comentarios del código. No hay versión en inglés todavía.

**Mini roadmap**, sujeto a que haya interés real:

- [ ] Traducción completa de menús, diálogos y mensajes al inglés
- [ ] Forma de elegir idioma (detección del sistema o una opción explícita)
- [ ] README en inglés
- [ ] Adaptarlo a otras versiones de Linux y empaquetarlo en un .deb

Si te interesaría usarlo en inglés, dilo en un issue — es la señal que necesito para priorizarlo.

## Contribuir

Los issues y pull requests son bienvenidos — hay plantillas en `.github/` para reportar errores o proponer mejoras. La guía completa está en [CONTRIBUTING.md](.github/CONTRIBUTING.md).

## Reportar una vulnerabilidad

Si encuentras un problema de seguridad (por ejemplo, algo que pudiera exponer las credenciales que guardan los módulos de Red, Bluetooth o los navegadores), sigue el proceso descrito en [SECURITY.md](.github/SECURITY.md) en vez de abrir un issue público.

## Licencia

GPLv3. Consulta el archivo [LICENSE](LICENSE).

---

Hecho por **[Filonux](https://github.com/filonux)**.
