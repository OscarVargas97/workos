# Fase 2 — Hyprland + barra + launcher + notificaciones + bloqueo.
# Workspaces pensados como: 1 código, 2 terminal, 3 navegador,
# 4 comunicación (slk, TUI en una terminal), 5 IA/agentes. No es
# definitivo, se ajusta con uso real.
{ pkgs, osConfig, ... }:
let
  # El toggle de teclado (Alt+Espacio) queda como bind explícito de
  # Hyprland en vez de la opción XKB "grp:alt_shift_toggle" - esa opción
  # cambia el layout a nivel de XKB, invisible para Hyprland (no hay forma
  # de engancharle un aviso). Como bind normal sí podemos, en el mismo
  # paso, avisar cuál quedó activo (pedido explícito: "no me avisa nada
  # cuando cambia el teclado").
  kbLayoutToggle = pkgs.writeShellScriptBin "kb-layout-toggle" ''
    hyprctl switchxkblayout current next >/dev/null
    layout=$(hyprctl devices -j | ${pkgs.jq}/bin/jq -r '.keyboards[] | select(.main==true) | .active_keymap')
    case "$layout" in
      *Latin*|*latam*|*LATAM*) label="Español (Latam)" ;;
      *) label="Inglés (US)" ;;
    esac
    ${pkgs.libnotify}/bin/notify-send "Teclado" "$label"
  '';

  # "rebuild" (y $mod+CTRL+R, que lo abre en una terminal para escribir la
  # contraseña de sudo): aplica el repo privado (el flake de entrada, que
  # importa este como input "workos") del clon local al host actual. Solo
  # el clon local, no github: - el repo es privado y sudo corre como root,
  # sin las credenciales de git del usuario. Si también está clonado este
  # repo público al lado, se usa ese clon en vez del commit pineado en el
  # flake.lock del privado (cambios locales sin pushear).
  # rebuild [switch|boot|test] - switch por defecto.
  rebuild = pkgs.writeShellScriptBin "rebuild" ''
    flake=''${WORKOS_PRIVATE:-$HOME/Repos/Externos/workos/workos-private}
    core=''${WORKOS_CORE:-$flake/../workos}
    [ -f "$flake/flake.nix" ] || { echo "no encuentro el repo privado en $flake (usa WORKOS_PRIVATE=<ruta> rebuild)" >&2; exit 1; }
    override=()
    [ -f "$core/flake.nix" ] && override=(--override-input workos "git+file://$(realpath "$core")")
    sudo nixos-rebuild "''${1:-switch}" --flake "$flake#$(hostname)" "''${override[@]}"
  '';

  # "ocultar-ventanas" ($mod+M): Hyprland no tiene minimizar, así que mueve
  # todas las ventanas del workspace actual a special:oculto (fuera de
  # vista, sin cerrarlas). Si ya hay ventanas ocultas, las devuelve al
  # workspace actual (el de ese momento, no necesariamente el original).
  ocultarVentanas = pkgs.writeShellScriptBin "ocultar-ventanas" ''
    jq=${pkgs.jq}/bin/jq
    cur=$(hyprctl activeworkspace -j | $jq -r .id)
    hidden=$(hyprctl clients -j | $jq -r '.[] | select(.workspace.name == "special:oculto") | .address')
    if [ -n "$hidden" ]; then
      for a in $hidden; do hyprctl dispatch movetoworkspacesilent "$cur,address:$a" >/dev/null; done
    else
      for a in $(hyprctl clients -j | $jq -r --argjson w "$cur" '.[] | select(.workspace.id == $w) | .address'); do
        hyprctl dispatch movetoworkspacesilent "special:oculto,address:$a" >/dev/null
      done
    fi
  '';
