#!/usr/bin/env bash
# Instala NixOS en una máquina nueva de punta a punta: verifica el acceso
# (la clave SSH ya viene autorizada para root en el pendrive, ver
# prepare-installer-usb.sh — no hace falta passwd/ssh-copy-id) y corre
# nixos-anywhere desde un contenedor Docker efímero con Nix (no instala
# nada en este equipo).
# El SISTEMA se instala directo desde GitHub (github:<repo-privado>#host):
# no se monta ningún checkout local para esa parte ni para la máquina
# destino — pusheá tus cambios antes de correr esto. La ÚNICA excepción es
# hosts/<host>/hardware-configuration.nix: nixos-anywhere lo regenera contra
# el hardware real de la máquina destino en cada corrida (nunca se asume
# el de una corrida anterior) y lo escribe en el checkout local, montado
# solo para ese paso puntual - después se commitea/pushea y recién ahí
# arranca la instalación real, ya 100% desde GitHub.
#
# Requiere el pendrive creado con prepare-installer-usb.sh /dev/sdX
# (graba el ISO oficial de ~/Repos/Externos/workos/iso/ y autoriza tu clave), arrancando
# en modo UEFI.
#
# Uso: nixos-anywhere-deploy.sh [--yes]
#   --yes   salta la confirmación antes de particionar (para scripts propios,
#           nunca la usa un agente sin que vos lo hayas tipeado).
set -euo pipefail

SKIP_CONFIRM=false
[ "${1:-}" = "--yes" ] && SKIP_CONFIRM=true

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

echo "Este script instala NixOS de punta a punta en una máquina nueva:"
echo "verifica el acceso por SSH al pendrive y corre nixos-anywhere desde"
echo "un contenedor Docker efímero (no instala nada en este equipo). Nada"
echo "de esto tiene datos tuyos fijos — todo lo pide acá, en cada corrida."
echo

echo "=== Paso 1: en la máquina destino ==="
echo "Booteá en modo UEFI desde el pendrive preparado con"
echo "prepare-installer-usb.sh (tu clave ya viene autorizada para root)"
echo "y dale red: cable al mismo router que este equipo, o 'nmtui' en su"
echo "consola si es wifi. Nada más: el pendrive se busca solo en la red."
echo

DEFAULT_USER="root"
read -rp "Usuario del live en el destino [$DEFAULT_USER]: " REMOTE_USER
REMOTE_USER="${REMOTE_USER:-$DEFAULT_USER}"

# Puerto SSH del destino: 22, u otro para instalar a través de un reenvío
# de puertos (ej. la VM de prueba de tests/e2e-install.sh). Las funciones
# lo aplican a todo ssh/scp de este script.
SSH_PORT="${SSH_PORT:-22}"
ssh() { command ssh -p "$SSH_PORT" "$@"; }
scp() { command scp -P "$SSH_PORT" "$@"; }

DEFAULT_SSH_KEY="$HOME/.ssh/id_ed25519"
if [ -z "${SSH_KEY:-}" ]; then
  read -rp "Ruta a tu clave privada SSH [$DEFAULT_SSH_KEY]: " SSH_KEY
  SSH_KEY="${SSH_KEY:-$DEFAULT_SSH_KEY}"
fi
if [ ! -f "$SSH_KEY" ]; then
  echo "No encuentro '$SSH_KEY'. Generá un par con 'ssh-keygen' o revisá la ruta." >&2
  exit 1
fi

# Busca el pendrive en las redes /24 de este equipo: primero quién tiene
# el puerto 22 abierto (bash puro, sin nmap), después a cuál se entra con
# tu clave y arrancó con la credencial que inyecta prepare-installer-usb.sh
# (así no se confunde con otra máquina donde tu clave también sirva).
# ponytail: solo redes /24 locales; en otra subred, se pide la IP a mano.
find_installer() {
  local net i h
  for net in $(ip -4 -o addr show scope global | awk '{print $4}' | grep '/24$' | cut -d. -f1-3); do
    for i in $(seq 1 254); do
      ( timeout 1 bash -c "echo >/dev/tcp/$net.$i/22" 2>/dev/null && echo "$net.$i" ) &
    done
  done | sort -u | while read -r h; do
    ssh -n -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i "$SSH_KEY" "$REMOTE_USER@$h" \
      'grep -q ssh.authorized_keys.root /proc/cmdline' 2>/dev/null && echo "$h"
  done
}

