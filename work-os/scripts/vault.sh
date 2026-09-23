#!/usr/bin/env bash
# vault/ cifrado (docs/DECISIONS.md #15): los .env y dumps de proyectos
# viven SOLO cifrados en <base>/vault.enc (gocryptfs, archivo por archivo,
# aguanta dumps de varios GB sin cargarlos en RAM). `open` monta la vista
# descifrada en <base>/vault; `close` la desmonta. Cualquier copia de
# vault.enc (backup, otra máquina, disco robado) es ilegible sin la clave.
#
# La clave vive en Bitwarden (entrada "workos-vault"), así que abrir el
# vault exige Bitwarden desbloqueado: contraseña maestra + el 2FA de la
# cuenta. Nunca se escribe a disco.
#
# Uso (en NixOS: `work vault <comando>`; en otra distro: este script, con
# gocryptfs y rbw instalados):
#   vault.sh init            crea vault.enc (y la clave en Bitwarden si no existe)
#   vault.sh open | close    monta / desmonta <base>/vault
#   vault.sh status
#   vault.sh import <dir>    cifra un vault en claro existente (lo mueve adentro)
#
# Entorno: WORKOS_BASE (default ~/Repos/Externos/workos),
#          WORKOS_VAULT_PASS_CMD (default "rbw get workos-vault").
set -euo pipefail

BASE="${WORKOS_BASE:-$HOME/Repos/Externos/workos}"
CIPHER="$BASE/vault.enc"
PLAIN="$BASE/vault"
PASS_CMD="${WORKOS_VAULT_PASS_CMD:-rbw get workos-vault}"
# La clave llega por un pipe en memoria (sustitución de proceso), nunca a disco.
passfile() { sh -c "$PASS_CMD"; }

is_open() { mountpoint -q "$PLAIN" 2>/dev/null; }
need_init() { [ -f "$CIPHER/gocryptfs.conf" ] || { echo "No hay vault cifrado en $CIPHER: corré 'init' primero." >&2; exit 1; }; }

cmd_init() {
  if [ -f "$CIPHER/gocryptfs.conf" ]; then echo "Ya existe $CIPHER."; return; fi
  if ! sh -c "$PASS_CMD" >/dev/null 2>&1; then
    if [ -z "${WORKOS_VAULT_PASS_CMD:-}" ]; then
      echo "No hay clave 'workos-vault' en Bitwarden (o está bloqueado: rbw unlock)."
      read -rp "¿Generar una clave nueva y guardarla en Bitwarden? [S/n] " a
      [[ "${a:-s}" =~ ^[sSyY]$ ]] || exit 1
      rbw generate 48 workos-vault >/dev/null
    else
      echo "WORKOS_VAULT_PASS_CMD falló: '$PASS_CMD'." >&2; exit 1
    fi
  fi
  mkdir -p "$CIPHER"
  gocryptfs -init -q -passfile <(passfile) "$CIPHER"
  echo "OK: $CIPHER creado (la clave está en Bitwarden como 'workos-vault')."
}

cmd_open() {
  need_init
  if is_open; then echo "Ya está abierto en $PLAIN."; return; fi
  mkdir -p "$PLAIN"
  [ -z "$(ls -A "$PLAIN")" ] || { echo "$PLAIN no está vacío: ¿un vault en claro viejo? Usá 'import $PLAIN'." >&2; exit 1; }
  gocryptfs -q -passfile <(passfile) "$CIPHER" "$PLAIN"
  echo "Abierto en $PLAIN - cerralo con 'close' cuando termines."
}

cmd_close() {
  if ! is_open; then echo "No estaba abierto."; return; fi
  fusermount -u "$PLAIN" 2>/dev/null || fusermount3 -u "$PLAIN"
  echo "Cerrado."
}

cmd_status() {
  if [ ! -f "$CIPHER/gocryptfs.conf" ]; then echo "Sin vault cifrado ($CIPHER no existe)."
  elif is_open; then echo "Abierto en $PLAIN."
  else echo "Cerrado ($CIPHER)."; fi
  if [ -d "$PLAIN" ] && ! is_open && [ -n "$(ls -A "$PLAIN" 2>/dev/null)" ]; then
    echo "AVISO: $PLAIN tiene archivos EN CLARO (fuera del vault cifrado): 'import $PLAIN'." >&2
  fi
}

cmd_import() {
  local src=${1:?Uso: vault.sh import <dir>}
  src=$(cd "$src" && pwd)
  [ "$src" != "$CIPHER" ] || { echo "Eso es el vault cifrado." >&2; exit 1; }
  # Si el origen es el propio punto de montaje, se aparta primero.
  if [ "$src" = "$PLAIN" ]; then
    mv "$PLAIN" "$PLAIN.claro"
    src="$PLAIN.claro"
  fi
  [ -f "$CIPHER/gocryptfs.conf" ] || cmd_init
  cmd_open
  echo "Copiando $src -> vault cifrado..."
  rsync -a "$src/" "$PLAIN/"
  # Verificación contenido por contenido antes de ofrecer borrar el original.
  if [ -n "$(rsync -a --checksum --dry-run --itemize-changes "$src/" "$PLAIN/")" ]; then
    echo "La copia no coincide con el original: NO borro nada, revisá a mano." >&2; exit 1
  fi
  echo "Copia verificada ($(du -sh "$src" | cut -f1))."
  read -rp "Escribí 'si' para BORRAR el original en claro ($src): " a
  if [ "$a" = si ]; then rm -rf "$src"; echo "Original borrado."; else echo "Original conservado en $src."; fi
}

case "${1:-}" in
  init) cmd_init ;;
  open) cmd_open ;;
  close) cmd_close ;;
  status) cmd_status ;;
  import) shift; cmd_import "$@" ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
