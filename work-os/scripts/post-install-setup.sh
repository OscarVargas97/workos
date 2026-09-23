#!/usr/bin/env bash
# Post-instalación de una máquina ya instalada por nixos-anywhere-deploy.sh
# (separado a propósito de ese script - ese particiona y borra todo, este
# no toca el disco: si algún paso de acá queda pendiente o falla, se
# re-corre solo, las veces que haga falta, sin reinstalar nada).
#
# Los pasos que necesitan root (TPM2) corren en una sesión interactiva
# (ssh -t): sudo te pide la contraseña (y el código "sudo" si ya tenés
# TOTP), y systemd-cryptenroll la passphrase actual y el PIN nuevo, todo en
# tu terminal - nada de eso pasa por este script ni queda en un archivo.
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

# Puerto SSH de la máquina nueva: 22, u otro a través de un reenvío de
# puertos (ej. la VM de prueba de tests/e2e-install.sh).
SSH_PORT="${SSH_PORT:-22}"
ssh() { command ssh -p "$SSH_PORT" "$@"; }

DEFAULT_SSH_KEY="$HOME/.ssh/id_ed25519"
if [ -z "${SSH_KEY:-}" ]; then
  read -rp "Ruta a tu clave privada SSH [$DEFAULT_SSH_KEY]: " SSH_KEY
  SSH_KEY="${SSH_KEY:-$DEFAULT_SSH_KEY}"
fi
[ -f "$SSH_KEY" ] || { echo "No encuentro '$SSH_KEY'." >&2; exit 1; }

if [ -z "${LOGIN_USER:-}" ]; then
  read -rp "Usuario del sistema ya instalado (workos.user.name del repo privado): " LOGIN_USER
fi
[ -z "$LOGIN_USER" ] && { echo "Falta el usuario." >&2; exit 1; }

# Busca la máquina sola en la red (lib-find-host.sh, compartida con
# migrate-pc.sh): puerto 22 abierto + esta clave funciona para
# $LOGIN_USER - no hace falta saber/tipear la IP, que puede ser
# distinta a la que tenía el live-USB.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-find-host.sh"

if [ -z "${REMOTE_HOST:-}" ]; then
  while [ -z "${REMOTE_HOST:-}" ]; do
    echo "Buscando la máquina en la red (clave SSH de $LOGIN_USER)..."
    mapfile -t FOUND < <(find_installed_host)
    case "${#FOUND[@]}" in
      1) REMOTE_HOST="${FOUND[0]}"; echo "Encontrada: $REMOTE_HOST" ;;
      0) echo "No la encontré (¿todavía arrancando, sin red, o falta tipear la passphrase de disco en la consola?)."
         read -rp "Enter para buscar de nuevo, o escribí la IP a mano: " REMOTE_HOST ;;
      *) echo "Hay más de una máquina que acepta esta clave para '$LOGIN_USER': ${FOUND[*]}"
         read -rp "¿Cuál es? " REMOTE_HOST ;;
    esac
  done
fi
[ -z "$REMOTE_HOST" ] && { echo "Falta el host." >&2; exit 1; }
ssh-keygen -R "$REMOTE_HOST" >/dev/null 2>&1 || true

NEW_TARGET="$LOGIN_USER@$REMOTE_HOST"

echo "=== Verificando acceso a $NEW_TARGET ==="
until ssh -n -o ConnectTimeout=4 -o StrictHostKeyChecking=no -o BatchMode=yes -i "$SSH_KEY" "$NEW_TARGET" "echo ok" >/dev/null 2>&1; do
  echo "Todavía no responde (¿esperando el primer arranque, o falta tipear la passphrase de disco en la consola?). Reintentando en 5s..."
  sleep 5
done
echo "OK."
echo

run_remote() {
  # -n: sin esto, ssh consume/descarta en silencio bytes del stdin REAL
  # de este script (no del remoto) aunque el comando remoto no lea nada -
  # bug real, encontrado acá (se comía la respuesta pensada para un
  # 'read' posterior, dejándolo sin nada que leer). Mismo bug ya
  # encontrado y arreglado antes en migrate-pc.sh.
  ssh -n -o StrictHostKeyChecking=no -i "$SSH_KEY" "$NEW_TARGET" "$@"
}
# Variante SIN -n, solo para los pocos casos que de verdad necesitan
# pipear algo (el token de gh) -
# nunca se llama sin un pipe real adelante.
run_remote_stdin() {
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$NEW_TARGET" "$@"
}
# Sesión interactiva (terminal real) para lo que pide datos por consola.
run_remote_tty() {
  ssh -t -o StrictHostKeyChecking=no -i "$SSH_KEY" "$NEW_TARGET" "$@"
}

