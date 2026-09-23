#!/usr/bin/env bash
# Crea el pendrive de instalación de punta a punta: graba el ISO OFICIAL de
# NixOS (el más nuevo de ~/Repos/Externos/workos/iso/, cualquier versión) y autoriza tu
# clave SSH para root en el live, sin reconstruir el ISO. Queda listo para
# nixos-anywhere-deploy.sh.
#
# Cómo: el live ya trae /etc/tmpfiles.d/ssh-root-provision.conf, que
# escribe /root/.ssh/authorized_keys desde la credencial de systemd
# 'ssh.authorized_keys.root'. Esa credencial se pasa por la línea del
# kernel (systemd.set_credential_binary=...), así que alcanza con editar
# el menú de GRUB:
#   1. La partición EFI (FAT) del pendrive se puede escribir: a su
#      grub.cfg se le agrega el parámetro en cada línea 'linux ... init='.
#   2. Pero GRUB casi siempre arranca vía El Torito y lee el grub.cfg del
#      ISO9660 (solo lectura, no se puede agrandar). Ese archivo se pisa
#      en el lugar, con el mismo tamaño, por un stub que salta al de la FAT.
# sshd arranca solo y el live permite root por clave: no hace falta tocar
# la consola de la máquina destino (salvo leer su IP).
#
# Límite: solo arranque UEFI. En BIOS/legacy (isolinux) bootea stock.
#
# Uso: prepare-installer-usb.sh [/dev/sdX] [archivo.iso] [clave.pub]
#   Sin el primer argumento, ofrece elegir entre los pendrives USB ya
#   conectados. Pide sudo solo (para el pendrive). BORRA el pendrive
#   (confirma antes, mostrando cuál es; --yes como primer argumento salta
#   la confirmación).
#   Si el destino es un archivo .iso en vez de un pendrive, no graba nada:
#   solo lo modifica en el lugar (para probar en una VM; usá una copia).
#   Se puede correr de nuevo (reemplaza la clave, no la duplica).
set -euo pipefail

