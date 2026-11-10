#!/usr/bin/env bash
#
# antigravity-manager.sh — Descarga, instala y actualiza todo lo relacionado con
# Google Antigravity en este equipo, protegiendo las conversaciones:
#
#   desktop  Antigravity (app de agentes)   /opt/antigravity       -> sudo update-antigravity
#   ide      Antigravity IDE (fork VS Code) /opt/antigravity-ide   -> sudo update-antigravity-ide
#   cli      Antigravity CLI (agy)          ~/.local/bin/agy       -> instalador oficial
#
# Desktop e IDE se gestionan con los helpers de LinuxCapable ya instalados en
# /usr/local/bin (descargan el tarball de https://antigravity.google/download,
# validan el archivo, hacen copia de seguridad y revierten si algo falla).
# El CLI se actualiza con el instalador oficial (verifica SHA-512 del binario).
# El instalador (install.sh) se descarga a un fichero, se comprueba que es un
# script y se registra su SHA-256 antes de ejecutarlo; si se define
# ANTIGRAVITY_CLI_INSTALLER_SHA256, se exige que coincida.
#
# Las tres apps comparten conversaciones y artefactos en ~/.gemini, y las
# versiones nuevas migran datos al primer arranque. Por eso, antes de actualizar:
#   1. se cierran Desktop, IDE y agy (escribir mientras se copia corrompe las BD),
#   2. se hace una copia de seguridad incremental de los datos de usuario
#      (~/.gemini, ~/.config/Antigravity*, ~/.antigravity-ide) en BACKUP_DIR.
#
# Uso:
#   antigravity-manager.sh                          Menú interactivo (o status si no hay terminal)
#   antigravity-manager.sh menu                     Menú: actualizar todos o los que elijas
#   antigravity-manager.sh status                   Versiones instaladas vs. disponibles
#   antigravity-manager.sh update [componente...]   Actualiza (por defecto: todos)
#   antigravity-manager.sh backup                   Copia de seguridad de conversaciones y ajustes
#   antigravity-manager.sh backups                  Lista las copias de seguridad
#   antigravity-manager.sh restore [copia]          Restaura una copia (pregunta cuál si no se indica)
#   antigravity-manager.sh clean                    Borra restos de actualizaciones previas
#   antigravity-manager.sh help
#
# Opciones:
#   -f, --force      Reinstala aunque ya esté en la última versión
#   -y, --yes        No preguntar (cierra las apps abiertas sin confirmar)
#   --no-backup      No hacer copia de seguridad antes de actualizar
#
# Variables de entorno:
#   ANTIGRAVITY_BACKUP_DIR    Carpeta de copias (por defecto ~/antigravity/backups)
#   ANTIGRAVITY_BACKUP_KEEP   Copias que se conservan (por defecto 5; entero >= 1)
#   ANTIGRAVITY_CLI_INSTALLER_SHA256  SHA-256 esperado de install.sh (opcional)
#
set -euo pipefail

DOWNLOAD_PAGE="https://antigravity.google/download"
CLI_INSTALLER_URL="https://antigravity.google/cli/install.sh"
CLI_MANIFEST_BASE="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests"

DESKTOP_ROOT="/opt/antigravity"
DESKTOP_HELPER="/usr/local/bin/update-antigravity"
DESKTOP_LINK="/usr/local/bin/antigravity"

IDE_ROOT="/opt/antigravity-ide"
IDE_HELPER="/usr/local/bin/update-antigravity-ide"
IDE_LINK="/usr/local/bin/antigravity-ide"

CLI_BIN="$HOME/.local/bin/agy"

BACKUP_DIR="${ANTIGRAVITY_BACKUP_DIR:-$HOME/antigravity/backups}"
BACKUP_KEEP="${ANTIGRAVITY_BACKUP_KEEP:-5}"
CLI_INSTALLER_SHA256="${ANTIGRAVITY_CLI_INSTALLER_SHA256:-}"
# Versión completa (X.Y.Z-build) instalada por este script: los helpers y agy solo
# informan de X.Y.Z, así que el build se recuerda aquí para poder compararlo.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/antigravity-manager"
# Datos de usuario (relativos a $HOME) que contienen conversaciones, artefactos y ajustes.
DATA_PATHS=(".gemini" ".config/Antigravity" ".config/Antigravity IDE" ".antigravity-ide")

