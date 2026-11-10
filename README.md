# Antigravity Manager (`antigravity-manager.sh`)

Script en Bash para consultar el estado, actualizar, respaldar y restaurar todo el ecosistema de **Google Antigravity** en Linux protegiendo tus conversaciones y configuraciones locales.

## Componentes gestionados

| Componente | Descripción | Ruta de instalación | Método de actualización |
| :--- | :--- | :--- | :--- |
| **`desktop`** | Antigravity (app de agentes) | `/opt/antigravity` | `sudo update-antigravity` (helper LinuxCapable) |
| **`ide`** | Antigravity IDE (fork VS Code) | `/opt/antigravity-ide` | `sudo update-antigravity-ide` (helper LinuxCapable) |
| **`cli`** | Antigravity CLI (`agy`) | `~/.local/bin/agy` | Instalador oficial (`https://antigravity.google/cli/install.sh`), que verifica el SHA-512 del binario |

---

## Características principales

- **Protección de conversaciones y datos**: Desktop, IDE y CLI comparten `~/.gemini`. Antes de actualizar o restaurar, el script detecta si hay procesos abiertos de Antigravity y solicita cerrarlos para evitar corrupción en las bases de datos.
- **Copias de seguridad incrementales**: Antes de cada actualización se realiza un backup incremental con `rsync --link-dest` (usando hard links para no duplicar espacio en disco) de:
  - `~/.gemini`
  - `~/.config/Antigravity`
  - `~/.config/Antigravity IDE`
  - `~/.antigravity-ide`
  *(Excluyendo cachés, binarios descargables, logs y perfiles temporales de navegador).*
- **Rotación automática**: Conserva por defecto las últimas 5 copias de seguridad y elimina las más antiguas automáticamente. La copia `pre-restore` que se crea al restaurar no rota, para no borrar la copia que se está restaurando.
- **Comparación de versiones con build**: Las versiones disponibles se leen como `X.Y.Z-build`. Como los helpers y `agy --version` solo informan de `X.Y.Z`, el script recuerda el build que instaló en `~/.local/state/antigravity-manager/` y solo lo compara cuando lo conoce. Si no se puede consultar la versión disponible, no se actualiza salvo con `--force`. (Los helpers de LinuxCapable no reinstalan si `X.Y.Z` no cambia, así que un build nuevo con la misma `X.Y.Z` puede requerir `--force`).
- **Actualización segura del CLI (`agy`)**: Aparta el binario previo como `~/.local/bin/agy.prev` antes de invocar el instalador oficial y lo restaura si la instalación falla o se interrumpe (Ctrl-C).
- **Instalador del CLI comprobado antes de ejecutarlo**: `install.sh` no publica firma ni hash, así que se descarga a un fichero, se comprueba que no está vacío y que es un script de shell, y se muestra su SHA-256 en el log. Si defines `ANTIGRAVITY_CLI_INSTALLER_SHA256`, solo se ejecuta si coincide (tras revisar el script, fija su hash con `curl -fsSL https://antigravity.google/cli/install.sh | sha256sum`).

---

## Requisitos

- Ejecutar el script **como tu usuario normal** (sin `sudo`; el propio script solicitará `sudo` únicamente cuando necesite actualizar `desktop`, `ide` o limpiar archivos en `/opt`).
- Comandos disponibles en el sistema: `curl`, `sed`, `grep`, `sort`, `pgrep`, `timeout`, `rsync` (y `sha256sum` para actualizar el CLI).
- Para `desktop` e `ide`: contar con los helpers `/usr/local/bin/update-antigravity` y `/usr/local/bin/update-antigravity-ide`.

---

## Uso

```bash
./antigravity-manager.sh [comando] [argumentos] [opciones]
```

Si se ejecuta sin argumentos en una terminal interactiva, abre el **menú interactivo**. Si no hay terminal interactiva, ejecuta `status`.

### Comandos disponibles

| Comando | Descripción |
| :--- | :--- |
| `menu` | Abre el menú interactivo para actualizar todos los componentes o elegir varios (ej. `2 4`), gestionar backups o limpiar archivos temporales. |
| `status` | Muestra una tabla comparando las versiones instaladas frente a las últimas versiones disponibles. |
| `update [componente...]` | Actualiza los componentes indicados (`desktop`, `ide`, `cli` o `all`). Si no se especifica ninguno, actualiza todos los que tengan nueva versión. |
| `backup` | Cierra Antigravity (si está abierto) y crea una copia de seguridad manual de conversaciones y ajustes. |
| `backups` | Lista las copias de seguridad disponibles y su tamaño incremental. |
| `restore [copia]` | Restaura una copia de seguridad (creando antes un backup `pre-restore` del estado actual). Si no se indica nombre, permite elegirla interactivamente. |
| `clean` | Busca y elimina restos de instalaciones o actualizaciones previas fallidas sin tocar nunca los directorios activos. Solo considera entradas propiedad de `root` (y en `/var/tmp`, solo directorios), nunca enlaces simbólicos; las copias `*.partial` propias se borran sin `sudo`. |
| `help` | Muestra la ayuda rápida del script. |

### Opciones

- `-f`, `--force`: Fuerza la reinstalación del componente aunque ya esté en la última versión.
- `-y`, `--yes`: Modo no interactivo; acepta confirmaciones automáticamente (cierra las aplicaciones abiertas sin preguntar).
- `--no-backup`: Omite la copia de seguridad previa al actualizar.
- `-h`, `--help`: Muestra la ayuda y sale.

---

## Ejemplos rápidos

```bash
# Abrir el menú interactivo
./antigravity-manager.sh

# Ver versiones instaladas vs. disponibles
./antigravity-manager.sh status

# Actualizar únicamente el CLI (agy)
./antigravity-manager.sh update cli

# Actualizar todo sin pedir confirmación
./antigravity-manager.sh update -y

# Forzar la reinstalación del CLI aunque figure al día
./antigravity-manager.sh update cli --force

# Crear una copia de seguridad manual
./antigravity-manager.sh backup

# Restaurar una copia de seguridad anterior
./antigravity-manager.sh restore
```

---

## Variables de entorno

Puedes personalizar el comportamiento de las copias de seguridad exportando estas variables antes de ejecutar el script:

| Variable | Valor por defecto | Descripción |
| :--- | :--- | :--- |
| `ANTIGRAVITY_BACKUP_DIR` | `~/antigravity/backups` | Directorio donde se guardan las copias de seguridad. |
| `ANTIGRAVITY_BACKUP_KEEP` | `5` | Número máximo de copias de seguridad que se conservan. Debe ser un entero mayor o igual que 1; si no, el script se detiene. |
| `ANTIGRAVITY_CLI_INSTALLER_SHA256` | *(vacío)* | SHA-256 esperado de `install.sh`. Si se define y no coincide, el CLI no se actualiza. |

