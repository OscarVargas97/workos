{
  description = "workos — Work OS base: NixOS + Home Manager + CLI de agentes, sin datos personales";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # AGS v3 (Astal+Gnim) no viene en nixpkgs (el paquete "ags" ahí es la
    # v2 vieja, incompatible) - trae su propio flake, pineado como
    # cualquier otro input. Ya re-expone los modulos de astal que
    # necesitamos (hyprland, mpris, notifd, tray, network) como paquetes
    # propios. Sin "follows" a propósito: dejamos que use el
    # nixpkgs-unstable que fija internamente, para no arriesgar romper su
    # build contra nuestro canal estable 26.05.
    ags.url = "github:Aylur/ags";
    # HUD: fork de ARCANGEL0/CyberArch-Shell adaptado a NixOS + AGS v3
    # (código TS que corre con `ags run`, no un paquete Nix - por eso
    # "flake = false"). Un repo privado puede reemplazarlo por otro con
    # `inputs.workos.inputs.cyberShell.follows = "cyberShell"`.
    cyberShell = {
      url = "github:OscarVargas97/cyber-shell";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, home-manager, disko, ags, cyberShell, ... }: {
    # Arma un host completo. Todo lo que es de una persona/empresa/máquina
    # (identidad, hardware, disco, extras) llega en `modules` desde el
    # repo privado de quien lo usa - este repo no conoce a nadie.
    lib.mkHost = modules: nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit ags cyberShell; };
      modules = [
        disko.nixosModules.disko
        ./hosts/vm/configuration.nix
        ./modules/workos.nix
        ./modules/security.nix
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.extraSpecialArgs = { inherit ags cyberShell; };
        }
      ] ++ modules;
    };

    # Disco LUKS+ext4 por defecto (/dev/vda; otro host lo pisa con
    # disko.devices.disk.main.device).
    nixosModules.disko-default = ./hosts/vm/disko-config.nix;
    # Tests en VMs (necesitan KVM): nix flake check, o
    # nix build .#checks.x86_64-linux.security -L
    checks.x86_64-linux.security = import ./tests/security.nix {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      inherit self;
    };

    # Host de prueba: VM de QEMU/Boxes con el disco por defecto.
    nixosModules.vm = {
      imports = [ ./hosts/vm/disko-config.nix ./hosts/vm/hardware-configuration.nix ];
    };
  };
}