REMOTE_HOST="${REMOTE_HOST:-}"
while [ -z "$REMOTE_HOST" ]; do
  echo "Buscando el pendrive en la red..."
  mapfile -t FOUND < <(find_installer)
  case "${#FOUND[@]}" in
    1) REMOTE_HOST="${FOUND[0]}"; echo "Encontrado: $REMOTE_HOST" ;;
    0) echo "No lo encontré (¿sin red todavía, booteó en BIOS en vez de UEFI, o está en otra subred?)."
       read -rp "Enter para buscar de nuevo, o escribí su IP: " REMOTE_HOST ;;
    *) echo "Hay más de un pendrive en la red: ${FOUND[*]}"
       read -rp "IP del que querés instalar: " REMOTE_HOST ;;
  esac
done
ssh-keygen -R "$REMOTE_HOST" >/dev/null 2>&1 || true

TARGET="$REMOTE_USER@$REMOTE_HOST"

echo
echo "=== Paso 2: verificando acceso por clave y sudo sin contraseña ==="
if ! ssh -n -o StrictHostKeyChecking=no -o BatchMode=yes -i "$SSH_KEY" "$TARGET" "sudo -n true" 2>/dev/null; then
  echo "No se pudo confirmar login por clave + sudo sin contraseña." >&2
  echo "¿El pendrive pasó por prepare-installer-usb.sh con esta clave, y booteó en UEFI (no BIOS)?" >&2
  exit 1
fi
echo "OK."
echo

# Las configs (hosts) salen del flake.nix del repo privado (el flake de
# entrada, que importa este repo público como input). Por defecto se instala
# la versión que está en GitHub (pusheá antes). INSTALL_FROM=local instala
# los checkouts locales tal cual (el privado y este workos, sin pushear):
# para probar cambios antes de publicarlos (tests/e2e-install.sh).
REPO_DIR="$(cd "$WORKOS_PRIVATE" && pwd)"
PUB_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_FROM="${INSTALL_FROM:-github}"
mapfile -t HOSTS < <(grep -oE 'nixosConfigurations\.[A-Za-z0-9_-]+' "$REPO_DIR/flake.nix" | cut -d. -f2)
[ "${#HOSTS[@]}" -gt 0 ] || { echo "No encontré nixosConfigurations en $REPO_DIR/flake.nix." >&2; exit 1; }
if [ "$INSTALL_FROM" = local ]; then
  SOURCE_DESC="checkouts locales $REPO_DIR + $PUB_DIR"
else
  REPO="$(git -C "$REPO_DIR" remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"
  SOURCE_DESC="github:$REPO"
fi
echo "¿Qué config instalar en $REMOTE_HOST? (de $SOURCE_DESC)"
select HOST in "${HOSTS[@]}"; do [ -n "$HOST" ] && break; done
# En modo local, dentro del contenedor se arma una copia del privado con
# su input "workos" apuntando al checkout local (el flake.lock real del
# privado no se toca).
if [ "$INSTALL_FROM" = local ]; then
  FLAKE_REF="/tmp/priv#$HOST"
  PREP='cp -r /repo /tmp/priv && rm -rf /tmp/priv/.git && nix --extra-experimental-features "nix-command flakes" flake lock /tmp/priv --override-input workos path:/workos &&'
else
  FLAKE_REF="github:$REPO#$HOST"
  PREP=''
fi
echo "Config: $FLAKE_REF"

# El hardware NUNCA se asume de una corrida anterior: un host
# puede terminar en una máquina física distinta a la que
# generó su hardware-configuration.nix la última vez (nos pasó: la config
# original de un host era de una laptop AMD, la máquina real
# terminó siendo una Intel). nixos-anywhere ya trae esto resuelto
# (--generate-hardware-config): kexecea al instalador, corre
# nixos-generate-config AHÍ (nunca a mano por SSH aparte) y escribe el
# resultado en el checkout local - fase "kexec" sola, sin tocar disco
# (disko/install/reboot quedan para el Paso 4 real, más abajo).
echo
echo "=== Generando hardware-configuration.nix real de $REMOTE_HOST ==="
HW_FILE="hosts/$HOST/hardware-configuration.nix"
GH_TOKEN_FILE="$(mktemp)"
chmod 600 "$GH_TOKEN_FILE"
trap 'rm -f "$GH_TOKEN_FILE"' EXIT
echo "GH_TOKEN=$(gh auth token 2>/dev/null || true)" > "$GH_TOKEN_FILE"
# "|| true": Docker real es idempotente acá (no falla si ya existe), pero
# 'docker' en este sistema es el alias a podman (dockerCompat,
# home-manager/common.nix) - podman SÍ falla con "already exists" en un
# volume creado por una corrida anterior (bug real, encontrado
# reintentando este mismo script).
docker volume create nix-store-cache >/dev/null 2>&1 || true
docker volume create nix-cache-home >/dev/null 2>&1 || true
docker run --rm --network host \
  --env-file "$GH_TOKEN_FILE" \
  -v "$SSH_KEY:/keys/id:ro" \
  -v "$REPO_DIR:/repo" \
  -v "$PUB_DIR:/workos:ro" \
  -v nix-store-cache:/nix \
  -v nix-cache-home:/root/.cache \
  nixos/nix \
  sh -c '
    mkdir -p /root/.ssh && cp /keys/id /root/.ssh/id && chmod 600 /root/.ssh/id &&
    export NIX_CONFIG="tarball-ttl = 0