# Procesos de Antigravity que escriben en los datos de usuario.
PROCESS_REGEX="^(/opt/antigravity(-ide)?/|$HOME/\.gemini/antigravity[^/]*/bin/|([^ ]*/)?agy( |$))"

ALL_COMPONENTS=(desktop ide cli)
# Versión disponible consultada por needs_update para cada componente.
declare -A REMOTE_VERSIONS=()
FORCE=no
ASSUME_YES=no
DO_BACKUP=yes

# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
	C_OK=$'\e[32m' C_WARN=$'\e[33m' C_ERR=$'\e[31m' C_BOLD=$'\e[1m' C_OFF=$'\e[0m'
else
	C_OK='' C_WARN='' C_ERR='' C_BOLD='' C_OFF=''
fi

info() { printf '%s==>%s %s\n' "$C_BOLD" "$C_OFF" "$*"; }
ok() { printf '%s✓%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s!%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die() {
	printf '%s✗%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2
	exit 1
}

usage() { sed -n '3,44p' "$0" | sed 's/^# \{0,1\}//'; }

confirm() {
	[ "$ASSUME_YES" = yes ] && return 0
	[ -t 0 ] || return 1
	local answer
	read -r -p "$1 [s/N] " answer
	[[ "$answer" =~ ^[sSyY]$ ]]
}

# Devuelve 0 si $2 es estrictamente mayor que $1 (comparación de versiones).
version_gt() {
	[ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$2" ]
}

# Como version_gt, pero con versiones X.Y.Z[-build]: el build solo se compara si
# ambas lo tienen (la instalada solo lo conoce si la instaló este script).
version_newer() {
	local installed=$1 available=$2
	if [[ "$installed" != *-* || "$available" != *-* ]]; then
		installed=${installed%%-*}
		available=${available%%-*}
	fi
	version_gt "$installed" "$available"
}

case "$(uname -m)" in
x86_64 | amd64) WEB_PLATFORM="linux-x64" CLI_PLATFORM="linux_amd64" ;;
aarch64 | arm64) WEB_PLATFORM="linux-arm" CLI_PLATFORM="linux_arm64" ;;
*) die "Arquitectura no soportada: $(uname -m)" ;;
esac
if ldd /bin/ls 2>&1 | grep -q musl; then
	CLI_PLATFORM="${CLI_PLATFORM}_musl"
fi

# ---------------------------------------------------------------------------
# Versiones remotas
# ---------------------------------------------------------------------------
DOWNLOAD_HTML=''
fetch_download_page() {
	if [ -z "$DOWNLOAD_HTML" ]; then
		DOWNLOAD_HTML=$(curl -fsSL --proto '=https' --compressed --retry 2 -m 30 "$DOWNLOAD_PAGE") ||
			die "No se pudo descargar $DOWNLOAD_PAGE"
	fi
}

remote_version() {
	local url_regex
	case "$1" in
	desktop)
		url_regex="https://storage\.googleapis\.com/antigravity-public/antigravity-hub/[0-9]+\.[0-9]+\.[0-9]+-[0-9]+/${WEB_PLATFORM}/Antigravity\.tar\.gz"
		;;
	ide)
		url_regex="https://edgedl\.me\.gvt1\.com/edgedl/release2/j0qc3/antigravity/stable/[0-9]+\.[0-9]+\.[0-9]+-[0-9]+/${WEB_PLATFORM}/Antigravity%20IDE\.tar\.gz"
		;;
	cli)
		# El manifiesto da X.Y.Z en "version" y el build en la URL (.../X.Y.Z-build/...).
		local manifest version build
		manifest=$(curl -fsSL --proto '=https' --retry 2 -m 30 "$CLI_MANIFEST_BASE/$CLI_PLATFORM.json" 2>/dev/null) || return 0
		version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' <<<"$manifest" | head -n1)
		[ -n "$version" ] || return 0
		build=$(grep -oE "/${version//./\\.}-[0-9]+/" <<<"$manifest" | head -n1 | tr -d /) || true
		echo "${build:-$version}"
		return 0
		;;
	esac
	fetch_download_page
	{ grep -oE "$url_regex" <<<"$DOWNLOAD_HTML" || true; } | head -n1 |
		sed -E 's#.*/([0-9]+\.[0-9]+\.[0-9]+-[0-9]+)/.*#\1#'
}

