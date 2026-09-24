# herdr (DECISIONS.md #5) - runtime de sesiones persistentes para agentes
# de coding, no un tema de terminal (Hyprland ya cubre splits/workspaces).
# Fork propio (OscarVargas97/herdr + OscarVargas97/herdr-sidebar,
# un plugin tipo VS Code) con secciones propias (repos/ports) agregadas
# al plugin.
#
# Versión anterior de este archivo compilaba con cargo+zig en un script
# de activación (con red, fuera de la sandbox de Nix - herdr vendorea un
# pedazo de Ghostty que se compila con Zig, y Zig baja sus propias
# dependencias en build-time). Reemplazado por esto: releases reales de
# los forks (tags v0.9.1-oscar.1 / v0.13.0-oscar.1; cada fork trae su
# script de build/release, scripts/fork/build.ps1, que imprime el hash
# SRI) - binarios musl estáticos, pineados por hash, `fetchurl`
# normal. Sin red en build, sin toolchain de compilación en
# home.packages, sin esperar minutos en cada activación - exactamente
# la opción "pineado a un tag/checksum" que DECISIONS.md #5 marcaba
# como ideal.
{ config, lib, pkgs, ... }:
let
  herdrVersion = "0.9.1-oscar.3";
  herdrSidebarVersion = "0.13.0-oscar.1";

  herdr = pkgs.stdenvNoCC.mkDerivation {
    pname = "herdr";
    version = herdrVersion;
    src = pkgs.fetchurl {
      url = "https://github.com/OscarVargas97/herdr/releases/download/v${herdrVersion}/herdr-x86_64-unknown-linux-musl";
      hash = "sha256-c47yRI97M/VYsHxWuTrceezMCRJKNZfdJpkGBREZ86U=";
    };
    dontUnpack = true;
    installPhase = ''
      mkdir -p $out/bin
      install -m755 $src $out/bin/herdr
    '';
  };

  # El plugin necesita su árbol completo, no solo el binario:
  # herdr-plugin.toml invoca ./target/release/herdr-sidebar relativo a
  # plugins/herdr-sidebar/ (ver handoff, sección "Puntos a tener en
  # cuenta"). Se arma un derivation que junta el código fuente del tag
  # (para el manifest/assets) con el binario prebuilt en la ruta exacta
  # que ese manifest espera.
  herdrSidebarSrc = pkgs.fetchFromGitHub {
    owner = "OscarVargas97";
    repo = "herdr-sidebar";
    rev = "v${herdrSidebarVersion}";
    hash = "sha256-gl4JFwwBlAAOvOz2H3KTpK8lWh37IbwX5LrQKQvRV2s=";
  };
  herdrSidebarBin = pkgs.fetchurl {
    url = "https://github.com/OscarVargas97/herdr-sidebar/releases/download/v${herdrSidebarVersion}/herdr-sidebar-x86_64-unknown-linux-musl";
    hash = "sha256-MvuMuquUl13KxqxsBj5FJb53m3RMIYyjNcm3v/4woqE=";
  };
  herdrSidebarPlugin = pkgs.runCommand "herdr-sidebar-plugin-${herdrSidebarVersion}" { } ''
    mkdir -p "$out/plugins/herdr-sidebar/target/release"
    cp -r ${herdrSidebarSrc}/plugins/herdr-sidebar/. "$out/plugins/herdr-sidebar/"
    chmod -R u+w "$out/plugins/herdr-sidebar"
    install -m755 ${herdrSidebarBin} "$out/plugins/herdr-sidebar/target/release/herdr-sidebar"
  '';
in
{
  home.packages = [ herdr ];

  # El "plugin link" hay que re-ejecutarlo en cada activación (idempotente,
  # `|| true`): el path del plugin en el store cambia con cada versión, y
  # herdr necesita que se le vuelva a apuntar. Primero limpia el symlink
  # viejo de ~/.local/bin (del enfoque anterior que compilaba a mano) -
  # si queda ahí, tapa el `herdr` de home.packages en el PATH.
  home.activation.linkHerdrSidebar = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    $DRY_RUN_CMD rm -f "${config.home.homeDirectory}/.local/bin/herdr"
    $VERBOSE_ECHO "herdr: registrando plugin herdr-sidebar (${herdrSidebarVersion})..."
    $DRY_RUN_CMD ${herdr}/bin/herdr plugin link "${herdrSidebarPlugin}/plugins/herdr-sidebar" || true
  '';

  # El sidebar arranca a la izquierda por default (dock_right=false, ver
  # src/state.rs del plugin) y la posición se persiste en un state.json
  # propio del plugin, no en config.toml - gestionarlo 100% con Nix (ej.
  # home.file, symlink de solo lectura) pisaría los ajustes que el
  # usuario cambia desde la UI en runtime (⚙ settings). Por eso se
  # semilla UNA sola vez, solo si el archivo todavía no existe (pedido
  # explícito: sidebar a la derecha sin configurarlo a mano) - una vez
  # creado, nunca más se toca desde acá, igual que companies.conf/
  # projects.conf.
  home.activation.herdrSidebarDockRight = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    STATE_FILE="${config.home.homeDirectory}/.local/state/herdr/plugins/herdr-sidebar/state.json"
    if [ ! -f "$STATE_FILE" ]; then
      $VERBOSE_ECHO "herdr-sidebar: primer arranque, seteando dock_right=true (a la derecha)..."
      $DRY_RUN_CMD mkdir -p "$(dirname "$STATE_FILE")"
      $DRY_RUN_CMD bash -c "printf '%s' '{\"dock_right\":true}' > \"$STATE_FILE\""
    fi
  '';

  # [ui.sidebar.repos] (config.toml de herdr) queda pendiente de agregar
  # a mano - ese archivo herdr lo reescribe en runtime con sus
  # propios ajustes (tema, keybindings tocados desde la UI), gestionarlo
  # 100% por Nix pisaría esos cambios en cada rebuild. Sin esto la sección
  # de repos del sidebar no aparece. Ejemplo para ~/.config/herdr/config.toml:
  #   [ui.sidebar.repos]
  #   roots = ["~/Repos"]
  #   max_depth = 3
}