ARGS=("$@")
SKIP_CONFIRM=false
[ "${1:-}" = "--yes" ] && { SKIP_CONFIRM=true; shift; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  # Sin argumento: ofrece elegir entre los pendrives USB extraíbles ya
  # conectados, en vez de exigir la ruta a mano (misma idea que el
  # 'select' de nixos-anywhere-deploy.sh para elegir el host del flake).
  mapfile -t USB_DEVS < <(lsblk -dnpo NAME,TRAN,RM,TYPE | awk '$2=="usb" && $3==1 && $4=="disk" {print $1}')
  [ "${#USB_DEVS[@]}" -gt 0 ] || { echo "No veo ningún pendrive USB conectado - conectalo y volvé a correr esto." >&2; exit 1; }
  echo "¿Qué pendrive grabo?"
  select TARGET in "${USB_DEVS[@]}"; do [ -n "$TARGET" ] && break; done
fi
# "|| true": sin carpeta iso/, ls falla y con pipefail el script moría en
# silencio en vez de llegar al mensaje "No encuentro el ISO" de más abajo.
ISO="${2:-$(ls -t "$SCRIPT_DIR"/../../../iso/*.iso 2>/dev/null | head -1 || true)}"
USER_HOME="$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)"
PUBKEY="${3:-$USER_HOME/.ssh/id_ed25519.pub}"

command -v mcopy >/dev/null || { echo "Falta mtools (dnf install mtools)." >&2; exit 1; }
[ -f "$PUBKEY" ] || { echo "No encuentro la clave pública '$PUBKEY'." >&2; exit 1; }
grep -q '^ssh-' "$PUBKEY" || { echo "'$PUBKEY' no parece una clave pública SSH." >&2; exit 1; }

# --- 0. Grabar el ISO (solo si el destino es un pendrive) ---
if [ -b "$TARGET" ]; then
  [ -f "$ISO" ] || { echo "No encuentro el ISO ('$ISO'). Bajalo a ~/Repos/Externos/workos/iso/ o pasalo como 2º argumento." >&2; exit 1; }
  # Solo discos USB extraíbles enteros: nunca un disco interno ni una partición.
  read -r TYPE TRAN RM < <(lsblk -dno TYPE,TRAN,RM "$TARGET")
  if [ "$TYPE" != disk ] || [ "$TRAN" != usb ] || [ "$RM" != 1 ]; then
    echo "'$TARGET' no es un pendrive USB extraíble (type=$TYPE tran=$TRAN rm=$RM). No lo toco." >&2; exit 1
  fi
  [ "$(id -u)" -eq 0 ] || exec sudo "$0" "${ARGS[@]}"
  echo "Se va a BORRAR este pendrive y grabar $(basename "$ISO"):"
  lsblk -o NAME,SIZE,MODEL,LABEL,MOUNTPOINTS "$TARGET"
  if ! $SKIP_CONFIRM; then
    read -rp "Escribí 'si' para confirmar: " CONFIRM
    [ "$CONFIRM" = "si" ] || { echo "Cancelado."; exit 1; }
  fi
  for p in $(lsblk -lnpo NAME "$TARGET"); do umount "$p" 2>/dev/null || true; done
  dd if="$ISO" of="$TARGET" bs=4M conv=fsync status=progress
elif [ ! -f "$TARGET" ]; then
  echo "'$TARGET' no es un dispositivo ni un archivo." >&2; exit 1
fi

# --- 1. grub.cfg de la partición EFI (FAT) ---
START="$(sfdisk -d "$TARGET" | sed -n 's/.*start= *\([0-9]*\),.*type=ef.*/\1/p' | head -1)"
[ -n "$START" ] || { echo "'$TARGET' no tiene partición EFI: ¿es un ISO de NixOS grabado con dd?" >&2; exit 1; }
FAT="$TARGET@@$((START * 512))"
export MTOOLS_SKIP_CHECK=1

CFG="$(mktemp)"
STUB="$(mktemp)"
trap 'rm -f "$CFG" "$STUB"' EXIT
mtype -i "$FAT" ::/EFI/BOOT/grub.cfg > "$CFG"

PARAM="systemd.set_credential_binary=ssh.authorized_keys.root:$(base64 -w0 < "$PUBKEY")"
# Saca una clave de una corrida anterior y agrega la nueva al final.
sed -i -E \
  -e 's/ systemd\.set_credential_binary=ssh\.authorized_keys\.root:[^ ]*//' \
  -e "/^\s*linux .*init=/ s|\s*\$| $PARAM|" "$CFG"

N="$(grep -c "$PARAM" "$CFG" || true)"
[ "$N" -gt 0 ] || { echo "No encontré entradas 'linux ... init=' en grub.cfg: cambió el formato del ISO, revisar a mano." >&2; exit 1; }
# El kernel x86 corta la línea de comandos en 2048 bytes.
if awk 'length > 2000 && /^\s*linux /' "$CFG" | grep -q .; then
  echo "La línea del kernel queda demasiado larga (¿muchas claves en '$PUBKEY'?)." >&2; exit 1
fi

# --- 2. grub.cfg del ISO9660: ubicarlo recorriendo los directorios ---
read -r OFF SIZE < <(python3 - "$TARGET" <<'PY'
import struct, sys
f = open(sys.argv[1], 'rb')
def entry(ext, size, name):
    f.seek(ext * 2048); d = f.read(size); i = 0
    while i < len(d):
        n = d[i]
        if n == 0:                       # resto del sector vacío
            i = (i // 2048 + 1) * 2048; continue
        e, s = struct.unpack_from('<I', d, i + 2)[0], struct.unpack_from('<I', d, i + 10)[0]
        if d[i+33:i+33+d[i+32]].decode('latin1').split(';')[0].upper() == name:
            return e, s
        i += n
    sys.exit(f'ISO9660: no encontré {name}')
f.seek(16 * 2048)
pvd = f.read(2048)
if pvd[1:6] != b'CD001': sys.exit('No es un ISO9660')
ext, size = struct.unpack_from('<I', pvd, 158)[0], struct.unpack_from('<I', pvd, 166)[0]
for name in ('EFI', 'BOOT', 'GRUB.CFG'):
    ext, size = entry(ext, size, name)
print(ext * 2048, size)
PY
)

cat > "$STUB" <<'CFG'
# workos: el menú real (con la clave SSH) está en la partición EFI.
# Ver work-os/scripts/prepare-installer-usb.sh en workos.
search --no-floppy --set=root --file /EFI/BOOT/workos-usb
configfile ($root)/EFI/BOOT/grub.cfg
CFG
PAD=$((SIZE - $(stat -c %s "$STUB")))
[ "$PAD" -ge 0 ] || { echo "El grub.cfg del ISO9660 es demasiado chico ($SIZE bytes)." >&2; exit 1; }
printf '%*s' "$PAD" '' | tr ' ' '\n' >> "$STUB"

mcopy -o -i "$FAT" "$CFG" ::/EFI/BOOT/grub.cfg
mcopy -o -i "$FAT" /dev/null ::/EFI/BOOT/workos-usb
dd if="$STUB" of="$TARGET" bs=4096 seek="$OFF" oflag=seek_bytes conv=notrunc status=none
sync
echo "OK: clave '$PUBKEY' autorizada para root en $N entradas del menú UEFI de $TARGET."