echo "=== Disco: TPM2 + PIN ==="
echo "El disco se desbloquea con el chip TPM2 de ESTA máquina + un PIN corto"
echo "que tipeás al encender (sin PIN, alguien con acceso físico puede sacarle"
echo "la clave al TPM). Vas a escribir: tu contraseña (sudo), la passphrase"
echo "actual del disco y el PIN nuevo dos veces. La passphrase sigue sirviendo"
echo "como recuperación: guardala en Bitwarden."
ROOT_PART="$(run_remote "readlink -f /dev/disk/by-partlabel/disk-main-root" 2>/dev/null || true)"
if [ -z "$ROOT_PART" ]; then
  echo "No pude resolver la partición root - TPM2 sin enrolar, revisar a mano." >&2
else
  # PCR 7 (política de Secure Boot) y no 0+7: con PIN la protección real es
  # el PIN (el TPM limita los intentos); atarlo también al código del
  # firmware (PCR 0) solo obliga a re-enrolar en cada actualización de BIOS.
  # --wipe-slot=tpm2 reemplaza un enrolamiento viejo sin PIN. El PIN se
  # detecta en el JSON de LUKS (luksDump normal no lo muestra si cryptsetup
  # no carga el plugin de tokens de systemd).
  run_remote_tty "sudo sh -c 'if cryptsetup luksDump --dump-json-metadata $ROOT_PART | grep -Eq \"\\\"tpm2-pin\\\": ?true\"; then echo \"Ya tiene TPM2 + PIN, salteo.\"; else systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-with-pin=yes --tpm2-pcrs=7 $ROOT_PART; fi'" \
    && echo "OK: el próximo arranque pide el PIN." \
    || echo "Falló el enrolamiento - revisar a mano (¿TPM habilitado en el BIOS?). Se puede re-correr este script." >&2
fi
echo

echo "=== GitHub: gh auth con el token de esta máquina ==="
if run_remote "gh auth status" >/dev/null 2>&1; then
  echo "Ya está logueado, salteo."
else
  # Sin 'gh auth setup-git' a propósito: intenta escribir
  # ~/.config/git/config, pero home-manager lo genera de solo lectura
  # (symlink al store) - falla siempre con "Read-only file system" (bug
  # real, encontrado instalando la laptop real). El clone de abajo usa
  # 'gh repo clone' en vez de 'git clone' por eso mismo (se autentica
  # con el token de gh directo, no necesita el credential helper de
  # git) - y home-manager/common.nix ya declara ese mismo helper para
  # el uso diario de git, así que no hace falta configurarlo acá.
  gh auth token | run_remote_stdin "gh auth login --with-token" \
    && echo "OK." || echo "Falló gh auth - revisar a mano (gh auth login en $NEW_TARGET)." >&2
fi
echo


# Repos a clonar: este público (módulos) y el privado (flake de entrada,
# identidad, hosts, instancias de company-context) - ambos salen de los
# checkouts locales desde los que se corre este script.
PUB_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Sin origin (un checkout de prueba) no hay de dónde clonar: se saltea.
PUB_REPO="$(git -C "$PUB_DIR" remote get-url origin 2>/dev/null | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##' || true)"
PRIV_REPO="$(git -C "$WORKOS_PRIVATE" remote get-url origin 2>/dev/null | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##' || true)"

# Empresa configurable a propósito (DECISIONS.md #11: uso personal
# multi-empresa por naturaleza) - este script no asume ninguna empresa
# fija. Su company-context vive en el repo privado, companies/<empresa>/.
if [ -z "${COMPANY_NAME:-}" ]; then
  read -rp "Nombre de la empresa (clave para companies.conf, carpeta companies/<empresa> del repo privado): " COMPANY_NAME
fi
[ -z "$COMPANY_NAME" ] && { echo "Falta el nombre de la empresa." >&2; exit 1; }

echo "=== Clonando workos (público) y workos-private ==="
# ~/Repos/Externos/workos - proyecto personal, clasifica como "externo"
# con el mismo criterio que el resto de Repos/ (DECISIONS.md #14).
run_remote "mkdir -p ~/Repos/Externos/workos && cd ~/Repos/Externos/workos && \
  { [ -d workos ] || [ -z '$PUB_REPO' ] || gh repo clone $PUB_REPO workos; } && \
  { [ -d workos-private ] || [ -z '$PRIV_REPO' ] || gh repo clone $PRIV_REPO workos-private; }" \
  && echo "OK." || echo "Falló el clone - revisar a mano." >&2
