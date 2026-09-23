#!/usr/bin/env bash
# Punto de partida de workos: deja tu repo privado listo al lado de este
# clon, sin tener que saber nada de antemano.
#
#   1. Si ya tenés un repo privado de workos, lo descarga.
#      Si no, lo crea (privado) en tu cuenta u organización desde
#      workos-template.
#   2. Lo configura (scripts/setup.sh del privado: usuario, claves SSH,
#      máquina, empresa) - pregunta todo por consola.
#   3. Lo valida (scripts/check.sh: evalúa cada máquina sin instalar nada).
#   4. Fija versiones y lo publica (commit + push), con tu confirmación.
#
# Se puede correr de nuevo: si el repo privado ya está al lado, lo usa y
# solo ofrece reconfigurarlo/validarlo/publicarlo.
#
# Requiere: git, gh (con `gh auth login`) y nix o Docker/Podman.
# Uso: ./init.sh
#
# Sin preguntas (para agentes de IA o automatización), por entorno:
#   WORKOS_REPO_MODE    clone (ya tengo uno) | create (nuevo desde el template)
#   WORKOS_REPO         dueño/nombre del repo privado (default <tu usuario>/workos-private)
#   WORKOS_RECONFIGURE  s|n: correr setup.sh aunque ya esté configurado (default n)
#   WORKOS_PUBLISH      s|n: fijar versiones + commit + push al final (default s)
#   + las WORKOS_* de scripts/setup.sh del privado (usuario, claves, máquina...).
#   WORKOS_PRIVATE      dónde queda el repo privado (default ../workos-private)
#   WORKOS_TEMPLATE     template a usar (default OscarVargas97/workos-template)
set -euo pipefail

WORKOS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BASE=$(dirname "$WORKOS")
PRIV="${WORKOS_PRIVATE:-$BASE/workos-private}"
TEMPLATE="${WORKOS_TEMPLATE:-OscarVargas97/workos-template}"

yes_no() { # yes_no VAR "pregunta" s|n  -> 0 si sí (VAR por entorno = no pregunta)
  local a=${!1:-}
  [ -n "${!1+x}" ] || read -rp "$2 [$([ "$3" = s ] && echo S/n || echo s/N)] " a
  [[ "${a:-$3}" =~ ^[sSyY]$ ]]
}

echo "== workos: preparar tu repo privado"
echo "Este clon:    $WORKOS"
echo "Repo privado: $PRIV"
echo

# --- Requisitos ---------------------------------------------------------------
for c in git gh; do
  command -v "$c" >/dev/null || { echo "Falta '$c'. Ver README.md, sección 'Requisitos'." >&2; exit 1; }
done
if ! GH_USER=$(gh api user --jq .login 2>/dev/null); then
  echo "gh no tiene sesión iniciada: corré 'gh auth login' y volvé a correr esto." >&2
  exit 1
fi
command -v nix >/dev/null || command -v docker >/dev/null || command -v podman >/dev/null \
  || { echo "Hace falta nix, docker o podman para validar. Ver README.md, 'Requisitos'." >&2; exit 1; }
echo "GitHub: sesión de '$GH_USER' (para usar otra cuenta: gh auth switch)."
echo

# --- 1. Obtener el repo privado -----------------------------------------------
if [ -f "$PRIV/flake.nix" ]; then
  echo "--- 1/4 Ya existe $PRIV - se usa ese."
else
  echo "--- 1/4 Tu repo privado"
  mode=${WORKOS_REPO_MODE:-}
  if [ -z "$mode" ]; then
    echo "  1) Ya tengo uno (lo descargo)"
    echo "  2) Crear uno nuevo desde workos-template (queda privado)"
    read -rp "Opción [2]: " opt
    mode=$([ "${opt:-2}" = 1 ] && echo clone || echo create)
  fi
  repo=${WORKOS_REPO:-}
  if [ -z "$repo" ]; then
    [ "$mode" = create ] && echo "Dueño: tu usuario o una organización donde puedas crear repos."
    read -rp "Repo (dueño/nombre) [$GH_USER/workos-private]: " repo
  fi
  repo=${repo:-$GH_USER/workos-private}
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Repo inválido: '$repo' (dueño/nombre)." >&2; exit 1; }
  if [ "$mode" = clone ]; then
    gh repo clone "$repo" "$PRIV"
  elif [ "$mode" = create ]; then
    gh repo create "$repo" --private --template "$TEMPLATE" \
      --description "Instancia privada de workos"
    # GitHub llena el repo desde el template en segundo plano: un clone
    # inmediato puede bajarlo vacío.
    for _ in $(seq 1 20); do
      gh api "repos/$repo/contents/flake.nix" --silent 2>/dev/null && break
      sleep 2
    done
    gh repo clone "$repo" "$PRIV"
  else
    echo "WORKOS_REPO_MODE inválido: '$mode' (clone|create)." >&2; exit 1
  fi
  [ -f "$PRIV/flake.nix" ] || { echo "El repo no tiene flake.nix: ¿es un repo de workos?" >&2; exit 1; }
  echo "  OK: $PRIV"
fi
echo

# --- 2. Configurar -------------------------------------------------------------
echo "--- 2/4 Configuración"
if grep -q 'name = "user";' "$PRIV/identity.nix" 2>/dev/null; then
  echo "Todavía tiene los datos de ejemplo: arranca el configurador."
  "$PRIV/scripts/setup.sh"
elif yes_no WORKOS_RECONFIGURE "Ya está configurado. ¿Revisar/cambiar la configuración (usuario, máquinas, empresa)?" n; then
  "$PRIV/scripts/setup.sh"
fi
echo

# --- 3. Validar ----------------------------------------------------------------
echo "--- 3/4 Validación (evalúa cada máquina, no instala nada)"
if ! "$PRIV/scripts/check.sh"; then
  echo "Hay errores: corregilos en $PRIV y volvé a correr ./init.sh." >&2
  exit 1
fi
echo

# --- 4. Publicar ---------------------------------------------------------------
echo "--- 4/4 Publicar"
echo "La instalación descarga tu repo privado de GitHub: tiene que estar pusheado."
if yes_no WORKOS_PUBLISH "¿Fijar versiones (flake.lock), commitear y pushear ahora?" s; then
  "$PRIV/scripts/check.sh" --lock
  git -C "$PRIV" add -A
  if git -C "$PRIV" diff --cached --quiet; then
    echo "Sin cambios para commitear."
  else
    git -C "$PRIV" commit -q -m "Configuración de workos"
  fi
  git -C "$PRIV" push -q
  echo "  OK: publicado ($(git -C "$PRIV" remote get-url origin))"
fi
echo

echo "== Listo. Siguiente: instalar (README.md, sección 3.4):"
echo "  1. Bajá el ISO mínimo de NixOS a $BASE/iso/"
echo "  2. cd $WORKOS/work-os/scripts && make    (muestra los pasos en orden)"
