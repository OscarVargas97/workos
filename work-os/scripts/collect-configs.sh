#!/usr/bin/env bash
# Fase final — recolección de configuraciones sensibles (.env, .sql
# gitignorados) de los repos reales encontrados en $HOME hacia
# ~/Repos/Externos/workos/vault/, organizados automáticamente por la
# misma ruta relativa que ya tienen en el home de quien lo corre.
#
# No hay ninguna ruta de proyecto ni nombre de repo hardcodeado: los repos
# se descubren dinámicamente cada vez que se corre, así sirve igual en
# cualquier máquina/usuario (ver regla general en workos/DECISIONS.md).
#
# Por defecto SOLO LISTA (read-only). Nada se copia sin --copy.
# Nunca se publica ni se versiona nada de esto; se guarda cifrado.
set -euo pipefail

COPY=false
[[ "${1:-}" == "--copy" ]] && COPY=true

VAULT="${WORKOS_BASE:-$HOME/Repos/Externos/workos}/vault"
# Solo se copia DENTRO del vault cifrado ya abierto (vault.sh open): así
# nada de esto toca el disco en claro (DECISIONS.md #15).
if $COPY && ! mountpoint -q "$VAULT"; then
  echo "El vault cifrado no está abierto en $VAULT." >&2
  echo "Primero: $(dirname "$0")/vault.sh init (la primera vez) y vault.sh open - o work vault open." >&2
  exit 1
fi

echo "=== Qué hace este script ==="
echo "Busca repos git reales bajo \$HOME (excluyendo cachés/herramientas de"
echo "versionado como pyenv, nvm, fzf), y dentro de cada uno busca:"
echo "  - archivos .env / .env.* / .envrc (siempre)"
echo "  - archivos .sql, SOLO si están en el .gitignore del repo (dumps"
echo "    locales, no migraciones versionadas)"
if $COPY; then
  echo "Modo --copy: los copia a $VAULT, en la misma ruta relativa a \$HOME"
  echo "que ya tienen (ej. ~/Proyectos/x/.env -> vault/Proyectos/x/.env)."
else
  echo "Modo lista (default): solo muestra qué encontraría. Usar --copy para"
  echo "copiar de verdad."
fi
echo

# Directorios que no son proyectos reales — cachés/herramientas de versión,
# no hace falta tocarlos nunca. OJO: ".git" NO va acá — este mismo prune
# se usa para DESCUBRIR repos buscando ".git" (ver find de abajo), si lo
# excluimos acá nunca se imprime ninguno (se poda a sí mismo antes de
# llegar al "-print"). Evitar bajar a .git/ al buscar archivos DENTRO de
# un repo ya está resuelto aparte, en el segundo find de más abajo.
EXCLUDE_DIRS=(.cache .nvm .pyenv .fzf .rustup .cargo .local node_modules venv .venv)

PRUNE_EXPR=()
for d in "${EXCLUDE_DIRS[@]}"; do
  PRUNE_EXPR+=(-name "$d" -o)
done
unset 'PRUNE_EXPR[${#PRUNE_EXPR[@]}-1]' # saca el último -o suelto

mapfile -t GIT_DIRS < <(
  find "$HOME" \( "${PRUNE_EXPR[@]}" \) -prune -o -type d -name '.git' -print 2>/dev/null
)

total=0
for gitdir in "${GIT_DIRS[@]}"; do
  repo="${gitdir%/.git}"
  rel="${repo#"$HOME"/}"
  dest="$VAULT/$rel"

  mapfile -t files < <(
    find "$repo" \( -name node_modules -o -name .git -o -name venv -o -name .venv \) -prune -o \
      -type f \( -name '.env' -o -name '.env.*' -o -name '.envrc' -o -name '*.sql' \) -print 2>/dev/null
  )

  keep=()
  for f in "${files[@]}"; do
    case "$f" in
      *.example|*.sample|*.template)
        # Plantilla pensada para vivir EN git (valores vacíos a
        # propósito) - no es un secreto real, no necesita backup.
        continue
        ;;
      *.sql)
        git -C "$repo" check-ignore -q "$f" 2>/dev/null && keep+=("$f")
        ;;
      *)
        keep+=("$f")
        ;;
    esac
  done

  [[ ${#keep[@]} -eq 0 ]] && continue

  echo "== $repo -> vault/$rel =="
  for f in "${keep[@]}"; do
    frel="${f#"$repo"/}"
    echo "  $frel"
    total=$((total + 1))
    if $COPY; then
      mkdir -p "$dest/$(dirname "$frel")"
      # -p preserva permisos/timestamps del original - un .env suele
      # estar en 600 (solo el dueño), sin -p el destino queda con el
      # umask del proceso (típicamente 644, más abierto que el original).
      cp -p "$f" "$dest/$frel"
    fi
  done
done

echo
if $COPY; then
  echo "$total archivo(s) copiados a $VAULT"
else
  echo "$total archivo(s) encontrados (modo lista, sin copiar). Usar --copy para copiar a $VAULT"
fi
