#!/usr/bin/env bash
# Prueba de punta a punta de la instalación, en una VM con TPM emulado y
# con los scripts reales de work-os/scripts/:
#
#   ISO oficial de NixOS -> prepare-installer-usb.sh (modo archivo)
#   -> VM UEFI + TPM2 (swtpm) arrancando ese ISO
#   -> nixos-anywhere-deploy.sh (INSTALL_FROM=local: este checkout, sin pushear)
#   -> primer arranque con la passphrase del disco
#   -> post-install-setup.sh: TPM2 + PIN y códigos TOTP
#   -> reinicio: el disco se abre con el PIN (sin passphrase)
#   -> sudo exige el código TOTP "sudo" (uno mal: rechazado; el bueno: OK)
#
# El repo privado es uno de prueba, creado desde workos-template con su
# setup.sh sin preguntas. Todo queda en $WORK (default ~/.cache/workos-e2e);
# la VM se apaga al final (--keep la deja corriendo para mirarla).
#
# Requiere: Linux con KVM, nix, docker o podman, ~/.ssh/id_ed25519(.pub).
# Uso: tests/e2e-install.sh [--keep]
set -euo pipefail

if [ -z "${WORKOS_E2E_SHELL:-}" ]; then
  exec env WORKOS_E2E_SHELL=1 nix --extra-experimental-features "nix-command flakes" shell \
    nixpkgs#qemu nixpkgs#swtpm nixpkgs#expect nixpkgs#oath-toolkit nixpkgs#socat \
    nixpkgs#mtools nixpkgs#curl nixpkgs#python3 nixpkgs#util-linux \
    -c bash "$0" "$@"
fi