access-tokens = github.com=$GH_TOKEN"
    '"$PREP"'
    nix run --extra-experimental-features "nix-command flakes" \
      github:nix-community/nixos-anywhere -- \
      --flake "'"$([ "$INSTALL_FROM" = local ] && echo /tmp/priv || echo /repo)"'#'"$HOST"'" \
      --generate-hardware-config nixos-generate-config "/repo/'"$HW_FILE"'" \
      --phases kexec \
      -i /root/.ssh/id \
      --ssh-option "StrictHostKeyChecking=no" --ssh-port "'"$SSH_PORT"'" \
      "'"$TARGET"'"
  '

if git -C "$REPO_DIR" diff --quiet -- "$HW_FILE" && git -C "$REPO_DIR" diff --cached --quiet -- "$HW_FILE"; then
  echo "Hardware sin cambios respecto al commit actual - no hace falta commitear."
else
  echo
  echo "=== Diff de $HW_FILE ==="
  git -C "$REPO_DIR" diff -- "$HW_FILE"
  echo
  if $SKIP_CONFIRM; then
    CONFIRM_HW=si
  else
    read -rp "Escribí 'si' para commitear y pushear este hardware-configuration.nix: " CONFIRM_HW
  fi
  if [ "$CONFIRM_HW" = "si" ]; then
    git -C "$REPO_DIR" add "$HW_FILE"
    git -C "$REPO_DIR" commit -m "hosts/$HOST: hardware-configuration.nix real (auto, nixos-anywhere-deploy.sh)"
    git -C "$REPO_DIR" push
  else
    echo "Cancelado - seguís con el hardware-configuration.nix anterior (puede no coincidir con esta máquina)." >&2
  fi
fi
echo

echo
echo "El usuario del sistema (workos.user.name) necesita una contraseña de"
echo "login para entrar por greetd/tuigreet y para sudo — si no se la fijamos"
echo "acá, queda bloqueado sin forma de loguearse ni de hacer sudo."
if [ -z "${LOGIN_USER:-}" ]; then
  read -rp "Usuario del sistema al que fijarle contraseña (el mismo de workos.user.name en el repo privado): " LOGIN_USER
fi
[ -z "$LOGIN_USER" ] && { echo "Falta el usuario de login." >&2; exit 1; }
if [ -z "${LOGIN_PASSWORD:-}" ]; then
  read -rsp "Contraseña de login para $LOGIN_USER (la vas a poder cambiar después con 'passwd'): " LOGIN_PASSWORD
  echo
fi
[ -z "$LOGIN_PASSWORD" ] && { echo "Falta la contraseña de login." >&2; exit 1; }

if ! command -v mkpasswd >/dev/null; then
  echo "Falta 'mkpasswd' en este equipo (paquete 'whois' o similar) para hashear la contraseña." >&2
  exit 1
fi
# El paquete 'expect' trae OTRO mkpasswd (genera contraseñas, otras
# opciones): si ese queda primero en el PATH, el hash fallaba en silencio.
if ! echo x | mkpasswd -m sha-512 --stdin >/dev/null 2>&1; then
  echo "El 'mkpasswd' de este equipo ($(command -v mkpasswd)) no es el de 'whois' (¿el de 'expect'?)." >&2
  echo "Poné el de whois primero en el PATH y volvé a correr esto." >&2
  exit 1
fi

