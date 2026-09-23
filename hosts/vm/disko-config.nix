# Layout de disco declarativo (disko) — reemplaza el particionado manual.
# Reutilizable para otras máquinas: solo cambia `device`
# (disko.devices.disk.main.device en el host del repo privado).
{
  # Desbloqueo por TPM2 (+ PIN, lo enrola post-install-setup.sh): necesita el
  # initrd con systemd para que crypttab entienda "tpm2-device". Sin TPM o
  # sin enrolar, pide la passphrase como siempre.
  boot.initrd.systemd.enable = true;
  boot.initrd.luks.devices.crypted.crypttabExtraOpts = [ "tpm2-device=auto" ];

  disko.devices = {
    disk.main = {
      device = "/dev/vda"; # VM de QEMU/Boxes; en la laptop real sería /dev/nvme0n1
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "512M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };
          root = {
            size = "100%";
            content = {
              # LUKS (hallazgo crítico del pentest de seguridad,
              # 2026-09-16): sin esto, un disco perdido/robado expone
              # todo en texto plano sin necesitar ni la contraseña del
              # sistema. La passphrase la pide `nixos-anywhere` al
              # instalar vía --disk-encryption-keys (ver
              # nixos-anywhere-deploy.sh) - acá solo se declara DÓNDE
              # la deja temporalmente ese instalador para que disko la
              # use al formatear.
              #
              # Deliberadamente SIN keyFile para el arranque: eso
              # significa que en cada boot hay que tipear la passphrase
              # a mano (como FileVault/BitLocker) - un keyFile guardado
              # en el propio disco anularía la protección completa
              # (si roban el disco, la llave viaja con él).
              type = "luks";
              name = "crypted";
              passwordFile = "/tmp/disko-password";
              settings.allowDiscards = true;
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
}