# ---------------------------------------------------------------------------
# Versiones locales
# ---------------------------------------------------------------------------
local_version() {
	local version recorded
	version=$(
		case "$1" in
		desktop) [ -x "$DESKTOP_LINK" ] && cat "$DESKTOP_ROOT/.linuxcapable-version" 2>/dev/null ;;
		ide) [ -x "$IDE_LINK" ] && cat "$IDE_ROOT/.linuxcapable-version" 2>/dev/null ;;
		cli) [ -x "$CLI_BIN" ] && timeout 15 "$CLI_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
		esac
	) || true
	[ -n "$version" ] || return 0
	# Añade el build recordado si corresponde a la misma X.Y.Z que hay instalada.
	recorded=$(cat "$STATE_DIR/$1.version" 2>/dev/null) || true
	if [[ "$recorded" == "$version"-* ]]; then
		echo "$recorded"
	else
		echo "$version"
	fi
}

# Recuerda la versión completa (X.Y.Z-build) si es la que ha quedado instalada.
record_version() {
	local component=$1 available=$2 installed
	[ -n "$available" ] || return 0
	installed=$(local_version "$component")
	[ "${installed%%-*}" = "${available%%-*}" ] || return 0
	mkdir -p "$STATE_DIR" && printf '%s\n' "$available" >"$STATE_DIR/$component.version" || true
}

component_label() {
	case "$1" in
	desktop) echo "Antigravity (desktop)" ;;
	ide) echo "Antigravity IDE" ;;
	cli) echo "Antigravity CLI (agy)" ;;
	esac
}

# ---------------------------------------------------------------------------
# Procesos abiertos
# ---------------------------------------------------------------------------
antigravity_pids() {
	pgrep -f -- "$PROCESS_REGEX" || true
}

