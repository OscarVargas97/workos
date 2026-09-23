# Mínimo real para QEMU/Boxes (bus virtio, machine q35). { } vacío fallaba:
# el initrd no traía los módulos para ver /dev/vda a tiempo ("Timed out
# waiting for device /dev/disk/by-partlabel/disk-main-root").
#
# Para una máquina real (ej. la laptop), hay que generarlo de verdad —
# detecta CPU, módulos de kernel, etc.:
#
#   sudo nixos-generate-config --no-filesystems --root /mnt
#
# (--no-filesystems porque disko-config.nix ya define los filesystems; no
# duplicar). Reemplazar este archivo con ese resultado antes de instalar en
# hardware real.
{ modulesPath, ... }:
{
  # El perfil oficial de nixpkgs para VMs QEMU ya trae los módulos virtio
  # correctos en el initrd — no hace falta re-listarlos a mano.
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
}
