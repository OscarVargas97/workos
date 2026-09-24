# Genérico: el hardware y el disco de cada máquina se agregan en flake.nix.
{ config, pkgs, ... }:
{
  boot.loader.systemd-boot.enable = true;
  # Sin editar la línea del kernel desde el menú de arranque: con acceso
  # físico permitía agregar init=/bin/sh o similares. Las generaciones
  # anteriores se siguen pudiendo elegir (recuperación).
  boot.loader.systemd-boot.editor = false;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "vm";
  networking.networkmanager.enable = true;

  # Brave/Slack y similares son unfree.
  nixpkgs.config.allowUnfree = true;

  # Fase 3 (devenv) - sin esto, devenv/nix-direnv fallan con "ignoring
  # the client-specified setting 'system', because it is a restricted
  # setting and you are not a trusted user": el daemon de Nix por
  # defecto solo confía en root. @wheel (no un usuario a mano) para que
  # cualquier admin del sistema pueda usar devenv.
  nix.settings.trusted-users = [ "root" "@wheel" ];

  # nix build/shell/run y flakes sin --extra-experimental-features en cada
  # comando: validar cambios (AGENTS.md) y las herramientas de un solo uso
  # (nix shell nixpkgs#x) dependen de esto.
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Limpieza de la store (2026-09-23): sin esto crecía sin límite (16 GB
  # y 7 generaciones sin tocar). gc semanal borra generaciones de más de
  # 14 días (la actual nunca se borra, y quedan 2 semanas para volver
  # atrás desde el menú de arranque). auto-optimise-store reemplaza
  # archivos idénticos de la store por hardlinks al construir.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.settings.auto-optimise-store = true;

  # Explícito a propósito (auditoría de seguridad, 2026-09-16): ya es el
  # default de NixOS, pero el criterio de este repo es no depender de
  # defaults no versionados (mismo caso que pipewire en Fase 2b). No
  # hace falta listar puertos a mano acá - services.openssh ya abre el
  # 22 solo (openFirewall=true por default de ese módulo).
  networking.firewall.enable = true;

  # Hallazgo del pentest (2026-09-16): net.ipv4.conf.all.rp_filter
  # venía en 0 (sin filtrado de ruta inversa - el kernel no descarta
  # paquetes con IP origen que no corresponde a por dónde deberían
  # entrar). 1 = estricto, apropiado para esta VM (una sola interfaz
  # simple hacia el bridge de libvirt, sin multi-homing que lo rompa).
  boot.kernel.sysctl."net.ipv4.conf.all.rp_filter" = 1;
  boot.kernel.sysctl."net.ipv4.conf.default.rp_filter" = 1;

  # Fase 3 - podman en vez de Docker (decisión explícita:
  # rootless/daemonless, sin un proceso corriendo como root todo el
  # tiempo - el default de Fedora/Red Hat). dockerCompat + dockerSocket.enable
  # para que `docker`/`docker-compose` (los `docker-compose.yml` de
  # proyectos existentes) sigan funcionando sin reescribir nada - dockerSocket
  # pone el socket de podman en el mismo lugar donde esas herramientas
  # ya buscan el de Docker. dns_enabled: los contenedores de un mismo
  # compose (celery, postgres, redis) necesitan resolverse por nombre
  # de servicio entre sí.
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    dockerSocket.enable = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  # Fase 2 — Hyprland como único entorno gráfico, sin GNOME/KDE de fondo.
  programs.hyprland.enable = true;
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-hyprland ];
  };

  # Sin adaptador real en esta VM (hciconfig no encuentra nada) - queda
  # andando igual para cuando esto corra en una máquina física, y para
  # que el módulo de bluetooth de waybar tenga con qué hablar por dbus.
  hardware.bluetooth.enable = true;

  # La VM se quedó sin memoria y se apagó sola varias veces (compilando
  # Vala/GTK para cyber-shell, con la sesión grafica ya arriba) - sin
  # esto, un pico de RAM mata el sistema en vez de degradar. zram
  # (RAM comprimida como swap) en vez de un swapfile en disco: no
  # necesita tocar el particionado de disko.
  zramSwap.enable = true;
  # Swappiness alto a propósito - el default del kernel (60) está pensado
  # para swap en DISCO (lento, evitarlo). zram es solo RAM comprimida -
  # swapear ahí es barato/rápido, así que conviene que el kernel lo use
  # más agresivo en vez de esperar a estar realmente apretado de RAM
  # (importa más en la laptop real de 16GB que acá).
  boot.kernel.sysctl."vm.swappiness" = 100;

  # GNOME Boxes (Fase 2b) para VMs anidadas sin salir de
  # Hyprland — solo libvirtd/qemu como backend, el paquete de Boxes en sí
  # va en home-manager (common.nix). Sin gdm/gnome-shell/nautilus: no se
  # habilita `services.xserver.desktopManager.gnome`, así que no arrastra
  # el resto del entorno GNOME. Nota: esta VM misma corre dentro de
  # libvirt/QEMU en el host real — Boxes acá adentro es virtualización
  # anidada, puede ir lento/sin KVM si el host no tiene nested virt
  # habilitado. La config es correcta igual para cuando esto se aplique a
  # la laptop real (ahí no hay anidamiento).
  virtualisation.libvirtd.enable = true;
  virtualisation.spiceUSBRedirection.enable = true;
  # dconf: GNOME Boxes (y otras apps GTK) lo necesitan para guardar sus
  # settings - sin esto tira warnings o pierde preferencias entre corridas.
  programs.dconf.enable = true;
  # LocalSend: pasar archivos entre equipos de la red (work vault env send).
  # Abre el 53317 (TCP/UDP) para descubrir equipos y recibir.
  programs.localsend = { enable = true; openFirewall = true; };

  # hyprpolkitagent (home-manager, hyprland.nix) necesita el servicio de
  # polkit corriendo — explícito para no depender de que algo más lo
  # habilite como efecto secundario.
  security.polkit.enable = true;

  services.greetd = {
    enable = true;
    settings.default_session = {
      # Fondo matrix + doom nativos de tuigreet (F4 alterna entre ambos en
      # el propio login, ver --kb-background). Mascota ASCII sin '/' ni
      # '\': esos trazos diagonales se ven mal en la fuente de la consola
      # virtual (bitmap chico); paréntesis/comillas/guiones sí son
      # nítidos ahí. Todo el texto sin tildes/ñ/unicode a propósito: la
      # fuente de consola por defecto no trae esos glifos (se ven en
      # blanco/rotos). Sin paquetes extra.
      # start-hyprland (no el binario Hyprland pelado) monta el entorno
      # de sesion correcto (dbus/systemd) - sin esto tira el warning de
      # "started without start-hyprland" y servicios como hyprpaper
      # pueden no levantar bien.
      command = "${pkgs.tuigreet}/bin/tuigreet --time --cmd start-hyprland --background matrix --matrix-colors '#00FF41,#008F11,#003B00' --custom-title 'nixos-unstab // acceso' --greeting '  (=^.^=)\n (\")_(\")\nautenticacion requerida' --asterisks --container-padding 2 --window-padding 2";
      user = "greeter";
    };
  };

  # Mensajes del sistema en inglés. Zona horaria y formatos regionales
  # (time.timeZone, i18n.extraLocaleSettings) son de la persona: van en
  # la identidad del repo privado, no acá.
  i18n.defaultLocale = "en_US.UTF-8";

  # El usuario de sistema y su identidad vienen de modules/workos.nix +
  # los valores del repo privado — este archivo es genérico.
  programs.zsh.enable = true;

  # sudo SÍ pide contraseña (default). El usuario no tiene una declarada acá
  # a propósito (nunca committeamos passwords) — se pone a mano después
  # del primer arranque con 'passwd', una sola vez. Para nixos-rebuild
  # remoto por SSH, usar 'ssh -t' (necesita terminal real para el prompt
  # de sudo).

  # sshd habilitado a propósito: sin esto no hay forma de entrar al sistema
  # instalado (solo el live installer trae sshd por defecto). Login por
  # clave únicamente, sin contraseñas.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  environment.systemPackages = with pkgs; [
    git
    vim
    gnumake
    # docker-compose clásico (standalone, con guion) - el subcomando
    # nuevo "docker compose" ya viene con el docker de nixpkgs, este es
    # por si algún proyecto todavía invoca el binario viejo.
    docker-compose
  ];

  system.stateVersion = "26.05";
}
