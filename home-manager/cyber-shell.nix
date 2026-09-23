# HUD estilo netrunner (fork propio de ARCANGEL0/CyberArch-Shell, ver
# ORIGIN.md del fork) corriendo con AGS v3 sobre Astal.
# Reemplaza a waybar/mako (duplicaban stats/notificaciones que este HUD
# ya muestra) - ver hyprland.nix, ambos quedan deshabilitados.
{ pkgs, lib, ags, cyberShell, ... }:
let
  agsPkgs = ags.packages.${pkgs.stdenv.hostPlatform.system};
  # AstalNotifd/AstalMpris/AstalWp no vienen en el paquete "ags" base
  # (core.ts los importa via gi://) - hay que sumar sus typelibs a mano.
  giExtra = lib.makeSearchPath "lib/girepository-1.0" [
    agsPkgs.notifd
    agsPkgs.mpris
    agsPkgs.wireplumber
  ];
  cyberShellBin = pkgs.writeShellScriptBin "cyber-shell" ''
    export GI_TYPELIB_PATH="${giExtra}:$GI_TYPELIB_PATH"
    export GSETTINGS_SCHEMA_DIR="${agsPkgs.notifd}/share/gsettings-schemas/astal-notifd-0.1.0/glib-2.0/schemas"
    # CYBER_SHELL_DIR=<clon local> cyber-shell: corre un checkout en
    # desarrollo con el mismo entorno, sin rebuild.
    exec ${agsPkgs.default}/bin/ags run --gtk 3 "''${CYBER_SHELL_DIR:-${cyberShell}}/core.ts"
  '';
in
{
  home.packages = [
    cyberShellBin
    agsPkgs.default # `ags` en el PATH - lo usan los binds de hyprland.nix (perf full/balanced/performance)
    pkgs.sassc # compila components/style/cyber.scss -> cyber.css
    pkgs.python3 # scripts/gen-map.py (minimapa del sidepanel)
    pkgs.nerd-fonts.symbols-only # ICONF = "Symbols Nerd Font" en fonts.ts
  ];

  # Fuentes propias del theme, si no los iconos/logos del HUD caen a un
  # font sin esos glifos (se ven como cuadros/tofu).
  home.file.".local/share/fonts/cyberarch".source = "${cyberShell}/assets/fonts";
}