in
{
  wayland.windowManager.hyprland = {
    enable = true;
    # Hyprland 0.55+ pasó a Lua como formato nuevo, y el módulo de
    # home-manager lo usa por defecto para paquetes tan nuevos — pero su
    # traductor a Lua no entiende el formato clásico "MODS, tecla,
    # dispatcher, args" de bind (rompía con "<name> expected near '$'" y
    # después con errores de keysym). configType = "hyprlang" fuerza el
    # .conf de siempre, que es la sintaxis que ya está escrita acá abajo.
    configType = "hyprlang";
    settings = {
      "$mod" = "SUPER";
      "$terminal" = "kitty";
      "$launcher" = "wofi --show drun";

      monitor = [ ",preferred,auto,1" ];

      # waybar/mako sacados de aca: cyber-shell (mas abajo) ya cubre esos
      # stats/notificaciones - la config de waybar queda mas abajo (sin
      # arrancar sola) por si se quiere volver a usar aparte.
      exec-once = [
        "hypridle"
        "swaybg -i ${./assets/wallpaper.png} -m fill"
        "cyber-shell"
        # Demonio de cliphist - sin esto el historial de $mod+V (bindd de
        # abajo) siempre está vacío, aunque el bind exista.
        "wl-paste --watch cliphist store"
        # Agente de polkit - sin uno, acciones gráficas que piden
        # privilegios (wifi protegida, autorizar Twingate, montar un
        # disco) fallan en silencio (no hay GNOME/KDE de fondo que traiga
        # uno). hyprpolkitagent en vez de polkit-gnome: nativo del
        # ecosistema Hyprland, no arrastra deps de GNOME. Ruta completa
        # a propósito: el binario vive en libexec/, no en bin/, así que
        # nunca entra al PATH solo con tenerlo en home.packages - el
        # exec-once fallaba en silencio (nunca corría) hasta este fix.
        "${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent"
      ];

      general = {
        gaps_in = 4;
        gaps_out = 8;
        border_size = 2;
        "col.active_border" = "rgba(bd93f9ee) rgba(ff79c6ee) 45deg";
        "col.inactive_border" = "rgba(44475aaa)";
      };

      decoration = {
        rounding = 10;
        active_opacity = 0.95;
        inactive_opacity = 0.85;
        blur = {
          enabled = true;
          size = 8;
          passes = 3;
          new_optimizations = true;
        };
      };

      # layerrule con nombres de efecto sueltos ("blur", "ignorezero") ya
      # no existe en esta version de Hyprland - la wiki solo documenta el
      # formato Lua nuevo (hl.layer_rule con tabla), no un equivalente
      # legacy claro. El blur de ventanas de arriba + la barra
      # semi-transparente ya dan el look pedido, sin perseguir una
      # sintaxis no documentada.

      # us (variante intl, para tener ñ/tildes por dead keys) + latam
      # intercambiables (pedido explícito) - el toggle es el bind
      # Alt+Espacio de más abajo (kb-layout-toggle), no una opción XKB,
      # para poder avisar con una notificación cuál quedó activo.
      input = {
        kb_layout = "us,latam";
        kb_variant = "intl,";
        follow_mouse = 1;
      };

      # bindd (bind + description): la descripción queda "Categoría: texto"
      # y viaja con el bind en hyprctl binds -j -> shortcuts.ts la lee de
      # ahí para categorizar el panel (Mod+K), sin mantener una lista
      # separada que se pueda desincronizar de estos binds.
      bindd =
        [
          "$mod, RETURN, Aplicaciones: Abrir terminal, exec, $terminal"
          # --hold deja la ventana abierta al terminar, para ver si falló
          "$mod CTRL, R, Sistema: Rebuild de NixOS, exec, $terminal --hold rebuild"
          "$mod, M, Ventanas: Ocultar/mostrar todas las ventanas, exec, ocultar-ventanas"
          "$mod, D, Aplicaciones: Abrir launcher, exec, $launcher"
          "$mod, V, Aplicaciones: Historial de portapapeles, exec, cliphist list | wofi --dmenu | cliphist decode | wl-copy"
          "$mod, Q, Ventanas: Cerrar ventana activa, killactive"
          # Invertido a pedido explícito: $mod+Q (cerrar ventana) se aprieta
          # tan seguido que $mod SHIFT+Q (un solo shift de distancia) volaba
          # sesiones enteras sin querer. Ahora el vecino de Q bloquea (acción
          # reversible) y salir de sesión se movió a L, mucho menos usado.
          "$mod SHIFT, Q, Sistema: Bloquear pantalla, exec, hyprlock"
          "$mod, L, Sistema: Salir de Hyprland, exit"
          ", Print, Capturas: Captura de región (al portapapeles), exec, grim -g \"$(slurp)\" - | wl-copy"
          "$mod, Print, Capturas: Captura de región (a archivo), exec, grim -g \"$(slurp)\" \"$HOME/Imagenes/captura-$(date +%Y%m%d-%H%M%S).png\""
          "$mod, B, Aplicaciones: Abrir Brave, exec, brave"
          "ALT, SPACE, Aplicaciones: Cambiar layout de teclado (us/latam), exec, kb-layout-toggle"

          # Todo lo que habla con el HUD (ags request -i cyberpunk) usa
          # siempre $mod SHIFT + letra, sin excepción - pedido explícito de
          # consistencia. Antes se mezclaba $mod solo para "acciones
          # directas" (notif, updates, perf, shortcuts, apps-menu) con
          # $mod SHIFT para "modales" (volumen, wifi...), y esa mezcla
          # generó un bug real: un bind terminó necesitando
          # SUPER+CTRL+Q porque Q y SHIFT+Q ya estaban tomados, pero el HUD
          # seguía dibujando solo "Q" - confuso y roto. $mod solo queda
          # reservado para gestión de ventanas y lanzar apps (arriba);
          # $mod SHIFT+letra que abajo NO dice "HUD:" en la descripción es
          # gestión nativa de ventanas (fullscreen, forzar cierre, mover
          # ventana), no pasa por cyber-shell.
          #
          # Los popups que dibujan la tecla en pantalla (aurbar.ts/
          # notifpopup.ts en cyber-shell) la leen en vivo de `hyprctl binds
          # -j` (ver keymap.ts ahí) - cambiar la letra acá abajo alcanza,
          # nunca más hace falta tocar cyber-shell para que el dibujo
          # coincida con el bind real.
          "$mod SHIFT, X, HUD: Descartar notificación actual, exec, ags request -i cyberpunk notif-dismiss"
          "$mod SHIFT, E, HUD: Leer notificación actual, exec, ags request -i cyberpunk notif-read"
          # G (no U): U ya es "modal aiusage" más abajo. El panel lista
          # drift de forks (vs su upstream real) y de herramientas del
          # sistema (inputs de flake.lock vs su origen) - ver
          # cyber-shell/components/modules/updates.ts.
          "$mod SHIFT, G, HUD: Abrir panel de actualizaciones (forks/herramientas), exec, ags request -i cyberpunk updates-toggle"
          "$mod SHIFT, J, HUD: Cerrar panel/aviso de actualizaciones, exec, ags request -i cyberpunk updates-dismiss"
          # 3 planes de animaciones/blur del HUD (pedido explícito: nunca
          # apagar animWheel, el menu de apps - baja el resto + el blur
          # de Hyprland, ver applyPerfPreset en cyber-shell/config.ts).
          "$mod SHIFT, F1, HUD: Plan de rendimiento FULL, exec, ags request -i cyberpunk 'perf full'"
          "$mod SHIFT, F2, HUD: Plan de rendimiento BALANCED, exec, ags request -i cyberpunk 'perf balanced'"
          "$mod SHIFT, F3, HUD: Plan de rendimiento PERFORMANCE, exec, ags request -i cyberpunk 'perf performance'"
          # Panel con todos los binds de Hyprland (lee hyprctl binds -j en
          # vivo, ver shortcuts.ts) - mientras se aprende Wayland. S (no K):
          # K ya es "forzar cierre" en gestión de ventanas, más abajo.
          "$mod SHIFT, S, HUD: Abrir/cerrar panel de shortcuts, exec, ags request -i cyberpunk shortcuts"

          # El resto de los paneles/toggles del HUD (auditoría completa de
          # userbinds.ts/THEME_ACTIONS - el diseño original de CyberArch-Shell,
          # pensado para un sistema de config Lua que no usamos, ver
          # DECISIONS.md). Se traduce acá 1 a 1 a bindd real. Quedan afuera
          # a propósito: chequeo de updates de AUR/del tema (no aplica,
          # desplegamos por Nix desde un commit fijo, no hay AUR) y el
          # cheatsheet estático de keybinds del HUD (mostraría datos
          # desactualizados/con entradas de AUR - nuestro panel de
          # $mod SHIFT+S ya cubre eso mejor, lee hyprctl binds -j en vivo).
          "$mod SHIFT, V, HUD: Volumen, exec, ags request -i cyberpunk 'modal vol'"
          "$mod SHIFT, I, HUD: Brillo, exec, ags request -i cyberpunk 'modal brt'"
          "$mod SHIFT, M, HUD: Notificaciones (historial), exec, ags request -i cyberpunk notif-hud"
          "$mod SHIFT, O, HUD: Reproductor de música, exec, ags request -i cyberpunk player"
          "$mod SHIFT, N, HUD: Wifi, exec, ags request -i cyberpunk 'modal wifi'"
          "$mod SHIFT, B, HUD: Bluetooth, exec, ags request -i cyberpunk 'modal bt'"
          "$mod SHIFT, P, HUD: Energía, exec, ags request -i cyberpunk 'modal pwr'"
          "$mod SHIFT, W, HUD: Pronóstico del clima, exec, ags request -i cyberpunk forecast"
          "$mod SHIFT, minus, HUD: Reloj, exec, ags request -i cyberpunk clock"
          "$mod SHIFT, Y, HUD: Batería, exec, ags request -i cyberpunk 'modal bat'"
          "$mod SHIFT, C, HUD: Monitor CPU/RAM, exec, ags request -i cyberpunk 'modal sys'"
          # % de sesión (5h)/semana de Claude Code, del mismo endpoint que usa
          # `claude` para su propio status (ver aiusage.ts/scripts/ai-usage.py
          # en cyber-shell) - reusa el token OAuth que Claude Code ya guarda,
          # nunca pide credenciales nuevas.
          "$mod SHIFT, U, HUD: Uso de Claude Code (sesion/semana), exec, ags request -i cyberpunk 'modal aiusage'"
          "$mod SHIFT, BackSpace, HUD: Ajustes del tema (animaciones/blur), exec, ags request -i cyberpunk 'modal themesettings'"
          # Mismo mensaje de socket que dispara el click en el ícono "R" del
          # dock (confirmado contra scripts/screenrecord) - un solo bind,
          # no dos formas distintas de hacer lo mismo.
          "$mod SHIFT, R, HUD: Grabar pantalla (toggle), exec, ags request -i cyberpunk record-region"
          "$mod SHIFT, Z, HUD: Mostrar/ocultar HUD completo, exec, ags request -i cyberpunk toggle-hud"
          # Rueda de apps estilo Kiroshi (openAppsMenu). En el original es
          # SUPER+TAB -> scripts/launcher, que manda "apps-menu" al socket;
          # la auditoría de arriba no lo vio porque está en un CD.bind()
          # suelto de keybinds.lua, no en THEME_ACTIONS. $mod+D sigue
          # siendo wofi (el request "launcher" es eso mismo, no hace falta).
          # SHIFT (no $mod solo) por la convención unificada de HUD de arriba.
          "$mod SHIFT, Tab, HUD: Menú de aplicaciones (rueda), exec, ags request -i cyberpunk apps-menu"

          # Gestión de ventanas del diseño original - estas son 100%
          # Hyprland nativo, no pasan por el HUD (no tiene sentido pedirle
          # a cyber-shell algo que el compositor ya resuelve solo).
          "$mod, F, Ventanas: Alternar flotante, togglefloating"
          "$mod SHIFT, F, Ventanas: Pantalla completa, fullscreen"
          "$mod SHIFT, K, Ventanas: Forzar cierre (crosshair), exec, hyprctl kill"
        ]
        ++ (
          builtins.concatLists (map (dir: [
            "$mod, ${dir.key}, Ventanas: Foco ${dir.label}, movefocus, ${dir.dispatch}"
            "$mod SHIFT, ${dir.key}, Ventanas: Mover ventana ${dir.label}, movewindow, ${dir.dispatch}"
            "CTRL SHIFT, ${dir.key}, Ventanas: Redimensionar ${dir.label}, resizeactive, ${dir.resize}"
          ]) [
            { key = "left"; label = "a la izquierda"; dispatch = "l"; resize = "-20 0"; }
            { key = "right"; label = "a la derecha"; dispatch = "r"; resize = "20 0"; }
            { key = "up"; label = "hacia arriba"; dispatch = "u"; resize = "0 -20"; }
            { key = "down"; label = "hacia abajo"; dispatch = "d"; resize = "0 20"; }
          ])
        )
        ++ (
          # $mod+1..5 va al workspace, $mod+shift+1..5 mueve la ventana activa
          builtins.concatLists (map (i: [
            "$mod, ${toString i}, Workspaces: Ir al workspace ${toString i}, workspace, ${toString i}"
            "$mod SHIFT, ${toString i}, Workspaces: Mover ventana al workspace ${toString i}, movetoworkspace, ${toString i}"
          ]) [ 1 2 3 4 5 ])
        );

      bindmd = [
        "$mod, mouse:272, Ventanas (mouse): Mover ventana, movewindow"
        "$mod, mouse:273, Ventanas (mouse): Redimensionar ventana, resizewindow"
      ];

      # Moonlight (script "pc", home.packages del repo privado) siempre
      # en pantalla completa y sin decoraciones - sin esto Hyprland lo
      # tilea como ventana normal (constatado en vivo: quedaba en 944x524
      # en vez de ocupar el monitor, aunque moonlight-qt reciba
      # --display-mode fullscreen). class real confirmado en vivo con
      # hyprctl clients: com.moonlight_stream.Moonlight (su app_id de
      # Wayland). La sintaxis CLÁSICA de windowrule ("regla,matcher") ya
      # no existe en esta versión de Hyprland pese a configType =
      # "hyprlang" (probado en vivo: "invalid field X: missing a value")
      # - hace falta la sintaxis nueva "match:campo valor, campo valor".
      # Campos probados en vivo uno por uno con `hyprctl keyword
      # windowrule` antes de escribir esto (bordersize/border/shadow/
      # noborder/noshadow no son campos válidos - tiran "invalid field
      # type"; solo funcionan fullscreen y decorate).
      windowrule = [
        "match:class com\\.moonlight_stream\\.Moonlight, fullscreen on"
        "match:class com\\.moonlight_stream\\.Moonlight, decorate off"
      ];
    };
  };

  # waybar y mako se sacaron del todo (no solo deshabilitados): cyber-shell
  # ya cubre stats/notificaciones/tray, mantener ~130 líneas de config sin
  # usar no aporta nada (historial completo en git si hace falta volver).

  # hyprpaper (v0.8, backend hyprtoolkit/EGL) no pinta nada en esta VM:
  # "Monitor Virtual-1 has no target" + errores EGL_BAD_PARAMETER contra
  # el GPU virtual de la VM. swaybg no necesita EGL (dibuja por wl_shm,
  # software puro) — más simple y no le importa el GPU virtual. Se lanza
  # por exec-once arriba.
  # hyprpolkitagent NO va acá: su binario vive en libexec/, no en bin/,
  # así que meterlo en home.packages no aporta nada al PATH - se referencia
  # directo por ruta completa en el exec-once de arriba.
  home.packages = with pkgs; [
    grim
    slurp
    wl-clipboard
    playerctl
    blueman
    cliphist
    swaybg
    kbLayoutToggle
    rebuild
    ocultarVentanas
    libnotify
    # wofi - lo usan $launcher (Mod+D) y el historial de portapapeles
    # (Mod+V) más arriba. Mismo bug que lsd en zsh.nix: declarado en un
    # exec/bind pero nunca instalado (encontrado en uso real).
    wofi
  ];

  # Tema "hackerman" morado/oscuro con transparencias, pedido explicito
  # en base a una referencia (Dracula + Tela-circle + Bibata-Ice).
  gtk = {
    enable = true;
    theme = {
      name = "Dracula";
      package = pkgs.dracula-theme;
    };
    iconTheme = {
      name = "Tela-circle-dark";
      package = pkgs.tela-circle-icon-theme;
    };
  };

  home.pointerCursor = {
    name = "Bibata-Modern-Ice";
    package = pkgs.bibata-cursors;
    size = 24;
    gtk.enable = true;
  };

  # El campo muestra lo que PAM está pidiendo ($PAMPROMPT): con
  # workos.security.totp son dos pasos (código de "desbloqueo" y
  # contraseña) y hay que ver cuál toca. Servicio PAM propio: ver
  # modules/security.nix.
  programs.hyprlock = {
    enable = true;
    settings = {
      general.hide_cursor = true;
      background = [{ color = "rgba(10, 8, 20, 1.0)"; }];
      label = [{
        text = "$TIME";
        font_size = 64;
        color = "rgba(200, 160, 255, 1.0)";
        position = "0, 120";
        halign = "center";
        valign = "center";
      }];
      input-field = [{
        size = "360, 56";
        position = "0, -40";
        halign = "center";
        valign = "center";
        outline_thickness = 2;
        outer_color = "rgba(150, 90, 255, 1.0)";
        inner_color = "rgba(20, 16, 36, 1.0)";
        font_color = "rgba(230, 220, 255, 1.0)";
        placeholder_text = "$PAMPROMPT";
        fail_text = "$PAMFAIL";
        fade_on_empty = false;
      }];
    };
  };

  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "pidof hyprlock || hyprlock";
        before_sleep_cmd = "loginctl lock-session";
      };
      listener = [
        { timeout = osConfig.workos.security.lockTimeout; on-timeout = "loginctl lock-session"; }
        { timeout = 2 * osConfig.workos.security.lockTimeout; on-timeout = "systemctl suspend"; }
      ];
    };
  };

  programs.wofi.enable = true;
}
