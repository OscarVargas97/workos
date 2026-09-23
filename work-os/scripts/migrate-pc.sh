#!/usr/bin/env bash
# Migra el ESTADO PERSONAL de esta máquina a otra ya instalada con
# workos (ej. la laptop nueva) - separado a propósito de
# nixos-anywhere-deploy.sh: ese instala el sistema base (declarado en
# Nix), este migra lo que nunca tendría sentido declarar en Nix -
# repos de trabajo reales, ~/.ssh, conexiones de DBeaver, perfil de
# Chrome (para importar a Brave) - datos/historial tuyo, no config del
# sistema.
#
# Ningún repo/ruta hardcodeada (regla general, DECISIONS.md): los repos
# se descubren igual que collect-configs.sh (Fase 4) - misma lista de
# exclusión, mismo find.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Perfil de esta máquina: scripts.env del repo privado (clon hermano,
# ../../../workos-private) o, si no hay, un .env local gitignoreado.
WORKOS_PRIVATE="${WORKOS_PRIVATE:-$(cd "$SCRIPT_DIR/../../.." && pwd)/workos-private}"
ENV_FILE="$WORKOS_PRIVATE/work-os/scripts.env"
[ -f "$ENV_FILE" ] || ENV_FILE="$SCRIPT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$ENV_FILE"
  set +a
fi

DEFAULT_SSH_KEY="$HOME/.ssh/id_ed25519"
if [ -z "${SSH_KEY:-}" ]; then
  read -rp "Ruta a tu clave SSH [$DEFAULT_SSH_KEY]: " SSH_KEY
  SSH_KEY="${SSH_KEY:-$DEFAULT_SSH_KEY}"
fi
[ -f "$SSH_KEY" ] || { echo "No encuentro '$SSH_KEY'." >&2; exit 1; }

if [ -z "${LOGIN_USER:-}" ]; then
  read -rp "Usuario en la máquina destino (workos.user.name del repo privado): " LOGIN_USER
fi
[ -z "$LOGIN_USER" ] && { echo "Falta el usuario." >&2; exit 1; }

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-find-host.sh"
if [ -z "${REMOTE_HOST:-}" ]; then
  while [ -z "${REMOTE_HOST:-}" ]; do
    echo "Buscando la máquina en la red (clave SSH de $LOGIN_USER)..."
    mapfile -t FOUND < <(find_installed_host)
    case "${#FOUND[@]}" in
      1) REMOTE_HOST="${FOUND[0]}"; echo "Encontrada: $REMOTE_HOST" ;;
      0) echo "No la encontré (¿sin red, o clave sin autorizar?)."
         read -rp "Enter para buscar de nuevo, o escribí la IP a mano: " REMOTE_HOST ;;
      *) echo "Hay más de una máquina que acepta esta clave para '$LOGIN_USER': ${FOUND[*]}"
         read -rp "¿Cuál es? " REMOTE_HOST ;;
    esac
  done
fi
[ -z "$REMOTE_HOST" ] && { echo "Falta el host." >&2; exit 1; }

TARGET="$LOGIN_USER@$REMOTE_HOST"
SSH_OPTS=(-o StrictHostKeyChecking=no -i "$SSH_KEY")

echo "=== Verificando acceso a $TARGET ==="
if ! ssh -n "${SSH_OPTS[@]}" -o BatchMode=yes "$TARGET" "echo ok" >/dev/null 2>&1; then
  echo "No se pudo conectar a $TARGET por SSH con esa clave." >&2
  exit 1
fi
echo "OK."
echo

rsync_to() {
  # $1 = origen local, $2 = destino relativo al home remoto, resto = --exclude extra
  local src="$1" dest="$2"
  shift 2
  rsync -az --info=progress2 -e "ssh -o StrictHostKeyChecking=no -i $SSH_KEY" "$@" "$src" "$TARGET:$dest"
}

