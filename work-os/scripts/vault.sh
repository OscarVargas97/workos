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
#   vault.sh env list        .env del repo actual: vault vs repo (igual/distinto/solo en uno)
#   vault.sh env pull [f..]  vault -> repo (pregunta antes de pisar)
#   vault.sh env push [f..]  repo -> vault (pregunta antes de pisar)
#   vault.sh env send <f>    manda un .env del vault por LocalSend
#   vault.sh env push --all  todos los repos bajo $HOME, sin declarar ninguno
#   vault.sh reorg           mueve el vault al layout de repo-companies.conf
#   (env/reorg necesitan el vault abierto; nunca lo abren solos)
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

# --- .env de los repos ---------------------------------------------------
# El vault guarda los .env de cada repo en la misma ruta relativa al home:
# ~/Repos/X/app/.env <-> vault/Repos/X/app/.env. El repo es el de $PWD.
# Solo archivos .env* que git ignora (un .env.example versionado no es
# secreto). Nunca abre el vault solo: si está cerrado, avisa y sale.
need_open() { is_open || { echo "El vault está cerrado: work vault open (y close al terminar)." >&2; exit 1; }; }

repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || { echo "No estás dentro de un repo git." >&2; exit 1; }
}

vault_dir() {
  local root=$1
  case "$root" in "$HOME"/*) ;; *) echo "El repo tiene que estar dentro de $HOME." >&2; exit 1 ;; esac
  echo "$PLAIN/${root#"$HOME"/}"
}

# .env* ignorados por git dentro del repo, como rutas relativas.
repo_envs() {
  (cd "$1" && find . \( -name node_modules -o -name .git -o -name .venv \) -prune -o -type f -name '.env*' -print \
    | sed 's|^\./||' | while read -r f; do if git check-ignore -q "$f"; then echo "$f"; fi; done)
}

vault_envs() { [ -d "$1" ] || return 0; (cd "$1" && find . -type f -name '.env*' | sed 's|^\./||'); }

# copy <origen> <destino> <nombre>: pregunta antes de pisar uno distinto.
copy_env() {
  local src=$1 dst=$2 name=$3
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then echo "  = $name (igual)"; return; fi
  if [ -f "$dst" ]; then
    read -rp "  $name es distinto en el destino. ¿Reemplazarlo? [s/N] " a
    [[ "$a" =~ ^[sSyY]$ ]] || { echo "  - $name (sin cambios)"; return; }
  fi
  mkdir -p "$(dirname "$dst")"
  install -m 600 "$src" "$dst"
  echo "  + $name"
}

# Repos bajo $HOME: el mismo descubrimiento que migrate-pc.sh (lib-repos.sh,
# empaquetado junto a este script).
WORKOS_PRIVATE="${WORKOS_PRIVATE:-$BASE/workos-private}"
# shellcheck source=lib-repos.sh
. "$(dirname "$0")/lib-repos.sh"

# push de un repo (ruta absoluta): repo -> vault.
push_repo() {
  local root=$1 dir f; shift
  dir=$(vault_dir "$root")
  for f in ${@:-$(repo_envs "$root")}; do
    [ -f "$root/$f" ] || { echo "  ! $f no está en el repo" >&2; continue; }
    copy_env "$root/$f" "$dir/$f" "$f"
  done
}

cmd_env() {
  local sub=${1:-} root dir f r
  shift || true
  need_open
  if [ "$sub" = push ] && [ "${1:-}" = --all ]; then
    # Todos los repos con .env, sin declarar ninguno. fd 3 para la lista:
    # stdin queda libre para las preguntas de copy_env.
    while read -r r <&3; do
      [ -n "$(repo_envs "$r")" ] || continue
      echo "== ${r#"$HOME"/}"
      push_repo "$r"
    done 3< <(discover_repos)
    return
  fi
  root=$(repo_root); dir=$(vault_dir "$root")
  case "$sub" in
    list)
      { vault_envs "$dir"; repo_envs "$root"; } | sort -u | while read -r f; do
        if [ ! -f "$root/$f" ]; then echo "solo en vault  $f"
        elif [ ! -f "$dir/$f" ]; then echo "solo en repo   $f"
        elif cmp -s "$root/$f" "$dir/$f"; then echo "igual          $f"
        else echo "distinto       $f"; fi
      done ;;
    pull) # vault -> repo
      for f in ${@:-$(vault_envs "$dir")}; do
        [ -f "$dir/$f" ] || { echo "  ! $f no está en el vault" >&2; continue; }
        copy_env "$dir/$f" "$root/$f" "$f"
      done ;;
    push) push_repo "$root" "$@" ;;
    send) # un .env del vault por LocalSend, sin dejar copia en disco
      f=${1:?Uso: work vault env send <archivo> (ver: work vault env list)}
      [ -f "$dir/$f" ] || { echo "$f no está en el vault de este repo." >&2; exit 1; }
      # Copia en RAM (XDG_RUNTIME_DIR es tmpfs), fuera del FUSE: LocalSend
      # no necesita ver el vault. Se borra al cerrar LocalSend.
      # ponytail: LocalSend no tiene CLI de envío; se abre con el archivo y se elige el destino a mano.
      local tmp; tmp=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/workos-send.XXXXXX")
      trap 'rm -rf "$tmp"' EXIT
      install -m 600 "$dir/$f" "$tmp/$(basename "$f")"
      echo "Enviando $tmp/$(basename "$f") - elegí el equipo en LocalSend y cerralo al terminar."
      localsend_app "$tmp/$(basename "$f")" >/dev/null 2>&1 || true ;;
    *) echo "Uso: work vault env list | pull [archivo...] | push [archivo...|--all] | send <archivo>" >&2; exit 1 ;;
  esac
}

# Reordena el vault de una migración vieja al layout nuevo con el mismo
# mapeo de migrate-pc.sh (repo-companies.conf): vault/<ruta vieja> ->
# vault/<Repos/Empresa/destino>. Sin destino (descartado) -> vault/_sin-destino/.
# Muestra el plan y solo mueve con 'si'; nunca pisa nada.
cmd_reorg() {
  need_open
  [ -f "$REPO_COMPANIES_FILE" ] || { echo "No encuentro $REPO_COMPANIES_FILE (WORKOS_PRIVATE=<ruta>)." >&2; exit 1; }
  local plan rel empresa dest to
  plan=$(while IFS='=' read -r rel empresa dest; do
    [[ -z "$rel" || "$rel" == \#* ]] && continue
    [ -d "$PLAIN/$rel" ] || continue
    if [ -n "$dest" ]; then to=$(repo_dest_path "$empresa" "$dest"); else to="_sin-destino/$rel"; fi
    [ "$to" = "$rel" ] || echo "$rel=$to"
  done < "$REPO_COMPANIES_FILE")
  [ -n "$plan" ] || { echo "Nada que reordenar."; return; }
  echo "$plan" | sed 's/=/  ->  /'
  read -rp "Escribí 'si' para mover: " a
  [ "$a" = si ] || { echo "Cancelado."; return; }
  while IFS='=' read -r rel to; do
    if [ -e "$PLAIN/$to" ]; then echo "  ! $to ya existe - $rel queda donde está" >&2; continue; fi
    mkdir -p "$(dirname "$PLAIN/$to")" && mv "$PLAIN/$rel" "$PLAIN/$to" && echo "  $rel -> $to"
  done <<< "$plan"
  find "$PLAIN" -mindepth 1 -type d -empty -delete
  echo "Lo que no está en repo-companies.conf quedó donde estaba."
}

case "${1:-}" in
  init) cmd_init ;;
  open) cmd_open ;;
  close) cmd_close ;;
  status) cmd_status ;;
  import) shift; cmd_import "$@" ;;
  env) shift; cmd_env "$@" ;;
  reorg) cmd_reorg ;;
  *) sed -n '2,27p' "$0"; exit 1 ;;
esac
