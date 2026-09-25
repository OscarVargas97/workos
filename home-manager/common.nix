# Entorno genérico — Fase 2, para cualquier persona de la empresa que use
# este repo. Nada de identidad acá (usuario, email, clave SSH); eso vive
# en modules/workos.nix (valores en el repo privado), que importa este archivo.
{ config, pkgs, ... }:
let
  slk = pkgs.callPackage ./pkgs/slk.nix { };
in
{
  imports = [
    ./hyprland.nix
    ./neovim.nix
    ./cyber-shell.nix
    ./zsh.nix
    ./kitty.nix
    ./devenv.nix
    ./herdr.nix
    ./yazi.nix
  ];

  home.stateVersion = "26.05";

  programs.git.enable = true;
  # gh (home.packages, abajo) como credential helper de github.com - así
  # git clone/push por https ya funciona solo con el login de `gh auth
  # login`, sin correr `gh auth setup-git` a mano. Ese comando intenta
  # escribir ~/.config/git/config directo, pero home-manager lo genera
  # de solo lectura (symlink al store) - falla con "Read-only file
  # system" (bug real, encontrado instalando la laptop real). La línea
  # "" vacía antes resetea cualquier helper heredado de un [credential]
  # más genérico, mismo formato que genera "gh auth setup-git" cuando
  # sí puede escribir.
  programs.git.extraConfig = {
    credential."https://github.com".helper = [ "" "!${pkgs.gh}/bin/gh auth git-credential" ];
  };

  # nvim ya es el IDE completo (Fase 2) - lo mismo para $EDITOR/$VISUAL
  # (git commit sin -m, sudoedit, etc), en vez de caer al default (vi/nano).
  home.sessionVariables.EDITOR = "nvim";
  home.sessionVariables.VISUAL = "nvim";

  # Carpetas en español (ya asumido por alias como cdgithub en zsh.nix) -
  # se declaran explícitas porque defaultLocale queda en inglés
  # (formatos regionales, si hay, en la identidad del repo privado), así que no
  # salen solas de la localización del sistema.
  xdg.userDirs = {
    enable = true;
    createDirectories = true;
    desktop = "${config.home.homeDirectory}/Escritorio";
    documents = "${config.home.homeDirectory}/Documentos";
    download = "${config.home.homeDirectory}/Descargas";
    music = "${config.home.homeDirectory}/Musica";
    pictures = "${config.home.homeDirectory}/Imagenes";
    publicShare = "${config.home.homeDirectory}/Publico";
    templates = "${config.home.homeDirectory}/Plantillas";
    videos = "${config.home.homeDirectory}/Videos";
  };

  # nvim como "editor de texto" gráfico por defecto (mimeApps de abajo) -
  # no hay un editor GUI standalone pedido, así que se envuelve el mismo
  # nvim de siempre en kitty en vez de sumar otro programa distinto.
  xdg.desktopEntries.nvim-kitty = {
    name = "Neovim";
    genericName = "Editor de texto";
    exec = "kitty -e nvim %f";
    terminal = false;
    type = "Application";
    mimeType = [ "text/plain" "text/markdown" "application/json" "text/x-nix" ];
    categories = [ "Utility" "TextEditor" ];
  };

  # Brave por defecto (DECISIONS.md #8) + un visor por tipo de archivo
  # habitual (Fase 2b) - livianos y nativos de Wayland, sin arrastrar
  # entorno GNOME/KDE completo por un solo visor.
  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "text/html" = "brave-browser.desktop";
      "x-scheme-handler/http" = "brave-browser.desktop";
      "x-scheme-handler/https" = "brave-browser.desktop";
      "x-scheme-handler/about" = "brave-browser.desktop";
      "x-scheme-handler/unknown" = "brave-browser.desktop";

      "application/pdf" = "org.pwmt.zathura.desktop";

      "image/png" = "imv.desktop";
      "image/jpeg" = "imv.desktop";
      "image/gif" = "imv.desktop";
      "image/webp" = "imv.desktop";

      "video/mp4" = "mpv.desktop";
      "video/x-matroska" = "mpv.desktop";
      "video/webm" = "mpv.desktop";

      "text/plain" = "nvim-kitty.desktop";
      "text/markdown" = "nvim-kitty.desktop";
    };
  };

  home.packages = with pkgs; [
    ripgrep
    fd
    bat
    btop
    fastfetch
    lazygit
    gh
    claude-code
    kubectl
    brave
    slk
    discord
    mpv
    imv
    zathura
    # GNOME Boxes (Fase 2b) - solo el paquete, el backend libvirtd/qemu va
    # a nivel de sistema (hosts/vm/configuration.nix). No trae gdm/
    # gnome-shell/nautilus: eso solo pasa si se habilita
    # services.xserver.desktopManager.gnome, que acá no se toca.
    gnome-boxes
    # Node/pnpm GLOBAL (Fase 3) - para instalar herramientas de CLI de
    # uso personal ("pnpm add -g ..."), no para proyectos puntuales. Los
    # proyectos pinnean su propia versión vía devenv.nix
    # (devenv.nix de este repo) - esto no reemplaza eso, es un runtime
    # aparte para lo que no está atado a ningún repo. Versión 22: la LTS
    # vigente al migrar (auditoría Fase 0).
    nodejs_22
    pnpm
    # Python: uv en vez de pyenv (decisión explícita) - maneja versiones
    # de Python + entornos + paquetes en un solo binario, más rápido.
    # miniforge/conda sigue afuera de la base, va por-proyecto vía
    # devenv.nix para lo que realmente necesita conda (Nextflow).
    uv
    # Cliente de base de datos nativo (auditoría Fase 0: DBeaver
    # Community, usado contra Postgres/Redis de proyectos reales) -
    # dbeaver-bin es el paquete correcto en nixpkgs, "dbeaver" a secas
    # no existe.
    dbeaver-bin
    # Cliente de base de datos de terminal (alternativa liviana a DBeaver
    # para uso rápido desde kitty/herdr, sin abrir una app Java/Electron
    # aparte) - conexiones en ~/.config/lazysql/config.toml, fuera de
    # este repo (dato de máquina, no de sistema).
    lazysql
    # AWS CLI v2 (auditoría de dotfiles real: ~/.aws/config con perfiles
    # ya armados) - "awscli" a
    # secas es la v1 vieja en nixpkgs, "awscli2" es la correcta. Sin
    # esto, migrate-pc.sh copia ~/.aws pero no hay binario que lo use -
    # bug real, encontrado auditando la laptop nueva después de migrar.
    awscli2
    # Plugin de Session Manager para AWS CLI (`aws ssm start-session`,
    # port forwarding) - sin este binario en el PATH, awscli2 falla con
    # "SessionManagerPlugin is not found" aunque el comando esté bien
    # escrito; no es un paquete de Python instalable con pip, es un
    # binario nativo que el CLI busca por nombre.
    ssm-session-manager-plugin
    # Backend de secretos para agentes (Fase 6, DECISIONS.md #2) - rbw
    # (cliente no oficial de Bitwarden) en vez de `bw` oficial: pensado
    # para scripting, `rbw get <nombre>` sin manejar session tokens a
    # mano. `work secret get` (work-os/cli/work) lo envuelve con la
    # policy de allowlist. Primer uso requiere `rbw config set email
    # <tu-email>` + `rbw login`/`rbw unlock` a mano (una persona, no un
    # agente - la IA nunca desbloquea el vault).
    rbw
    # rbw pide la contraseña maestra con el binario "pinentry": sin él,
    # `rbw unlock` falla con "error spawning pinentry".
    pinentry-curses
    # Cliente gráfico oficial de Bitwarden (aparte de rbw
    # - rbw es solo CLI, para scripting/agentes, no para uso manual del
    # vault completo: buscar, organizar, editar entradas). Mismo login
    # manual de siempre, la IA no lo toca. "bitwarden" es un alias roto
    # en nixpkgs desde 2025-10-27 (throw "renombrado a
    # bitwarden-desktop") - hay que usar el nombre nuevo.
    bitwarden-desktop
  ];

  # Brave (Chromium) sin esto renderiza via XWayland en vez de Wayland
  # nativo — capa de compatibilidad de mas, RAM/CPU de mas por ventana.
  # XWayland sigue disponible para lo que realmente lo necesite, esto
  # solo hace que Brave lo evite. slk (arriba) es TUI, no Electron: no
  # aplica.
  home.sessionVariables.NIXOS_OZONE_WL = "1";

  # docker-compose (clásico, el binario real de Docker Inc) busca el
  # socket en la ruta fija de siempre (/var/run/docker.sock) - podman
  # escucha en otro lado (/run/podman/podman.sock). Sin esto,
  # docker-compose tira "permission denied" contra un socket viejo que
  # ya no tiene nada escuchando. `docker` (el alias a podman,
  # dockerCompat) no lo necesita, solo las herramientas que hablan la
  # API de Docker por socket en vez de invocar el binario.
  home.sessionVariables.DOCKER_HOST = "unix:///run/podman/podman.sock";

  fonts.fontconfig.enable = true;

  # Contexto de sistema para Claude Code: lo carga en toda sesión, en
  # cualquier directorio. Declarado para que venga en cada instalación; se
  # edita en docs/claude-system.md, no en ~/.claude (es un symlink de solo
  # lectura al store). "text" y no "source" a propósito: es de tipo lines,
  # así el repo privado puede sumarle lo suyo con lib.mkAfter.
  home.file.".claude/CLAUDE.md".text = builtins.readFile ../docs/claude-system.md;
}