echo "=== SSH: claves y config ==="
echo "Incluye lo que tengas ahí (claves de infra real si las tenés guardadas -"
echo "viaja por el mismo canal cifrado que ya usamos para vault/, entre tus"
echo "propias dos máquinas)."
if rsync_to "$HOME/.ssh/" ".ssh/" --exclude 'known_hosts*'; then
  ssh -n "${SSH_OPTS[@]}" "$TARGET" '
    chmod 700 ~/.ssh
    chmod 600 ~/.ssh/*.pem ~/.ssh/id_* 2>/dev/null
    chmod 644 ~/.ssh/*.pub ~/.ssh/config 2>/dev/null
    true
  '
  echo "OK."
else
  echo "Falló - revisar a mano." >&2
fi
echo

echo "=== Historial de shell (zsh) ==="
# home-manager/zsh.nix declara la RUTA (history.path), no el contenido -
# sin esto, la máquina nueva arranca con el historial vacío (bug real,
# encontrado auditando qué faltaba para el flujo diario).
ZSH_HISTORY="$HOME/.zsh_history"
if [ -f "$ZSH_HISTORY" ]; then
  rsync_to "$ZSH_HISTORY" ".zsh_history" \
    && echo "OK." || echo "Falló - revisar a mano." >&2
else
  echo "No encontré $ZSH_HISTORY en esta máquina - saltando." >&2
fi
echo

echo "=== CLI: gh / docker / aws (config y sesión de login, no solo el token) ==="
GH_CFG="$HOME/.config/gh"
if [ -d "$GH_CFG" ]; then
  ssh -n "${SSH_OPTS[@]}" "$TARGET" "mkdir -p ~/.config/gh"
  rsync_to "$GH_CFG/" ".config/gh/" \
    && echo "gh: OK." || echo "gh: falló - revisar a mano." >&2
else
  echo "No encontré $GH_CFG en esta máquina - saltando gh." >&2
fi

DOCKER_CFG="$HOME/.docker/config.json"
if [ -f "$DOCKER_CFG" ]; then
  ssh -n "${SSH_OPTS[@]}" "$TARGET" "mkdir -p ~/.docker"
  rsync_to "$DOCKER_CFG" ".docker/config.json" \
    && echo "docker: OK." || echo "docker: falló - revisar a mano." >&2
else
  echo "No encontré $DOCKER_CFG en esta máquina - saltando docker." >&2
fi

AWS_CFG="$HOME/.aws"
if [ -d "$AWS_CFG" ]; then
  ssh -n "${SSH_OPTS[@]}" "$TARGET" "mkdir -p ~/.aws"
  rsync_to "$AWS_CFG/" ".aws/" \
    && echo "aws: OK." || echo "aws: falló - revisar a mano." >&2
else
  echo "No encontré $AWS_CFG en esta máquina - saltando aws." >&2
fi
echo

echo "=== Claude Code: config, sesiones, memoria, plugins ==="
# Mismo criterio que .ssh de arriba (viaja por el mismo canal cifrado,
# entre tus propias dos máquinas) - incluye ~/.claude.json (cuenta/MCP)
# y ~/.claude/projects (que a su vez tiene la memoria de Claude, ver
# CLAUDE.md de ese sistema). Excluidos por ser específicos de ESTA
# máquina/sesión, no algo que tenga sentido llevar: shell-snapshots
# (entorno de shell de acá), paste-cache/cache (cachés), daemon
# (sockets/PIDs de un proceso que no corre en la máquina nueva),
# telemetry (ids locales).
CLAUDE_DIR="$HOME/.claude"
CLAUDE_JSON="$HOME/.claude.json"
if [ -d "$CLAUDE_DIR" ]; then
  ssh -n "${SSH_OPTS[@]}" "$TARGET" "mkdir -p ~/.claude"
  rsync_to "$CLAUDE_DIR/" ".claude/" \
    --exclude shell-snapshots --exclude paste-cache --exclude daemon \
    --exclude telemetry --exclude cache \
    && echo "~/.claude: OK." || echo "~/.claude: falló - revisar a mano." >&2
else
  echo "No encontré $CLAUDE_DIR en esta máquina - saltando." >&2
fi
if [ -f "$CLAUDE_JSON" ]; then
  rsync_to "$CLAUDE_JSON" ".claude.json" \
    && echo "~/.claude.json: OK." || echo "~/.claude.json: falló - revisar a mano." >&2
else
  echo "No encontré $CLAUDE_JSON en esta máquina - saltando." >&2
fi
echo

TARGET_USER="${TARGET%@*}"
REMOTE_PROJECTS=""
trap 'rm -f "${REMOTE_PROJECTS:-}"' EXIT

# Esta MISMA máquina ya puede estar organizada bajo ~/Repos/<Empresa>/ y
# ~/Repos/Externos/ (DECISIONS.md #14) - ej. migrando de una laptop ya migrada a una
# laptop nueva, no de la vieja Fedora desordenada. En ese caso no tiene
# sentido re-descubrir/re-clasificar repo por repo (eso ya se hizo la
# vez que se migró ACÁ) - alcanza con copiar ~/Repos tal cual, y fusionar
# el projects.conf local (que ya está bien armado) con el del destino.
# La rama de abajo (para el caso viejo, sin ~/Repos todavía) se mantiene
# para migrar por primera vez desde una máquina sin esta estructura.
if [ -d "$HOME/Repos" ]; then
  echo "=== Repos: ya organizados acá bajo ~/Repos/ - copiando tal cual ==="
  for group_dir in "$HOME"/Repos/*/; do
    group_name="$(basename "$group_dir")"
    # Externos/workos NO se copia acá - lo clona post-install-setup.sh
    # directo de GitHub (más liviano, sin historia de .git duplicada por
    # rsync) - solo faltan sus archivos gitignoreados (.env,
    # repo-companies.conf), que sí hay que copiar aparte a mano si esta
    # rama corrió (no lo hace sola, para no pisar un .env real del
    # destino sin querer).
    if [ "$group_name" = "Externos" ]; then
      ssh -n "${SSH_OPTS[@]}" "$TARGET" "mkdir -p ~/Repos/Externos"
      if rsync_to "$group_dir" "Repos/Externos/" \
        --exclude workos \
        --exclude node_modules --exclude .venv --exclude venv --exclude __pycache__ \
        --exclude dist --exclude build --exclude .next --exclude target; then
        echo "  Repos/Externos (menos workos): OK."
      else
        echo "  Repos/Externos: Falló - revisar a mano." >&2
      fi
      continue
    fi
    ssh -n "${SSH_OPTS[@]}" "$TARGET" "mkdir -p ~/Repos/$group_name"
    if rsync_to "$group_dir" "Repos/$group_name/" \
      --exclude node_modules --exclude .venv --exclude venv --exclude __pycache__ \
      --exclude dist --exclude build --exclude .next --exclude target; then
      echo "  Repos/$group_name: OK."
    else
      echo "  Repos/$group_name: Falló - revisar a mano." >&2
    fi
  done

  # workos: post-install-setup.sh ya clonó workos + workos-private vía
  # git en el destino - scripts.env y repo-companies.conf viven
  # versionados en workos-private (perfil de la máquina, privado), así
  # que viajan con ese clone, no hace falta copiarlos acá.
  echo
  echo "=== projects.conf: fusionando con el del destino ==="
  LOCAL_PROJECTS="$HOME/.config/work-os/projects.conf"
  if [ -f "$LOCAL_PROJECTS" ]; then
    ssh -n "${SSH_OPTS[@]}" "$TARGET" "mkdir -p ~/.config/work-os && touch ~/.config/work-os/projects.conf"
    REMOTE_PROJECTS="$(mktemp)"
    ssh -n "${SSH_OPTS[@]}" "$TARGET" "cat ~/.config/work-os/projects.conf" > "$REMOTE_PROJECTS"
    awk -F= 'NR==FNR{seen[$1]=1; next} !($1 in seen)' "$REMOTE_PROJECTS" "$LOCAL_PROJECTS" >> "$REMOTE_PROJECTS"
    if ssh "${SSH_OPTS[@]}" "$TARGET" "cat > ~/.config/work-os/projects.conf" < "$REMOTE_PROJECTS"; then
      echo "OK."
    else
      echo "Falló - revisar ~/.config/work-os/projects.conf a mano en el destino." >&2
    fi
  else
    echo "No encontré $LOCAL_PROJECTS - saltando." >&2
  fi
  echo