# Cierra Desktop, IDE y agy si están abiertos: comparten ~/.gemini y, si siguen
# escribiendo mientras se copia o se migra, las conversaciones pueden perderse.
ensure_closed() {
	local pids
	pids=$(antigravity_pids)
	[ -n "$pids" ] || return 0

	warn "Antigravity está abierto. Hay que cerrarlo para no perder conversaciones:"
	# shellcheck disable=SC2086
	ps -o pid=,args= -p ${pids//$'\n'/,} | cut -c1-110 | sed 's/^/    /' >&2
	confirm "¿Cerrar estos procesos ahora? (guarda tu trabajo antes)" || return 1

	# shellcheck disable=SC2086
	kill -TERM $pids 2>/dev/null || true
	for _ in $(seq 1 30); do
		[ -n "$(antigravity_pids)" ] || {
			ok "Antigravity cerrado"
			return 0
		}
		sleep 1
	done
	warn "Algunos procesos siguen abiertos tras 30 s; ciérralos a mano y vuelve a intentarlo."
	return 1
}

# ---------------------------------------------------------------------------
# Copias de seguridad
# ---------------------------------------------------------------------------
# Exclusiones por raíz: cachés, binarios descargables, logs y perfiles de
# navegador, que se regeneran solos y no contienen conversaciones.
backup_filters() {
	case "$1" in
	.gemini)
		printf '%s\n' \
			--exclude=/antigravity-browser-profile/ --exclude=/antigravity-backup/ \
			--exclude=/bin/ --exclude=/cache/ --exclude=/logs/ \
			--exclude='/antigravity*/bin/' --exclude='/antigravity*/lib/' \
			--exclude='/antigravity*/log/' --exclude='/antigravity*/crashes/'
		;;
	.config/*)
		printf '%s\n' \
			--exclude=/Cache/ '--exclude=/Code Cache/' --exclude=/GPUCache/ --exclude=/CachedData/ \
			--exclude=/DawnGraphiteCache/ --exclude=/DawnWebGPUCache/ --exclude=/GPUPersistentCache/ \
			--exclude=/Crashpad/ --exclude=/logs/ --exclude='/Service Worker/CacheStorage/' \
			--exclude=/SingletonLock --exclude=/SingletonSocket --exclude=/SingletonCookie
		;;
	esac
}

list_backup_dirs() {
	[ -d "$BACKUP_DIR" ] || return 0
	find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '2*' ! -name '*.partial' | sort
}

# Copia incremental: los ficheros que no cambian desde la copia anterior se
# enlazan (hard link) y no ocupan espacio extra.
# Uso: create_backup [etiqueta] [prune|no-prune]
create_backup() {
	local label=${1:-manual} prune=${2:-prune} dest latest root filters
	mkdir -p "$BACKUP_DIR"
	chmod 700 "$BACKUP_DIR"
	latest=$(list_backup_dirs | tail -n1)
	dest="$BACKUP_DIR/$(date +%Y%m%d-%H%M%S)-$label"
	rm -rf -- "$dest.partial"

	info "Copia de seguridad de conversaciones y ajustes en $dest"
	for root in "${DATA_PATHS[@]}"; do
		[ -d "$HOME/$root" ] || continue
		mapfile -t filters < <(backup_filters "$root")
		mkdir -p "$dest.partial/$root"
		rsync -a --no-specials --no-devices "${filters[@]}" \
			${latest:+--link-dest="$latest/$root"} \
			"$HOME/$root/" "$dest.partial/$root/" ||
			die "Falló la copia de $HOME/$root; no se continúa para no arriesgar datos."
	done
	mv -- "$dest.partial" "$dest"
	# du cuenta una sola vez los hard links compartidos: la última línea es lo nuevo.
	ok "Copia creada: $(basename "$dest") ($(du -sh ${latest:+"$latest"} "$dest" | tail -n1 | cut -f1) nuevos)"
	[ "$prune" = no-prune ] || prune_backups
}

prune_backups() {
	local old
	list_backup_dirs | head -n "-$BACKUP_KEEP" | while read -r old; do
		rm -rf -- "$old"
		info "Eliminada copia antigua: $(basename "$old")"
	done
}

cmd_backups() {
	local dirs
	mapfile -t dirs < <(list_backup_dirs)
	if [ ${#dirs[@]} -eq 0 ]; then
		warn "No hay copias en $BACKUP_DIR"
		return 0
	fi
	info "Copias en $BACKUP_DIR (tamaño incremental):"
	du -sh "${dirs[@]}" | sed "s#$BACKUP_DIR/##; s/^/    /"
}

cmd_backup() {
	ensure_closed || die "No se hace la copia con Antigravity abierto."
	create_backup manual
}

cmd_restore() {
	local id=${1:-} src root filters restored=0
	if [ -z "$id" ]; then
		cmd_backups
		[ -t 0 ] || die "Indica la copia: $0 restore <copia>"
		read -r -p "Copia a restaurar (nombre, vacío para cancelar): " id
		[ -n "$id" ] || return 0
	fi
	src="$BACKUP_DIR/$(basename "$id")"
	[ -d "$src" ] || die "No existe la copia $src"
	for root in "${DATA_PATHS[@]}"; do
		[ -d "$src/$root" ] && restored=$((restored + 1))
	done
	[ "$restored" -gt 0 ] || die "La copia $(basename "$src") no contiene datos de Antigravity; no hay nada que restaurar."
	restored=0

	ensure_closed || die "No se restaura con Antigravity abierto."
	confirm "Se sustituirán los datos actuales de Antigravity por $(basename "$src"). El estado actual se guarda antes en otra copia. ¿Seguir?" || return 0
	# Sin rotación: podar ahora podría borrar justo la copia que se va a restaurar.
	create_backup pre-restore no-prune
	[ -d "$src" ] || die "La copia $src ha desaparecido; no se ha restaurado nada."

	for root in "${DATA_PATHS[@]}"; do
		[ -d "$src/$root" ] || continue
		mapfile -t filters < <(backup_filters "$root")
		mkdir -p "$HOME/$root"
		# --delete solo actúa dentro de $HOME/$root y respeta las exclusiones (cachés, binarios).
		rsync -a --delete --no-specials --no-devices "${filters[@]}" "$src/$root/" "$HOME/$root/"
		restored=$((restored + 1))
	done
	[ "$restored" -gt 0 ] || die "La copia $(basename "$src") no contiene datos de Antigravity; no se ha restaurado nada."
	ok "Restaurada la copia $(basename "$src") ($restored carpetas)"
}

# ---------------------------------------------------------------------------
# Comandos
# ---------------------------------------------------------------------------
cmd_status() {
	local component local_v remote_v state
	fetch_download_page
	printf '%s%-24s %-24s %-24s %s%s\n' "$C_BOLD" "Componente" "Instalada" "Disponible" "Estado" "$C_OFF"
	for component in "${ALL_COMPONENTS[@]}"; do
		local_v=$(local_version "$component")
		remote_v=$(remote_version "$component")
		if [ -z "$local_v" ]; then
			state="${C_WARN}no instalado${C_OFF}"
		elif [ -z "$remote_v" ]; then
			state="${C_WARN}no se pudo consultar${C_OFF}"
		elif version_newer "$local_v" "$remote_v"; then
			state="${C_WARN}actualización disponible${C_OFF}"
		else
			state="${C_OK}al día${C_OFF}"
		fi
		printf '%-24s %-24s %-24s %s\n' "$(component_label "$component")" "${local_v:--}" "${remote_v:--}" "$state"
	done
}

update_with_helper() {
	local helper=$1
	[ -x "$helper" ] ||
		die "No existe $helper. Instala primero el helper de LinuxCapable para este componente."
	sudo "$helper"
}

# Se ejecuta al salir (también con Ctrl-C): si no ha quedado agy instalado,
# devuelve a su sitio el binario apartado; si lo hay, descarta la copia.
cli_install_cleanup() {
	local tmp=$1 prev=$2
	if [ -f "$prev" ]; then
		if [ -e "$CLI_BIN" ]; then
			rm -f -- "$prev"
		else
			mv -f -- "$prev" "$CLI_BIN" && warn "Restaurado el agy anterior en $CLI_BIN"
		fi
	fi
	rm -rf -- "$tmp"
}

update_cli() {
	local tmp prev="$CLI_BIN.prev" installer_sha
	command -v sha256sum >/dev/null 2>&1 || die "Falta el comando requerido: sha256sum"
	# Restos de una ejecución interrumpida antes de existir esta protección.
	if [ ! -e "$CLI_BIN" ] && [ -f "$prev" ]; then
		mv -f -- "$prev" "$CLI_BIN"
	fi
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/agy-install.XXXXXX")
	# shellcheck disable=SC2064 # se expande ahora a propósito: las variables locales no existen al salir
	trap "$(printf 'cli_install_cleanup %q %q' "$tmp" "$prev")" EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 -m 60 -o "$tmp/install.sh" "$CLI_INSTALLER_URL" ||
		die "No se pudo descargar el instalador del CLI"
	# install.sh no publica firma ni hash: al menos se comprueba que es un script
	# de shell y se deja su SHA-256 en el log (o se exige si se ha fijado).
	[ -s "$tmp/install.sh" ] || die "El instalador del CLI descargado está vacío"
	head -n1 "$tmp/install.sh" | grep -Eq '^#!.*(/|env )(ba)?sh\b' ||
		die "El instalador del CLI descargado no parece un script de shell; no se ejecuta"
	installer_sha=$(sha256sum "$tmp/install.sh" | cut -d' ' -f1)
	info "Instalador del CLI: $CLI_INSTALLER_URL (sha256 $installer_sha)"
	if [ -n "$CLI_INSTALLER_SHA256" ] && [ "$installer_sha" != "${CLI_INSTALLER_SHA256,,}" ]; then
		die "El SHA-256 de install.sh no coincide con ANTIGRAVITY_CLI_INSTALLER_SHA256 ($CLI_INSTALLER_SHA256); no se ejecuta"
	fi
	# El instalador oficial sale sin actualizar si ~/.local/bin/agy ya existe;
	# lo apartamos junto a él (no en $tmp, que se borra al salir) y se restaura
	# si la instalación falla o se interrumpe.
	if [ -f "$CLI_BIN" ]; then
		mv -f -- "$CLI_BIN" "$prev"
	fi
	if ! bash "$tmp/install.sh" || [ ! -x "$CLI_BIN" ]; then
		[ -f "$prev" ] && mv -f -- "$prev" "$CLI_BIN"
		die "Falló la actualización del CLI"
	fi
}

# Devuelve 0 si el componente necesita instalarse o actualizarse.
needs_update() {
	local component=$1 label local_v remote_v
	label=$(component_label "$component")
	local_v=$(local_version "$component")
	remote_v=$(remote_version "$component")

	REMOTE_VERSIONS[$component]=$remote_v

	info "$label: instalada ${local_v:-ninguna}, disponible ${remote_v:-desconocida}"
	if [ -z "$remote_v" ] && [ "$FORCE" != yes ]; then
		warn "$label: no se pudo consultar la versión disponible; no se actualiza (usa --force para forzarlo)"
		return 1
	fi
	if [ "$FORCE" != yes ] && [ -n "$local_v" ] && ! version_newer "$local_v" "$remote_v"; then
		ok "$label ya está al día"
		return 1
	fi
}

update_component() {
	local component=$1
	case "$component" in
	desktop) update_with_helper "$DESKTOP_HELPER" ;;
	ide) update_with_helper "$IDE_HELPER" ;;
	cli) update_cli ;;
	esac
	record_version "$component" "${REMOTE_VERSIONS[$component]:-}"
	ok "$(component_label "$component"): $(local_version "$component")"
}

cmd_update() {
	local components=("$@") component pending=() failed=()
	[ ${#components[@]} -eq 0 ] && components=("${ALL_COMPONENTS[@]}")
	for component in "${components[@]}"; do
		case "$component" in
		all) components=("${ALL_COMPONENTS[@]}") && break ;;
		desktop | ide | cli) ;;
		*) die "Componente desconocido: $component (usa desktop, ide, cli o all)" ;;
		esac
	done

	fetch_download_page
	for component in "${components[@]}"; do
		needs_update "$component" && pending+=("$component")
	done
	if [ ${#pending[@]} -eq 0 ]; then
		echo
		cmd_status
		return 0
	fi

	ensure_closed || die "Actualización cancelada: cierra Antigravity y vuelve a intentarlo."
	if [ "$DO_BACKUP" = yes ]; then
		create_backup "pre-update-$(IFS=-; echo "${pending[*]}")"
	else
		warn "Actualizando sin copia de seguridad (--no-backup)"
	fi

	for component in "${pending[@]}"; do
		# Cada componente en un subshell: si uno falla, se sigue con el resto.
		if ! (update_component "$component"); then
			failed+=("$component")
			warn "Falló la actualización de $(component_label "$component")"
		fi
	done

	echo
	cmd_status
	if [ "$DO_BACKUP" = yes ]; then
		echo
		info "Al abrirse por primera vez, las versiones nuevas pueden migrar las conversaciones."
		info "Si falta alguna, restaura la copia previa con: $0 restore"
	fi
	[ ${#failed[@]} -eq 0 ] || die "Componentes con error: ${failed[*]}"
}

# Menú interactivo: permite actualizar todos los componentes o solo los elegidos
# (varios números separados por espacios o comas, p. ej. "2 4").
cmd_menu() {
	local choice token tokens selected component unique
	[ -t 0 ] || die "El menú necesita una terminal interactiva; usa: $0 update [componente...]"

	while true; do
		echo
		cmd_status
		echo
		printf '%s¿Qué quieres hacer?%s\n' "$C_BOLD" "$C_OFF"
		echo "  1) Actualizar todos"
		echo "  2) Actualizar $(component_label desktop)"
		echo "  3) Actualizar $(component_label ide)"
		echo "  4) Actualizar $(component_label cli)"
		echo "  b) Copia de seguridad de conversaciones"
		echo "  l) Listar copias de seguridad"
		echo "  s) Restaurar una copia de seguridad"
		echo "  c) Limpiar restos de actualizaciones"
		echo "  r) Refrescar estado"
		echo "  q) Salir"
		read -r -p "Opción (puedes elegir varias, p. ej. \"2 4\"): " choice || return 0

		selected=()
		read -r -a tokens <<<"${choice//,/ }"
		for token in "${tokens[@]+"${tokens[@]}"}"; do
			case "$token" in
			1) selected=("${ALL_COMPONENTS[@]}") && break ;;
			2) selected+=(desktop) ;;
			3) selected+=(ide) ;;
			4) selected+=(cli) ;;
			b | B) (cmd_backup) || true ;;
			l | L) cmd_backups ;;
			s | S) (cmd_restore) || true ;;
			c | C) (cmd_clean) || true ;;
			r | R) DOWNLOAD_HTML='' ;;
			q | Q | 0) return 0 ;;
			*) warn "Opción no válida: $token" ;;
			esac
		done

		if [ ${#selected[@]} -gt 0 ]; then
			# Quita duplicados manteniendo el orden.
			unique=()
			for component in "${selected[@]}"; do
				[[ " ${unique[*]-} " == *" $component "* ]] || unique+=("$component")
			done
			# cmd_update termina con die si algo falla; en el menú se sigue.
			(cmd_update "${unique[@]}") || true
			DOWNLOAD_HTML=''
		fi
		read -r -p "Pulsa Intro para volver al menú..." _ || return 0
	done
}

# Elimina copias de seguridad y temporales que hayan quedado de actualizaciones
# interrumpidas, sin tocar nunca el directorio al que apunta el ejecutable activo.
cmd_clean() {
	local active_desktop active_ide system_paths=() user_paths=() path
	active_desktop=$(readlink -f "$DESKTOP_LINK" 2>/dev/null || true)
	active_ide=$(readlink -f "$IDE_LINK" 2>/dev/null || true)

	# Restos de los helpers (se ejecutan con sudo): solo entradas propiedad de
	# root y que no sean enlaces simbólicos. En /var/tmp cualquiera puede crear
	# ficheros con ese nombre, así que solo se aceptan los directorios de mktemp -d.
	while IFS= read -r -d '' path; do
		case "$active_desktop/" in "$path"/*) continue ;; esac
		case "$active_ide/" in "$path"/*) continue ;; esac
		system_paths+=("$path")
	done < <(
		for path in "$DESKTOP_ROOT" "$IDE_ROOT"; do
			find "$(dirname "$path")" -mindepth 1 -maxdepth 1 ! -type l -user root \
				\( -name "$(basename "$path").previous.*" -o -name "$(basename "$path").new.*" \) -print0 2>/dev/null || true
			[ -d "$path" ] && [ ! -L "$path" ] || continue
			find "$path" -mindepth 1 -maxdepth 1 ! -type l -user root -name '*.backup-*' -print0 2>/dev/null || true
		done
		find /var/tmp -mindepth 1 -maxdepth 1 -type d -user root \
			\( -name 'antigravity.*' -o -name 'antigravity-ide.*' \) -print0 2>/dev/null || true
	)
	# Copias a medias del propio script: son del usuario y se borran sin sudo.
	if [ -d "$BACKUP_DIR" ]; then
		while IFS= read -r -d '' path; do
			user_paths+=("$path")
		done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -user "$(id -u)" -name '*.partial' -print0)
	fi

	if [ $((${#system_paths[@]} + ${#user_paths[@]})) -eq 0 ]; then
		ok "No hay restos que limpiar"
		return 0
	fi
	printf '  %s\n' "${system_paths[@]+"${system_paths[@]}"}" "${user_paths[@]+"${user_paths[@]}"}"
	confirm "¿Borrar estos $((${#system_paths[@]} + ${#user_paths[@]})) elementos?" || {
		warn "Limpieza cancelada"
		return 0
	}
	[ ${#user_paths[@]} -eq 0 ] || rm -rf -- "${user_paths[@]}"
	[ ${#system_paths[@]} -eq 0 ] || sudo rm -rf -- "${system_paths[@]}"
	ok "Limpieza completada"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
[ "$(id -u)" -ne 0 ] ||
	die "Ejecútalo como tu usuario (sin sudo): el CLI y los datos están en tu \$HOME y el script pide sudo cuando lo necesita."

for required_command in curl sed grep sort pgrep timeout rsync; do
	command -v "$required_command" >/dev/null 2>&1 || die "Falta el comando requerido: $required_command"
done

# Con 0 o un valor no numérico, la rotación ("head -n -N") borraría todas las copias.
[[ "$BACKUP_KEEP" =~ ^[1-9][0-9]*$ ]] ||
	die "ANTIGRAVITY_BACKUP_KEEP debe ser un entero mayor o igual que 1 (valor actual: '$BACKUP_KEEP')"

args=()
for arg in "$@"; do
	case "$arg" in
	-f | --force) FORCE=yes ;;
	-y | --yes) ASSUME_YES=yes ;;
	--no-backup) DO_BACKUP=no ;;
	-h | --help) usage && exit 0 ;;
	*) args+=("$arg") ;;
	esac
done
set -- "${args[@]+"${args[@]}"}"

if [ -t 0 ] && [ -t 1 ]; then
	default_command=menu
else
	default_command=status
fi
command=${1:-$default_command}
[ $# -gt 0 ] && shift
case "$command" in
menu) cmd_menu ;;
status) cmd_status ;;
update | install | upgrade) cmd_update "$@" ;;
backup) cmd_backup ;;
backups) cmd_backups ;;
restore) cmd_restore "$@" ;;
clean) cmd_clean ;;
help) usage ;;
*)
	usage
	exit 1
	;;
esac