echo

echo "=== Copiando vault.enc (cifrado; puede tardar si tiene dumps) ==="
# Solo viaja la versión cifrada (vault.sh, DECISIONS.md #15): en la
# máquina nueva se abre con 'work vault open' (clave en Bitwarden).
VAULT_ENC="$PUB_DIR/../vault.enc"
if [ -f "$VAULT_ENC/gocryptfs.conf" ]; then
  rsync -az --info=progress2 -e "ssh -p $SSH_PORT -o StrictHostKeyChecking=no -i $SSH_KEY" \
    "$VAULT_ENC/" "$NEW_TARGET:Repos/Externos/workos/vault.enc/" \
    && echo "OK." || echo "Falló el rsync de vault.enc - reintentar a mano después." >&2
elif [ -n "$(ls -A "$PUB_DIR/../vault" 2>/dev/null)" ]; then
  echo "Hay un vault EN CLARO en $PUB_DIR/../vault y no lo copio así." >&2
  echo "Cifralo primero: $SCRIPT_DIR/vault.sh import $PUB_DIR/../vault  (y volvé a correr esto)." >&2
else
  echo "No hay vault en esta máquina - saltando."
fi
echo

echo "=== work-os: companies.conf / projects.conf ==="
run_remote "mkdir -p ~/.config/work-os && \
  { [ -f ~/.config/work-os/companies.conf ] || echo '$COMPANY_NAME=/home/$LOGIN_USER/Repos/Externos/workos/workos-private/companies/$COMPANY_NAME' > ~/.config/work-os/companies.conf; } && \
  { [ -f ~/.config/work-os/projects.conf ] || cp ~/Repos/Externos/workos/workos/work-os/cli/projects.conf.example ~/.config/work-os/projects.conf; }" \
  && echo "companies.conf listo (si ya existía, no lo pisé). Completá projects.conf a mano con tus proyectos reales." \
  || echo "Falló - revisar a mano." >&2
echo

# Twingate solo si el repo privado lo instala (VPN de una empresa puntual).
if run_remote "command -v twingate" >/dev/null 2>&1; then
  echo "=== Twingate (necesita que autorices en el navegador) ==="
  ssh -t -o StrictHostKeyChecking=no -i "$SSH_KEY" "$NEW_TARGET" "sudo twingate setup" \
    || echo "Twingate quedó pendiente - correlo a mano con 'sudo twingate setup'." >&2
  echo
fi

echo "=== Códigos TOTP (bloqueo de pantalla y sudo) ==="
if run_remote "command -v workos-totp-setup" >/dev/null 2>&1; then
  echo "Necesitás el teléfono con una app de códigos (Aegis, Google Authenticator...)."
  run_remote_tty workos-totp-setup || echo "Quedó pendiente - correlo en la máquina nueva: workos-totp-setup" >&2
else
  echo "workos.security.totp no está activado en este host - salteo."
fi
echo

# Moonlight ("pc", si el repo privado lo instala): las llaves del
# emparejamiento se generan al emparejar y el PIN se confirma en el PC
# que transmite (Sunshine), así que no se puede declarar en Nix ni
# automatizar desde acá.
if run_remote "command -v pc" >/dev/null 2>&1; then
  echo "=== Pantalla extendida del PC (Moonlight/'pc') - opcional, una sola vez ==="
  echo "Con Sunshine corriendo en el PC que transmite:"
  echo "  1. En la máquina nueva: pc pair 1234 <ip-del-pc>"
  echo "  2. En el PC: https://localhost:47990 -> pestaña PIN -> 1234"
  echo "Después: pc (abrir), pc full (pantalla completa on/off), pc off (cerrar)."
  echo
fi

echo "=== Bitwarden - esto NUNCA se automatiza (tu contraseña maestra, la IA no la maneja) ==="
echo "Conectate y corré vos mismo:"
echo "  ssh $NEW_TARGET"
echo "  rbw config set email ${RBW_EMAIL:-<tu-email>} && rbw login"
echo
echo "=== Todo listo (revisá los 'Falló'/'pendiente' de arriba si hubo alguno) ==="
echo "Después falta migrate-pc.sh (aparte) para traer tus repos/ssh/config"
echo "personales - eso no lo toca este script."