echo
echo "=== Cifrado de disco (LUKS) ==="
echo "El disco queda cifrado - sin esto, perder la máquina expone todo en"
echo "texto plano sin necesitar ni la contraseña del sistema (hallazgo de"
echo "la auditoría de seguridad, hosts/vm/disko-config.nix)."
echo "Esta passphrase la vas a tener que tipear en CADA arranque (como"
echo "FileVault/BitLocker) - a propósito no queda guardada en ningún lado,"
echo "ni acá ni en el disco: si la perdés, el contenido es irrecuperable."
echo "Guardala vos en un gestor de contraseñas."
if [ -z "${DISK_PASSPHRASE:-}" ]; then
  read -rsp "Passphrase de cifrado de disco: " DISK_PASSPHRASE
  echo
  read -rsp "Repetila: " DISK_PASSPHRASE_CONFIRM
  echo
  [ "$DISK_PASSPHRASE" = "$DISK_PASSPHRASE_CONFIRM" ] || { echo "No coinciden." >&2; exit 1; }
  unset DISK_PASSPHRASE_CONFIRM
fi
[ -z "$DISK_PASSPHRASE" ] && { echo "Falta la passphrase de disco." >&2; exit 1; }
echo

EXTRA_FILES_DIR="$(mktemp -d)"
# El trap de limpieza se registra más abajo (junto con GH_TOKEN_FILE) -
# "trap ... EXIT" reemplaza cualquier trap anterior, no se acumulan.
mkdir -p "$EXTRA_FILES_DIR/etc/secrets"
PASSWORD_HASH_PATH="$EXTRA_FILES_DIR/etc/secrets/${LOGIN_USER}-password-hash"
# --stdin (no la contraseña como argumento) - un argumento de proceso es
# visible para cualquier otro proceso/usuario de esta máquina que pueda
# leer /proc/<pid>/cmdline mientras corre; por stdin no queda ahí.
mkpasswd -m sha-512 --stdin <<< "$LOGIN_PASSWORD" > "$PASSWORD_HASH_PATH"
chmod 600 "$PASSWORD_HASH_PATH"
unset LOGIN_PASSWORD
echo "modules/workos.nix ya lo declara para workos.user.name = \"$LOGIN_USER\":"
echo "  users.users.$LOGIN_USER.hashedPasswordFile = \"/etc/secrets/$LOGIN_USER-password-hash\";"
echo

