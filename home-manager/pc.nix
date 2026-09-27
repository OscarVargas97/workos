# `pc`: muestra en esta máquina, a pantalla completa, el monitor de otro
# PC que transmite con Sunshine (Moonlight como cliente). Solo video: el
# audio sigue sonando en el PC remoto (--audio-on-host). Se activa con
# workos.pc.enable (modules/workos.nix); las reglas de ventana de
# Moonlight están en hyprland.nix.
{ pkgs, osConfig, ... }:
{
  home.packages = [
    pkgs.moonlight-qt
    (pkgs.writeShellScriptBin "pc" ''
      # Nada fijo: el host es el primero emparejado en Moonlight (por
      # nombre; Moonlight descubre su IP actual por mDNS). Si no lo
      # encuentra (otra red/subred), PC_HOST=<ip> pc una vez: Moonlight
      # guarda la IP nueva para ese host y "pc" vuelve a andar solo.
      conf="$HOME/.config/Moonlight Game Streaming Project/Moonlight.conf"
      host=''${PC_HOST:-$(sed -n 's/^[0-9]*\\hostname=//p' "$conf" 2>/dev/null | head -1)}
      ml=${pkgs.moonlight-qt}/bin/moonlight
      # pkill/pgrep -x moonlight NUNCA matchean: el wrapper de Nix
      # (makeWrapper) corre como proceso real con comm truncado a
      # ".moonlight-wrap" (15 chars, límite de /proc/*/comm), no
      # "moonlight" - bug real, encontrado en vivo: "pc off" nunca
      # mataba nada, y el guard de "ya está corriendo" tampoco
      # detectaba una instancia previa. Matchea por el path completo
      # del binario real en vez del nombre del proceso.
      # permite lanzarlo por ssh: engancha la sesión gráfica local
      export XDG_RUNTIME_DIR=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
      [ -z "$WAYLAND_DISPLAY" ] && export WAYLAND_DISPLAY=$(basename "$(ls $XDG_RUNTIME_DIR/wayland-? 2>/dev/null | head -1)")
      [ -z "$HYPRLAND_INSTANCE_SIGNATURE" ] && export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t $XDG_RUNTIME_DIR/hypr 2>/dev/null | head -1)
      export DISPLAY=''${DISPLAY:-:0}
      case "$1" in
        off)  pkill -f "$ml stream"; exit ;;
        pair) exec $ml pair "''${3:?uso: pc pair <pin> <nombre.local-o-ip>}" --pin "$2" ;;
        # alterna pantalla completa <-> ventana (la windowrule solo aplica al abrir)
        full) hyprctl dispatch focuswindow class:com.moonlight_stream.Moonlight >/dev/null && exec hyprctl dispatch fullscreen 0 ;;
      esac
      [ -n "$host" ] || { echo "sin PC emparejado: pc pair <pin> <nombre.local-o-ip>" >&2; exit 1; }
      pgrep -f "$ml stream" >/dev/null && exit 0
      # Resolución: workos.pc.resolution, o si no la del monitor con foco;
      # Hz: los del monitor. PC_RES=WxH / PC_FPS=N para forzar otros. El PC
      # remoto tiene que ofrecer ese modo (en Windows: lista de
      # resoluciones del Virtual Display Driver).
      mon=$(hyprctl monitors -j 2>/dev/null | ${pkgs.jq}/bin/jq -r 'map(select(.focused))[0] // .[0] | "\(.width)x\(.height) \(.refreshRate | round)"')
      res=''${PC_RES:-${if osConfig.workos.pc.resolution != null then osConfig.workos.pc.resolution else "\${mon% *}"}}; fps=''${PC_FPS:-''${mon#* }}
      [[ $res =~ ^[0-9]+x[0-9]+$ ]] || res=1920x1080
      [[ $fps =~ ^[0-9]+$ ]] || fps=60
      setsid -f $ml stream "$host" Desktop --resolution "$res" --fps "$fps" --display-mode fullscreen --audio-on-host >/dev/null 2>&1
    '')
  ];
}
