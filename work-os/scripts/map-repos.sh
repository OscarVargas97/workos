#!/usr/bin/env bash
# Mapea los repos git de ESTA máquina a su destino en la máquina nueva
# (work-os/repo-companies.conf del repo privado), para que migrate-pc.sh
# los ordene en Repos/<Empresa>/ o Repos/Externos/ sin preguntar de nuevo.
# Reglas del mapeo: ver lib-repos.sh.
#
# Uso:
#   map-repos.sh                    interactivo: pregunta solo los repos sin mapear
#   map-repos.sh --list             tabla TSV para leer (personas o agentes):
#                                   estado, ruta, remote, empresa, destino, ruta final
#   map-repos.sh --set 'ruta=empresa=destino' [...]
#                                   agrega o reemplaza entradas, validando las reglas
#                                   (ruta relativa a $HOME, como la muestra --list)
#
# Después de mapear: commit + push del repo privado (así el mapeo queda
# para la próxima máquina).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKOS_PRIVATE="${WORKOS_PRIVATE:-$(cd "$SCRIPT_DIR/../../.." && pwd)/workos-private}"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-repos.sh"
[ -d "$WORKOS_PRIVATE/work-os" ] || { echo "No encuentro el repo privado en $WORKOS_PRIVATE (usa WORKOS_PRIVATE=<ruta>)." >&2; exit 1; }
touch "$REPO_COMPANIES_FILE"

set_entry() { # set_entry ruta empresa destino
  local rel=$1 empresa=$2 dest=$3
  [[ "$rel" =~ ^[^=/][^=]*$ && "$rel" != *..* ]] || { echo "Ruta inválida: '$rel' (relativa a \$HOME, sin '=' ni '..')." >&2; return 1; }
  [[ "$empresa" =~ $REPO_EMPRESA_RE ]] || { echo "Empresa inválida: '$empresa' (minúsculas, números y '-'; vacío = externo)." >&2; return 1; }
  [[ "$dest" =~ $REPO_DEST_RE && "$dest" != *..* ]] || { echo "Destino inválido: '$dest' (nombre o Grupo/nombre; vacío = no migrar)." >&2; return 1; }
  awk -F= -v r="$rel" '$1!=r' "$REPO_COMPANIES_FILE" > "$REPO_COMPANIES_FILE.tmp"
  mv "$REPO_COMPANIES_FILE.tmp" "$REPO_COMPANIES_FILE"
  printf '%s=%s=%s\n' "$rel" "$empresa" "$dest" >> "$REPO_COMPANIES_FILE"
}

case "${1:-}" in
  --list)
    printf 'estado\truta\tremote\tempresa\tdestino\truta_final\n'
    while read -r repo; do
      rel="${repo#"$HOME"/}"
      remote=$(git -C "$repo" remote get-url origin 2>/dev/null || echo "-")
      if d=$(lookup_repo_dest "$rel"); then
        IFS='=' read -r empresa dest <<< "$d"
        final=$([ -n "$dest" ] && repo_dest_path "$empresa" "$dest" || echo "(no migrar)")
        printf 'mapeado\t%s\t%s\t%s\t%s\t%s\n' "$rel" "$remote" "${empresa:--}" "${dest:--}" "$final"
      else
        printf 'pendiente\t%s\t%s\t-\t-\t-\n' "$rel" "$remote"
      fi
    done < <(discover_repos)
    ;;
  --set)
    shift
    [ $# -gt 0 ] || { echo "Uso: map-repos.sh --set 'ruta=empresa=destino' [...]" >&2; exit 1; }
    for e in "$@"; do
      IFS='=' read -r rel empresa dest extra <<< "$e"
      [ -z "${extra:-}" ] || { echo "Formato: ruta=empresa=destino ('$e')." >&2; exit 1; }
      set_entry "$rel" "$empresa" "$dest"
      echo "OK: $rel -> $([ -n "$dest" ] && repo_dest_path "$empresa" "$dest" || echo "(no migrar)")"
    done
    ;;
  "")
    mapfile -t pending < <(discover_repos | while read -r repo; do
      rel="${repo#"$HOME"/}"; lookup_repo_dest "$rel" >/dev/null || echo "$repo"; done)
    [ "${#pending[@]}" -gt 0 ] || { echo "Todos los repos ya están mapeados ($REPO_COMPANIES_FILE)."; exit 0; }
    echo "${#pending[@]} repo(s) sin mapear. Para cada uno:"
    echo "  - empresa: su clave en minúscula (la de companies.conf), vacío = personal/de terceros (Repos/Externos)"
    echo "  - destino: nombre de carpeta (o Grupo/nombre para agrupar repos hermanos), vacío = no migrar"
    for repo in "${pending[@]}"; do
      rel="${repo#"$HOME"/}"
      echo
      echo "  $rel  ($(git -C "$repo" remote get-url origin 2>/dev/null || echo "sin remote"))"
      while true; do
        read -rp "     empresa [vacío = externo]: " empresa
        read -rp "     destino bajo $(repo_dest_path "$empresa" "")[${repo##*/}, '-' = no migrar]: " dest
        case "$dest" in "") dest=${repo##*/} ;; -) dest="" ;; esac
        set_entry "$rel" "$empresa" "$dest" && break
      done
    done
    echo
    echo "Guardado en $REPO_COMPANIES_FILE - commitealo en el repo privado."
    ;;
  *) sed -n '2,17p' "$0"; exit 1 ;;
esac