# Wifi (pendiente real, sin resolver en Nix): nmtui en la consola del
# live guarda los perfiles en /etc/NetworkManager/system-connections/,
# pero eso vive en el live, no pasa solo al sistema instalado - sin
# esto, arranca sin wifi y hay que repetir nmtui a mano. Se copia ahora,
# mientras el live sigue arriba, al mismo --extra-files de la contraseña.
echo "=== Wifi: copiando perfiles de NetworkManager del live (si hay) ==="
mkdir -p "$EXTRA_FILES_DIR/etc/NetworkManager/system-connections"
if ssh -n -o StrictHostKeyChecking=no -o BatchMode=yes -i "$SSH_KEY" "$TARGET" \
  'ls /etc/NetworkManager/system-connections/*.nmconnection' >/dev/null 2>&1; then
  scp -q -o StrictHostKeyChecking=no -i "$SSH_KEY" \
    "$TARGET:/etc/NetworkManager/system-connections/*.nmconnection" \
    "$EXTRA_FILES_DIR/etc/NetworkManager/system-connections/" 2>/dev/null \
    && chmod 600 "$EXTRA_FILES_DIR"/etc/NetworkManager/system-connections/*.nmconnection \
    && echo "Copiados (NetworkManager exige 600, ya seteado)." \
    || echo "No se pudieron copiar - revisar wifi a mano después de instalar." >&2
else
  echo "No hay perfiles guardados en el live (¿usaste 'nmtui'? si es cable, ignorá esto)."
fi
echo

if ! $SKIP_CONFIRM; then
  echo
  echo "=== Esto va a particionar y reinstalar $TARGET — borra todo lo que tenga ==="
  read -rp "Escribí 'si' para confirmar: " CONFIRM
  [ "$CONFIRM" = "si" ] || { echo "Cancelado."; exit 1; }
fi

docker volume create nix-store-cache >/dev/null 2>&1 || true
docker volume create nix-cache-home >/dev/null 2>&1 || true

echo
echo "=== Paso 4: instalando con nixos-anywhere ==="
# tarball-ttl=0: el volumen nix-store-cache persiste entre corridas, y sin
# esto un 'github:...' sin pinnear puede quedar cacheado hasta 1h y traer
# un commit viejo (nos pasó). Mismo motivo para usar --refresh en un
# 'nixos-rebuild switch --flake github:...' hecho a mano poco después de
# pushear.
# El token va en un env-file temporal aparte (NO dentro de
# EXTRA_FILES_DIR: nixos-anywhere copia TODO lo que hay ahí adentro al
# filesystem de la máquina destino - si el token quedara ahí, terminaría
# escrito en el disco de la VM recién instalada). 0600, con su propio
# trap de borrado. Tampoco "-e GH_TOKEN=..." de docker run - un "-e"
# queda visible en el argv del proceso docker en ESTE host (ps aux),
# un --env-file no.
# GH_TOKEN_FILE ya existe (creado más arriba, para generar el hardware-
# configuration.nix) - se reusa, mismo contenido.
# Passphrase de disco: mismo criterio que GH_TOKEN_FILE - un archivo
# aparte, NUNCA dentro de EXTRA_FILES_DIR (eso se copia entero al disco
# de la máquina destino). nixos-anywhere la sube temporalmente al
# entorno del instalador remoto vía --disk-encryption-keys, y ahí es
# donde disko la lee UNA sola vez para formatear con LUKS - no queda
# guardada en la máquina instalada (ver disko-config.nix, sin keyFile
# a propósito).
DISK_PASSPHRASE_FILE="$(mktemp)"
trap 'rm -f "$GH_TOKEN_FILE" "$DISK_PASSPHRASE_FILE"; rm -rf "$EXTRA_FILES_DIR"' EXIT
chmod 600 "$DISK_PASSPHRASE_FILE"
printf '%s' "$DISK_PASSPHRASE" > "$DISK_PASSPHRASE_FILE"
unset DISK_PASSPHRASE

docker run --rm --network host \
  --env-file "$GH_TOKEN_FILE" \
  -e TARGET="$TARGET" \
  -e FLAKE_REF="$FLAKE_REF" \
  -e SSH_PORT="$SSH_PORT" \
  -e PREP="$PREP" \
  -v "$SSH_KEY:/keys/id:ro" \
  -v "$REPO_DIR:/repo:ro" \
  -v "$PUB_DIR:/workos:ro" \
  -v "$EXTRA_FILES_DIR:/extra-files:ro" \
  -v "$DISK_PASSPHRASE_FILE:/keys/disk-passphrase:ro" \
  -v nix-store-cache:/nix \
  -v nix-cache-home:/root/.cache \
  nixos/nix \
  sh -c '
    mkdir -p /root/.ssh && cp /keys/id /root/.ssh/id && chmod 600 /root/.ssh/id &&
    # NIX_CONFIG (variable de entorno, no --option): nixos-anywhere invoca
    # sus propios "nix build"/"nix copy" como subprocesos para bajar
    # $FLAKE_REF (nuestro repo, privado) - un --option solo aplica al
    # comando de nix al que se le pasa directo (acá, el que baja
    # nixos-anywhere en sí, que es público y no lo necesita), nunca se
    # hereda por subprocesos. Una env var sí se hereda - por eso el token
    # tiene que ir acá adentro, no como --option del "nix run" de abajo
    # (hallazgo real: sin esto, nixos-anywhere fallaba con 404 al bajar
    # el tarball del repo privado, un 404 en vez de 403 porque GitHub
    # oculta la existencia de repos privados a quien no tiene acceso).
    export NIX_CONFIG="tarball-ttl = 0
access-tokens = github.com=$GH_TOKEN"
    eval "$PREP" true &&
    nix run --extra-experimental-features "nix-command flakes" \
      github:nix-community/nixos-anywhere -- \
      --flake "$FLAKE_REF" \
      --extra-files /extra-files \
      --disk-encryption-keys /tmp/disko-password /keys/disk-passphrase \
      -i /root/.ssh/id \
      --ssh-option "StrictHostKeyChecking=no" --ssh-port "$SSH_PORT" \
      "$TARGET"
  '

echo
echo "=== Instalación lista (si no hubo errores arriba) ==="
echo "La máquina se reinició sola. Si es una VM con ISO montado, expulsalo"
echo "(o va a bootear el instalador de nuevo en vez del sistema instalado)."
echo
echo "Como el TPM todavía no está enrolado, este primer arranque va a pedir"
echo "la passphrase de disco A MANO en la consola (una sola vez - el"
echo "siguiente script se encarga de enrolar el TPM para que no la vuelva"
echo "a pedir)."
echo
echo "=== Siguiente paso: post-instalación ==="
echo "Cuando $LOGIN_USER@$REMOTE_HOST responda por SSH, corré (separado a"
echo "propósito de este script - se puede re-correr solo, sin repetir la"
echo "instalación completa que particiona y borra todo):"
echo "  ./post-install-setup.sh"
