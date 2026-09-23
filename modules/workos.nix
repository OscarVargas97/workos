# Variables de identidad del sistema. Este repo solo declara las
# opciones; los valores reales (usuario, nombre, email, claves SSH) los
# pone el repo privado de cada persona (ver example/identity.nix).
{ config, lib, pkgs, ... }:
let
  cfg = config.workos;
  inherit (lib) mkOption types;
in
{
  options.workos = {
    user = {
      name = mkOption { type = types.str; description = "Usuario de login."; };
      fullName = mkOption { type = types.str; description = "Nombre para los commits de git."; };
      email = mkOption { type = types.str; description = "Email para los commits de git."; };
      sshKeys = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Claves públicas autorizadas por SSH. Solo estas - cualquier clave
          no listada queda afuera aunque antes funcionara.
        '';
      };
    };
    secretsPolicy = mkOption {
      type = types.path;
      default = ../work-os/cli/secrets-policy.yaml;
      description = "Allowlist de secretos por skill (default-deny, DECISIONS.md #2).";
    };
  };

  config = {
    users.users.${cfg.user.name} = {
      isNormalUser = true;
      extraGroups = [ "wheel" "networkmanager" "podman" "libvirtd" ];
      shell = pkgs.zsh;
      openssh.authorizedKeys.keys = cfg.user.sshKeys;
      # Hash de contraseña inyectado por work-os/scripts/nixos-anywhere-deploy.sh
      # vía --extra-files (nunca se pide ni se guarda en ningún repo). Sin
      # esto, el login gráfico y sudo quedan sin forma de autenticar.
      hashedPasswordFile = "/etc/secrets/${cfg.user.name}-password-hash";
    };

    home-manager.users.${cfg.user.name} = {
      imports = [ ../home-manager/common.nix ];
      home.username = cfg.user.name;
      home.homeDirectory = "/home/${cfg.user.name}";
      programs.git.settings.user = { inherit (cfg.user) email; name = cfg.user.fullName; };
      xdg.configFile."work-os/secrets-policy.yaml".source = cfg.secretsPolicy;
    };
  };
}
