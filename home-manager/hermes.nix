# Hermes Agent (Nous Research), alternativa a Claude Code. Se activa con
# workos.hermes.enable (modules/workos.nix). No está en nixpkgs: su propio
# instalador clona un repo git a $HOME/.hermes y baja Python/uv/node ahí
# (mismo patrón que uv/rustup en hosts/vm/configuration.nix, por eso
# nix-ld ya está prendido). El instalador se vendoriza en
# work-os/scripts/vendor para no ejecutar código remoto sin pin -
# actualizarlo es traer una copia nueva a mano, igual que un input de
# flake. `hermes-bootstrap` corre solo en cada login (servicio de abajo)
# y también se puede correr a mano; repetirlo no hace daño.
{ pkgs, ... }:
let
  hermesInstaller = ../work-os/scripts/vendor/hermes-install.sh;
  hermesBootstrap = pkgs.writeShellScriptBin "hermes-bootstrap" ''
    set -euo pipefail
    HERMES_HOME="$HOME/.hermes"
    HERMES_BIN="$HOME/.local/bin/hermes"
    mkdir -p "$HERMES_HOME/logs"
    log() { printf '[hermes-bootstrap] %s\n' "$1"; }

    # Instala solo si hace falta. Actualizaciones posteriores son cosa
    # de `hermes update`, no de este bootstrap.
    if [ ! -x "$HERMES_BIN" ]; then
      log "primera instalación de Hermes Agent en esta máquina"
      if ! ${pkgs.bash}/bin/bash ${hermesInstaller} --non-interactive \
          >>"$HERMES_HOME/logs/bootstrap.log" 2>&1; then
        log "el instalador terminó con error (ver $HERMES_HOME/logs/bootstrap.log)"
      fi
    fi

    if [ ! -x "$HERMES_BIN" ]; then
      log "hermes no quedó instalado; abortando"
      exit 1
    fi

    # Plugin que corre los turnos de Hermes sobre la suscripción de Claude
    # Pro/Max vía el CLI `claude` (Agent SDK) en vez de una API key aparte
    # (claude-code ya viene en common.nix). Requiere `claude login` hecho
    # a mano - la IA nunca hace ese login.
    PLUGIN_DIR="$HERMES_HOME/plugins/claude-subscription-directsdk-experimental"
    if [ ! -d "$PLUGIN_DIR" ]; then
      log "instalando plugin claude-subscription-directsdk"
      "$HERMES_BIN" plugins install claude-subscription-directsdk \
        >>"$HERMES_HOME/logs/bootstrap.log" 2>&1 \
        || log "no se pudo instalar el plugin (ver log)"
    fi
    if [ -d "$PLUGIN_DIR" ]; then
      "$HERMES_BIN" plugins enable claude-subscription-directsdk-experimental \
        >>"$HERMES_HOME/logs/bootstrap.log" 2>&1 || true
    fi

    # Solo fija el modelo si el config sigue con el "provider: auto" de
    # fábrica (cli-config.yaml.example, verificado contra una instalación
    # limpia el 2026-09-25) - si la persona ya eligió otro modelo a mano
    # con `hermes model`, este bootstrap no se lo pisa después.
    CONFIG="$HERMES_HOME/config.yaml"
    if [ -f "$CONFIG" ] && grep -qE '^  provider: "auto"$' "$CONFIG"; then
      log "configurando modelo por defecto: suscripción de Claude vía claude-subscription-directsdk"
      sed -i \
        -e '0,/^  provider: "auto"$/s//  provider: "claude-subscription-directsdk-experimental"/' \
        -e '0,/^  default: "anthropic\/.*"$/s//  default: "sonnet"/' \
        "$CONFIG"
    fi
    log "listo"
  '';
in
{
  # $HOME/.local/bin en PATH (hermes queda publicado ahí) - declarado
  # acá a propósito: el instalador de Hermes busca esta misma línea en
  # ~/.zshrc/~/.zprofile antes de intentar agregarla él mismo, y como
  # los gestiona Home Manager (symlink de solo lectura al store), esa
  # escritura falla.
  programs.zsh.initContent = ''
    export PATH="$HOME/.local/bin:$PATH"
  '';
  home.file.".zprofile".text = ''
    export PATH="$HOME/.local/bin:$PATH"
  '';

  home.packages = [ hermesBootstrap ];

  # Deja Hermes Agent instalado y con el plugin de suscripción de Claude
  # sin intervención: oneshot en cada login; la primera vez hace el
  # trabajo pesado, después son chequeos baratos. `claude login` queda
  # a mano (OAuth por máquina).
  systemd.user.services.hermes-agent-bootstrap = {
    Unit.Description = "Bootstrap de Hermes Agent (plugin de suscripción Claude)";
    Service = {
      Type = "oneshot";
      ExecStart = "${hermesBootstrap}/bin/hermes-bootstrap";
    };
    Install.WantedBy = [ "default.target" ];
  };
}
