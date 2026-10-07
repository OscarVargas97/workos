# slk (cliente TUI de Slack, ver pkgs/slk.nix) corriendo como servicio de
# usuario, para que las notificaciones lleguen con la ventana cerrada.
#
# Por qué un servicio y no "abrilo cuando lo necesites": en Linux no hay
# push del sistema operativo para Slack (no existe un equivalente a
# FCM/APNs del teléfono). Cualquier cliente de escritorio - el oficial de
# Electron incluido - mantiene su propio websocket abierto, y si nadie lo
# mantiene, Slack no tiene por dónde avisar. slk conectado en segundo
# plano son ~38 MB medidos, contra ~500 MB del cliente oficial.
#
# slk es un TUI: no arranca sin un TTY (bubbletea aborta con "could not
# open TTY"), así que el servicio lo corre dentro de un pty persistente de
# dtach. El comando `slk` de la terminal no levanta otra instancia, se
# engancha a esa: dos procesos a la vez pelearían por el mismo SQLite
# (~/.local/share/slk/cache.db).
{ pkgs, workosServices, ... }:
let
  slk = pkgs.callPackage ./pkgs/slk.nix { };

  # En XDG_RUNTIME_DIR (tmpfs, 0700, se limpia sola al cerrar sesión): el
  # socket da control total sobre la sesión de Slack, no va a /tmp.
  #
  # Dos escrituras de la misma ruta porque systemd no es un shell: en las
  # unidades solo expande sus propios especificadores (%t = XDG_RUNTIME_DIR),
  # no `${VAR:-default}` ni `$(...)`, que ahí quedarían literales.
  socketUnit = "%t/slk.sock";
  socketShell = "\${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/slk.sock";

  # El wrapper se queda con el nombre `slk` y es el único que entra al
  # PATH; al binario real se llega por su ruta del store, así que no hay
  # ambigüedad sobre cuál corre la persona.
  slkAttach = pkgs.writeShellScriptBin "slk" ''
    set -euo pipefail

    SOCKET="${socketShell}"

    # Los subcomandos de gestión no son la TUI y no tocan el cache: se
    # pasan derecho al binario real (agregar/quitar workspaces, --version).
    case "''${1:-}" in
      --*) exec ${slk}/bin/slk "$@" ;;
    esac

    if [ ! -S "$SOCKET" ]; then
      ${pkgs.systemd}/bin/systemctl --user start slk.service || true
      # El socket lo crea dtach al arrancar; sin esta espera el attach de
      # abajo corre antes de que exista y falla en el primer `slk` del día.
      for _ in $(${pkgs.coreutils}/bin/seq 1 50); do
        [ -S "$SOCKET" ] && break
        ${pkgs.coreutils}/bin/sleep 0.1
      done
    fi

    if [ ! -S "$SOCKET" ]; then
      # Caso típico: está dado de baja desde el panel del HUD, y entonces
      # ExecCondition saltó la unidad y nunca hubo socket que crear. Una
      # unidad saltada así queda con Result=exec-condition (ConditionResult
      # es de las directivas Condition*=, que son otra cosa).
      if ${pkgs.systemd}/bin/systemctl --user show slk.service -p Result --value | ${pkgs.gnugrep}/bin/grep -qx exec-condition; then
        echo "slk está dado de baja. Reactivalo desde el HUD (Super+Shift+S) o con: workos-services enable slk" >&2
      else
        echo "slk no pudo arrancar. Mirá: workos-services logs slk" >&2
      fi
      exit 1
    fi

    # -r winch: al reengancharse, dtach le manda SIGWINCH al programa para
    # que se redibuje al tamaño de ESTA terminal (slk arrancó contra un pty
    # sin medidas reales). Ctrl+\ despega sin cerrar la sesión.
    exec ${pkgs.dtach}/bin/dtach -a "$SOCKET" -r winch
  '';
in
{
  home.packages = [ slkAttach ];

  systemd.user.services.slk = {
    Unit = {
      Description = "slk - Slack en segundo plano (notificaciones con la ventana cerrada)";
      # Las notificaciones van por D-Bus al daemon del HUD, que vive en la
      # sesión gráfica: fuera de ella el servicio no tendría a quién
      # avisarle.
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };

    Service = {
      Type = "simple";
      ExecCondition = workosServices.execCondition;
      # dtach -N: crea el socket y corre el programa en primer plano, sin
      # daemonizar (lo que systemd espera de un Type=simple) y sin
      # engancharse a ninguna terminal.
      ExecStart = "${pkgs.dtach}/bin/dtach -N ${socketUnit} ${slk}/bin/slk";
      # Si quedó un socket de una sesión anterior que murió mal, dtach -N
      # se niega a arrancar.
      ExecStartPre = "${pkgs.coreutils}/bin/rm -f ${socketUnit}";
      # xterm-256color y no xterm-kitty: el pty del servicio sobrevive a la
      # terminal desde la que te enganchás, así que tiene que ser un TERM
      # que funcione en cualquiera. El costo es que las imágenes caen al
      # modo halfblock en vez del protocolo de kitty.
      Environment = [ "TERM=xterm-256color" ];
      Restart = "always";
      RestartSec = 5;
    };

    Install.WantedBy = [ "graphical-session.target" ];
  };
}
