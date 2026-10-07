# Servicios de usuario de WorkOS: registro, baja persistente y CLI.
#
# Problema que resuelve: las unidades systemd de usuario las genera Home
# Manager como symlinks al store y las vuelve a poner en cada switch, así
# que `systemctl --user disable` no sobrevive a un `rebuild`. Para poder
# dar de baja un servicio de verdad (y que siga de baja), la decisión vive
# en un archivo de estado del usuario y se consulta en cada arranque con
# `ExecCondition` - que marca la unidad como "saltada", no como fallida.
#
# Registro: un servicio es "de WorkOS" si su ExecCondition pasa por el
# guard de abajo - que es justo lo que ya necesita para poder darse de
# baja. No hay lista hardcodeada en ningún lado, ni acá ni en el HUD:
# `workos-services list` los descubre preguntándole a systemd quién lleva
# ese guard, así que un servicio nuevo aparece solo en el panel.
#
# Se usa el ExecCondition como marca, y no un Documentation propio, porque
# systemd valida los esquemas de Documentation y rechaza uno inventado
# ("Invalid URL in Documentation"); las claves X- propias, en cambio, no
# se exponen por `systemctl show`. De yapa, la marca no puede
# desincronizarse del mecanismo: un servicio marcado sin guard (o al
# revés) es imposible de escribir.
{ pkgs, ... }:
let
  # Se expande en runtime dentro de los scripts, no en tiempo de
  # evaluación: la ruta del home no se hornea en el store (AGENTS.md §2).
  stateFile = "\${XDG_CONFIG_HOME:-$HOME/.config}/work-os/services.disabled";

  # ExecCondition: 0 = arranca, 1..254 = se salta limpiamente (la unidad
  # queda inactive, no failed, así el panel no la muestra como rota).
  guard = pkgs.writeShellScriptBin "workos-service-enabled" ''
    set -euo pipefail
    unit="''${1:?uso: workos-service-enabled <unidad>}"
    state="${stateFile}"
    [ -f "$state" ] || exit 0
    # -x: línea completa, para que "slk" no matchee "slk-algo".
    if ${pkgs.gnugrep}/bin/grep -qxF "$unit" "$state"; then exit 1; fi
    exit 0
  '';

  cli = pkgs.writeShellScriptBin "workos-services" ''
    set -euo pipefail

    STATE="${stateFile}"
    # El nombre del binario, no su ruta del store: esa cambia de hash en
    # cada rebuild, y las unidades que siguen cargadas en memoria apuntan
    # todavía a la anterior - con la ruta completa, el panel las perdería
    # de vista hasta el próximo `systemctl --user daemon-reload`.
    MARKER="workos-service-enabled"
    SYSTEMCTL=${pkgs.systemd}/bin/systemctl
    JQ=${pkgs.jq}/bin/jq
    AWK=${pkgs.gawk}/bin/awk

    # Los servicios de WorkOS son los que corren el guard como
    # ExecCondition. `systemctl show '*.service'` imprime un bloque por
    # unidad separado por una línea en blanco; se filtran los bloques que
    # mencionan el guard y se devuelve el Id de cada uno.
    unidades() {
      {
        "$SYSTEMCTL" --user show '*.service' -p Id -p ExecCondition 2>/dev/null \
          | "$AWK" -v m="$MARKER" '
              BEGIN { RS = "" }
              index($0, m) {
                for (i = 1; i <= NF; i++)
                  if ($i ~ /^Id=/) { sub(/^Id=/, "", $i); print $i }
              }'

        # El glob de arriba solo ve unidades cargadas, y systemd descarga
        # las que están detenidas: un servicio dado de baja desaparecería
        # del panel justo cuando hace falta poder reactivarlo. Se agregan
        # por nombre desde el archivo de estado; `show` sobre uno suelto sí
        # carga la unidad. Se confirma que lleve el guard para no listar lo
        # que alguien haya escrito a mano en el archivo.
        if [ -f "$STATE" ]; then
          while IFS= read -r n; do
            [ -n "$n" ] || continue
            if "$SYSTEMCTL" --user show "$n.service" -p ExecCondition 2>/dev/null \
                 | ${pkgs.gnugrep}/bin/grep -q "$MARKER"; then
              printf '%s.service\n' "$n"
            fi
          done < "$STATE"
        fi
      } | sort -u
    }

    esta_de_baja() {
      [ -f "$STATE" ] || return 1
      ${pkgs.gnugrep}/bin/grep -qxF "''${1%.service}" "$STATE"
    }

    prop() {
      "$SYSTEMCTL" --user show "$1" -p "$2" --value 2>/dev/null || true
    }

    cmd_list() {
      local primero=1 u baja
      printf '['
      for u in $(unidades); do
        [ "$primero" = 1 ] || printf ','
        primero=0
        baja=false
        esta_de_baja "$u" && baja=true
        "$JQ" -nc \
          --arg id "$u" \
          --arg nombre "''${u%.service}" \
          --arg desc "$(prop "$u" Description)" \
          --arg active "$(prop "$u" ActiveState)" \
          --arg sub "$(prop "$u" SubState)" \
          --arg result "$(prop "$u" Result)" \
          --arg tipo "$(prop "$u" Type)" \
          --argjson baja "$baja" \
          '{id:$id, nombre:$nombre, descripcion:$desc, active:$active, sub:$sub, result:$result, tipo:$tipo, deBaja:$baja}'
      done
      printf ']\n'
    }

    # La baja se anota sin el sufijo .service para que el archivo se pueda
    # leer y editar a mano; el guard recibe %N (el nombre sin sufijo), así
    # que compara contra lo mismo.
    cmd_disable() {
      local n="''${1%.service}"
      ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$STATE")"
      ${pkgs.coreutils}/bin/touch "$STATE"
      ${pkgs.gnugrep}/bin/grep -qxF "$n" "$STATE" || printf '%s\n' "$n" >> "$STATE"
      "$SYSTEMCTL" --user stop "$n.service" 2>/dev/null || true
    }

    cmd_enable() {
      local n="''${1%.service}" tmp
      [ -f "$STATE" ] || return 0
      # Se reescribe vía temporal en vez de `sed -i`: editar en sitio un
      # archivo que el guard podría estar leyendo en ese mismo instante
      # deja una ventana en la que se lo ve vacío.
      tmp=$(${pkgs.coreutils}/bin/mktemp)
      ${pkgs.gnugrep}/bin/grep -vxF "$n" "$STATE" > "$tmp" || true
      ${pkgs.coreutils}/bin/mv "$tmp" "$STATE"
    }

    case "''${1:-list}" in
      list)    cmd_list ;;
      start)   "$SYSTEMCTL" --user start "''${2:?falta el servicio}" ;;
      stop)    "$SYSTEMCTL" --user stop "''${2:?falta el servicio}" ;;
      restart) "$SYSTEMCTL" --user restart "''${2:?falta el servicio}" ;;
      enable)  cmd_enable "''${2:?falta el servicio}"; "$SYSTEMCTL" --user start "''${2%.service}.service" || true ;;
      disable) cmd_disable "''${2:?falta el servicio}" ;;
      logs)    ${pkgs.systemd}/bin/journalctl --user -u "''${2:?falta el servicio}" -n 200 --no-pager ;;
      *)
        ${pkgs.coreutils}/bin/cat <<'USO'
    uso: workos-services [list|start|stop|restart|enable|disable|logs] [servicio]

      list      JSON con los servicios de WorkOS y su estado
      start     arranca ahora (no toca la baja)
      stop      detiene ahora (vuelve a arrancar en el próximo login)
      disable   lo da de baja: no arranca más hasta reactivarlo
      enable    lo reactiva y lo arranca
      logs      últimas 200 líneas del journal del servicio
    USO
        exit 1 ;;
    esac
  '';
in
{
  # Se expone al resto de los módulos de Home Manager: poner esto en
  # `Service.ExecCondition` es lo único que hace falta para que un
  # servicio se pueda dar de baja y aparezca en el panel del HUD. %N es el
  # nombre de la unidad sin sufijo, que es como se anota la baja.
  _module.args.workosServices = {
    execCondition = "${guard}/bin/workos-service-enabled %N";
  };

  home.packages = [ guard cli ];
}