KEEP=false; [ "${1:-}" = "--keep" ] && KEEP=true
WORKOS=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=${WORK:-$HOME/.cache/workos-e2e}
TEMPLATE=${WORKOS_TEMPLATE_REPO:-https://github.com/OscarVargas97/workos-template}
ISO_URL=${ISO_URL:-https://channels.nixos.org/nixos-26.05/latest-nixos-minimal-x86_64-linux.iso}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}
PORT=2222
LOGIN_PASS=e2e-login-pass
DISK_PASS=e2e-disk-pass
PIN=246810
S="$WORKOS/work-os/scripts"

log() { printf '\n\033[1;35m== %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mFALLÓ: %s\033[0m\n' "$*" >&2; exit 1; }

cleanup() {
  $KEEP && { echo "VM corriendo (--keep): ssh -p $PORT tester@127.0.0.1, serial: socat - UNIX:$WORK/serial.sock"; return; }
  [ -f "$WORK/qemu.pid" ] && kill "$(cat "$WORK/qemu.pid")" 2>/dev/null || true
  [ -f "$WORK/swtpm.pid" ] && kill "$(cat "$WORK/swtpm.pid")" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$WORK"
cd "$WORK"

# --- Repo privado de prueba ------------------------------------------------------
log "Repo privado de prueba (desde workos-template, setup.sh sin preguntas)"
rm -rf workos-private
git clone -q "$TEMPLATE" workos-private
(
  cd workos-private
  WORKOS_USER=tester WORKOS_FULLNAME="E2E Tester" WORKOS_EMAIL=tester@example.com \
  WORKOS_SSH_KEYS="$(cat "$SSH_KEY.pub")" WORKOS_TIMEZONE=UTC WORKOS_LOCALE="" \
  WORKOS_HOST=e2e WORKOS_DISK=/dev/vda WORKOS_COMPANY=acme WORKOS_SSH_KEY="$SSH_KEY" \
  WORKOS_RBW_EMAIL="" scripts/setup.sh < /dev/null > setup.log
  # Lo que se prueba + consola serial (los prompts del arranque van ahí).
  sed -i 's|^{ lib, ... }:$|{ lib, ... }:|; s|^  imports = \[ ./hardware-configuration.nix \];$|  imports = [ ./hardware-configuration.nix ];\n  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200" ];\n  workos.security = {\n    totp.enable = true;\n    sshTotp = { enable = true; trustedNetworks = [ "10.0.2.0/24" ]; };\n  };|' hosts/e2e/default.nix
  git add -A && git -c user.name=e2e -c user.email=e2e@example.com commit -qm e2e
)
grep -q "totp.enable = true" workos-private/hosts/e2e/default.nix || fail "no pude activar workos.security en el host de prueba"

# --- ISO ---------------------------------------------------------------------------
log "ISO de NixOS + clave SSH autorizada (prepare-installer-usb.sh, modo archivo)"
[ -f nixos.iso ] || curl -fL --progress-bar -o nixos.iso "$ISO_URL"
cp nixos.iso installer.iso
bash "$S/prepare-installer-usb.sh" "$WORK/installer.iso" "" "$SSH_KEY.pub"

# --- VM: UEFI + TPM2 + disco virtio, SSH en localhost:$PORT --------------------------
log "VM (QEMU + OVMF + swtpm)"
OVMF=$(nix --extra-experimental-features "nix-command flakes" build --no-link --print-out-paths nixpkgs#OVMF.fd)
cp -f "$OVMF/FV/OVMF_VARS.fd" vars.fd && chmod u+w vars.fd
rm -rf tpm && mkdir tpm
swtpm socket --tpm2 --tpmstate dir=tpm --ctrl type=unixio,path=tpm/sock --daemon --pid file=swtpm.pid
rm -f disk.qcow2 && qemu-img create -q -f qcow2 disk.qcow2 40G
rm -f serial.sock serial.log
qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -smp 4 -m 6144 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF/FV/OVMF_CODE.fd" \
  -drive if=pflash,format=raw,file=vars.fd \
  -chardev socket,id=chrtpm,path=tpm/sock -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
  -drive file=disk.qcow2,if=none,id=d0 -device virtio-blk-pci,drive=d0,bootindex=1 \
  -device qemu-xhci -drive file=installer.iso,format=raw,if=none,id=stick,readonly=on \
  -device usb-storage,drive=stick,bootindex=2 \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:22 -device virtio-net-pci,netdev=n0 \
  -serial unix:serial.sock,server,nowait -display none -daemonize -pidfile qemu.pid

wait_ssh() { # wait_ssh usuario segundos
  for _ in $(seq 1 "$(($2 / 5))"); do
    ssh -p $PORT -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$1@127.0.0.1" true 2>/dev/null && return 0
    sleep 5
  done
  return 1
}
wait_ssh root 300 || fail "el live no levantó SSH con la clave autorizada"

# Los prompts de arranque (passphrase / PIN) llegan por la consola serial.
answer_boot_prompt() { # answer_boot_prompt "texto esperado" respuesta segundos
  expect -c "
    set timeout $3
    spawn socat - UNIX-CONNECT:$WORK/serial.sock
    expect {
      -re {$1} { sleep 1; send -- \"$2\r\"; sleep 3; exit 0 }
      timeout { exit 1 }
    }" > /dev/null
}

# --- Instalación ---------------------------------------------------------------------
log "Instalación (nixos-anywhere-deploy.sh, INSTALL_FROM=local)"
# Respuestas: usuario del live (Enter), host "e2e" (último de la lista),
# no commitear el hardware generado, confirmar el particionado.
N_HOSTS=$(grep -cE 'nixosConfigurations\.[A-Za-z0-9_-]+ =' workos-private/flake.nix)
# El mkpasswd de whois primero: el de expect (en el PATH de este script) es otro.
mkdir -p bin && ln -sf "$(nix --extra-experimental-features "nix-command flakes" build --no-link --print-out-paths "nixpkgs#mkpasswd^out")/bin/mkpasswd" bin/mkpasswd
printf '\n%s\nn\nsi\n' "$N_HOSTS" | \
  PATH="$WORK/bin:$PATH" INSTALL_FROM=local WORKOS_PRIVATE="$WORK/workos-private" REMOTE_HOST=127.0.0.1 SSH_PORT=$PORT \
  SSH_KEY="$SSH_KEY" LOGIN_USER=tester LOGIN_PASSWORD="$LOGIN_PASS" DISK_PASSPHRASE="$DISK_PASS" \
  bash "$S/nixos-anywhere-deploy.sh" 2>&1 | tee deploy.log | grep -E "^===|OK|Falló|Error|error:" || true
grep -q "Instalación lista" deploy.log || fail "nixos-anywhere-deploy.sh (ver $WORK/deploy.log)"

log "Primer arranque: passphrase del disco"
answer_boot_prompt "(assphrase|password).*:" "$DISK_PASS" 600 || fail "no apareció el prompt de la passphrase"
wait_ssh tester 300 || fail "el sistema instalado no levantó SSH"

# --- Post-instalación ----------------------------------------------------------------
log "Post-instalación (post-install-setup.sh: TPM2 + PIN, TOTP)"
export LOGIN_USER=tester REMOTE_HOST=127.0.0.1 SSH_PORT=$PORT SSH_KEY COMPANY_NAME=acme \
  WORKOS_PRIVATE="$WORK/workos-private"
expect -c "
  set timeout 300
  log_file -noappend $WORK/post-install.log
  spawn bash $S/post-install-setup.sh
  set secrets {}
  expect {
    -re {\[sudo\] password} { send -- \"$LOGIN_PASS\r\"; exp_continue }
    -re {current passphrase} { send -- \"$DISK_PASS\r\"; exp_continue }
    -re {TPM2 PIN} { send -- \"$PIN\r\"; exp_continue }
    -re {secret key is: ([A-Z2-7]+)} { set last \$expect_out(1,string); lappend secrets \$last; exp_continue }
    -re {Enter code from app} { send -- \"[exec oathtool --totp -b \$last]\r\"; exp_continue }
    -re {Enter cuando} { send -- \"\r\"; exp_continue }
    -re {Nombre de la empresa} { send -- \"acme\r\"; exp_continue }
    eof
  }
  set f [open $WORK/secrets w]; puts \$f [join \$secrets \"\n\"]; close \$f
" > /dev/null
grep -q "OK: el próximo arranque pide el PIN" post-install.log || fail "enrolamiento TPM2 + PIN (ver $WORK/post-install.log)"
[ "$(wc -l < secrets)" -ge 2 ] || fail "workos-totp-setup no creó los dos secretos (ver $WORK/post-install.log)"
UNLOCK_SECRET=$(sed -n 1p secrets); SUDO_SECRET=$(sed -n 2p secrets)

# --- Verificación ----------------------------------------------------------------------
ssh_tty() { # ssh_tty "comando" -> expect con contraseña + código
  expect -c "
    set timeout 60
    spawn ssh -t -p $PORT -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR tester@127.0.0.1 {$1}
    expect {
      -re {\[sudo\] password} { send -- \"$LOGIN_PASS\r\"; exp_continue }
      -re {Verification code} { send -- \"$2\r\"; exp_continue }
      -re {Sorry, try again} { send \003; exp_continue }
      eof
    }
    catch wait r; exit [lindex \$r 3]"
}
# Entre casos: un intento fallido cuenta para el límite de 3 cada 30 s
# (anti fuerza bruta), así que se espera a que salga de la ventana.
fresh_window() { sleep 31; sleep $((31 - $(date +%s) % 30)); }

# Un solo intento por caso (Ctrl-C en el reintento de sudo): con los 3
# reintentos de sudo, dos casos fallidos agotaban el límite y el código
# correcto se rechazaba - la protección funcionando, no un bug.
log "sudo exige el código \"sudo\""
fresh_window
ssh_tty "sudo -k; sudo true" 000000 > /dev/null && fail "sudo aceptó un código incorrecto"
fresh_window
ssh_tty "sudo -k; sudo true" "$(oathtool --totp -b "$UNLOCK_SECRET")" > /dev/null && fail "sudo aceptó el código de desbloqueo"
fresh_window
ssh_tty "sudo -k; sudo true" "$(oathtool --totp -b "$SUDO_SECRET")" > /dev/null || fail "sudo rechazó el código correcto"

log "Reinicio: el disco se abre con el PIN del TPM2"
fresh_window
ssh_tty "sudo systemctl reboot" "$(oathtool --totp -b "$SUDO_SECRET")" > /dev/null || true
answer_boot_prompt "PIN" "$PIN" 600 || fail "no apareció el prompt del PIN del TPM2"
wait_ssh tester 300 || fail "no arrancó con el PIN"
ssh -p $PORT -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR tester@127.0.0.1 \
  'grep -q pam_google_authenticator /etc/pam.d/hyprlock && grep -q pam_google_authenticator /etc/pam.d/login' \
  || fail "hyprlock/login sin TOTP en PAM"

log "TODO OK: instalación + TPM2/PIN + TOTP funcionando en la VM"