else
  echo "=== Repos reales: descubriendo (lib-repos.sh, misma lógica que map-repos.sh) ==="
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/lib-repos.sh"
  mapfile -t GIT_DIRS < <(discover_repos)

  # Estructura de destino (decisión explícita, DECISIONS.md #14):
  # Repos/<Empresa>/... para las de trabajo, Repos/Externos/... para las
  # personales/de terceros - no se preserva dónde estaba guardado en esta
  # máquina vieja. Se registra igual en projects.conf del destino.
  NEW_PROJECT_ENTRIES="$(mktemp)"
  trap 'rm -f "$NEW_PROJECT_ENTRIES" "${REMOTE_PROJECTS:-}"' EXIT

  if [ "${#GIT_DIRS[@]}" -eq 0 ]; then
    echo "No encontré ningún repo git bajo \$HOME (fuera de workos/)."
  else
    echo "Encontrados ${#GIT_DIRS[@]}:"
    printf '  %s\n' "${GIT_DIRS[@]}"
    echo
    read -rp "¿Migrar todos? [S/n] " CONFIRM_REPOS
    if [ "${CONFIRM_REPOS:-s}" != "n" ] && [ "${CONFIRM_REPOS:-s}" != "N" ]; then
      # Mapeo repo->empresa/destino (repo-companies.conf del privado): lo
      # que falte se pregunta una sola vez con map-repos.sh y queda
      # guardado para la próxima.
      "$SCRIPT_DIR/map-repos.sh"
      for repo in "${GIT_DIRS[@]}"; do
        rel="${repo#"$HOME"/}"
        echo "  -> $rel"
        dest="$(lookup_repo_dest "$rel")" || { echo "     sin mapeo - salteado." >&2; continue; }
        IFS='=' read -r empresa dest_name <<< "$dest"
        if [ -z "$dest_name" ]; then
          echo "     (sin destino - salteado a propósito)"
          continue
        fi
        dest_rel="$(repo_dest_path "$empresa" "$dest_name")"
        echo "     -> $dest_rel"
        ssh -n "${SSH_OPTS[@]}" "$TARGET" "mkdir -p ~/\"\$(dirname \"$dest_rel\")\""
        # Carpetas pesadas y 100% regenerables (npm install/pip install/
        # cargo build las recrean) - copiarlas solo haría más lenta la
        # migración sin preservar nada que valga la pena.
        if rsync_to "$repo/" "$dest_rel/" \
          --exclude node_modules --exclude .venv --exclude venv --exclude __pycache__ \
          --exclude dist --exclude build --exclude .next --exclude target; then
          echo "     OK."
          pname="${dest_name//\//-}"
          if [ -n "$empresa" ]; then
            printf '%s=/home/%s/%s=%s\n' "$pname" "$TARGET_USER" "$dest_rel" "$empresa" >> "$NEW_PROJECT_ENTRIES"
          else
            printf '%s=/home/%s/%s\n' "$pname" "$TARGET_USER" "$dest_rel" >> "$NEW_PROJECT_ENTRIES"
          fi
        else
          echo "     Falló '$dest_rel' - revisar a mano." >&2
        fi
      done
    fi
  fi
  echo

  echo "=== Carpetas de grupo: docs/Makefile/etc. sueltos ==="
  # Algunos proyectos no son un solo repo git - son carpetas que agrupan varios
  # repos hermanos (Front, backend, pipeline...) MÁS contenido suelto que
  # no es ningún repo en sí (docs/, Makefile, .gitignore, dev_iam.json) -
  # el descubrimiento de arriba solo encuentra ".git", así que esto se
  # perdía siempre (hallazgo real: comparando local vs migrado
  # faltaba "docs" en un proyecto). Acá se copia lo suelto de cada carpeta-grupo
  # detectada (cualquier dest_name con "/" en repo-companies.conf),
  # excluyendo los repos que ya se migraron uno por uno arriba.
  if [ -f "$REPO_COMPANIES_FILE" ]; then
    declare -A GROUP_SEEN
    while IFS='=' read -r rel empresa dest_name; do
      [[ -z "$rel" || "$rel" == \#* ]] && continue
      [[ "$dest_name" == */* ]] || continue
      group_local_rel="${rel%/*}"
      group_dest_name="${dest_name%/*}"
      group_key="$empresa|$group_local_rel"
      [ -n "${GROUP_SEEN[$group_key]:-}" ] && continue
      GROUP_SEEN[$group_key]=1
      group_local="$HOME/$group_local_rel"
      [ -d "$group_local" ] || continue
      group_remote="$(repo_dest_path "$empresa" "$group_dest_name")"
      exclude_args=()
      while IFS='=' read -r rel2 _ _; do
        [[ -z "$rel2" || "$rel2" == \#* ]] && continue
        [ "${rel2%/*}" = "$group_local_rel" ] && exclude_args+=(--exclude "${rel2##*/}")
      done < "$REPO_COMPANIES_FILE"
      echo "  -> $group_local_rel (suelto) -> $group_remote"
      if rsync_to "$group_local/" "$group_remote/" "${exclude_args[@]}" \
        --exclude node_modules --exclude .venv --exclude venv --exclude __pycache__; then
        echo "     OK."
      else
        echo "     Falló - revisar a mano." >&2
      fi
    done < "$REPO_COMPANIES_FILE"
  fi
  echo

  if [ -s "$NEW_PROJECT_ENTRIES" ]; then
    echo "=== Registrando en ~/.config/work-os/projects.conf del destino ==="
    ssh -n "${SSH_OPTS[@]}" "$TARGET" "mkdir -p ~/.config/work-os && touch ~/.config/work-os/projects.conf"
    REMOTE_PROJECTS="$(mktemp)"
    ssh -n "${SSH_OPTS[@]}" "$TARGET" "cat ~/.config/work-os/projects.conf" > "$REMOTE_PROJECTS"
    # Solo agrega los nombres que todavía no estén - no pisa nada que ya
    # hayas completado a mano en la máquina destino.
    awk -F= 'NR==FNR{seen[$1]=1; next} !($1 in seen)' "$REMOTE_PROJECTS" "$NEW_PROJECT_ENTRIES" >> "$REMOTE_PROJECTS"
    if ssh "${SSH_OPTS[@]}" "$TARGET" "cat > ~/.config/work-os/projects.conf" < "$REMOTE_PROJECTS"; then
      echo "OK."
    else
      echo "Falló - revisar ~/.config/work-os/projects.conf a mano en el destino." >&2
    fi
    echo
  fi
fi

echo "=== DBeaver: conexiones guardadas ==="
DBEAVER_CFG="$HOME/.local/share/DBeaverData/workspace6/General/.dbeaver"
if [ -d "$DBEAVER_CFG" ]; then
  ssh -n "${SSH_OPTS[@]}" "$TARGET" "mkdir -p ~/.local/share/DBeaverData/workspace6/General/.dbeaver"
  rsync_to "$DBEAVER_CFG/" ".local/share/DBeaverData/workspace6/General/.dbeaver/" \
    && echo "OK." || echo "Falló - revisar a mano." >&2
else
  echo "No encontré $DBEAVER_CFG en esta máquina - saltando." >&2
fi
echo

echo "=== Brave: perfil (historial, marcadores, contraseñas, etc.) ==="
# La importación Chrome->Brave se hizo ACÁ, en esta máquina (GUI de
# Brave: Configuración -> Importar marcadores y configuración -> Chrome
# - no hay forma de dispararla por CLI). Lo que se manda al destino ya
# es el perfil de Brave resultante, no el de Chrome (no se quiere
# Chrome en la máquina nueva). Brave nativo (rpm, no Flatpak) - el
# Flatpak corre en sandbox y no veía el perfil de Chrome para importar,
# por eso se usó el paquete nativo - misma ruta que el Brave de
# nixpkgs en el destino (home-manager/common.nix), no hace falta
# traducir nada.
BRAVE_CFG="$HOME/.config/BraveSoftware/Brave-Browser"
if [ -d "$BRAVE_CFG" ]; then
  ssh -n "${SSH_OPTS[@]}" "$TARGET" "mkdir -p ~/.config/BraveSoftware/Brave-Browser"
  rsync_to "$BRAVE_CFG/" ".config/BraveSoftware/Brave-Browser/" \
    && echo "OK." || echo "Falló - revisar a mano." >&2
else
  echo "No encontré $BRAVE_CFG en esta máquina - saltando (¿instalaste Brave" >&2
  echo "acá e importaste de Chrome? Ver README/instrucciones)." >&2
fi
echo

echo "=== Migración de PC lista (revisá los 'Falló' de arriba si hubo alguno) ==="
