# Descubrimiento de repos y mapeo repo -> destino, compartido entre
# migrate-pc.sh y map-repos.sh (mismo criterio exacto en los dos, para no
# mantenerlo duplicado). Requiere WORKOS_PRIVATE ya resuelto por quien lo
# source-ea.
#
# Mapeo (work-os/repo-companies.conf del repo privado), una línea por repo:
#   ruta-relativa-a-$HOME=empresa=nombre-destino
# Reglas (DECISIONS.md #11 y #14):
#   - empresa: clave en minúscula (la misma de companies.conf); vacía =
#     repo personal/de terceros -> Repos/Externos/<destino>.
#   - con empresa -> Repos/<Empresa>/<destino> (carpeta con mayúscula
#     inicial; la clave sigue en minúscula).
#   - destino vacío = no migrar (duplicado/descartado a propósito).
#   - destino puede tener "/" para agrupar repos hermanos de un mismo
#     proyecto (ej. "Proyecto/backend"); lo suelto de esa carpeta-grupo
#     (docs/, Makefile) también se migra.

REPO_COMPANIES_FILE="$WORKOS_PRIVATE/work-os/repo-companies.conf"
REPO_EMPRESA_RE='^([a-z][a-z0-9-]*)?$'
REPO_DEST_RE='^([A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*)?$'

# Repos git bajo $HOME, uno por línea (ruta absoluta, sin /.git).
# "workos" excluido a propósito: workos/workos-private/vault los maneja la
# instalación por separado, no son "tus proyectos de trabajo". .claude
# excluido: plugins/marketplaces descargados y tmp/ de jobs de Claude Code
# (hallazgo real probando esto).
discover_repos() {
  local EXCLUDE_DIRS=(.cache .nvm .pyenv .fzf .rustup .cargo .local .claude node_modules venv .venv workos)
  local PRUNE_EXPR=() d
  for d in "${EXCLUDE_DIRS[@]}"; do PRUNE_EXPR+=(-name "$d" -o); done
  unset 'PRUNE_EXPR[${#PRUNE_EXPR[@]}-1]'
  find "$HOME" \( "${PRUNE_EXPR[@]}" \) -prune -o -type d -name '.git' -print 2>/dev/null \
    | sed 's#/\.git$##' | sort
}

# lookup_repo_dest <ruta-relativa> -> imprime "empresa=destino"; falla si no está mapeado.
lookup_repo_dest() {
  [ -f "$REPO_COMPANIES_FILE" ] || return 1
  awk -F= -v r="$1" '$1==r { print $2 "=" $3; found=1 } END { exit !found }' "$REPO_COMPANIES_FILE"
}

# repo_dest_path <empresa> <destino> -> ruta de destino relativa a $HOME.
repo_dest_path() {
  if [ -n "$1" ]; then
    echo "Repos/$(tr '[:lower:]' '[:upper:]' <<< "${1:0:1}")${1:1}/$2"
  else
    echo "Repos/Externos/$2"
  fi
}
