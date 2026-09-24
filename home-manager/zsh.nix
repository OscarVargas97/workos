# zsh de uso diario, portado de la laptop Fedora original (ver
# DECISIONS.md #9 — traducido a opciones de home-manager, nada de rutas
# absolutas fijas). NVM/pnpm/conda quedaron afuera a propósito: son
# runtimes por-proyecto, van a Fase 3 (devenv/direnv), no a la base.
{ pkgs, ... }:
let
  # work-os/cli/work empaquetado vía Nix (no una ruta de checkout en
  # disco - "nixos-rebuild switch --flake github:..." baja el flake
  # directo al store, la máquina destino nunca tiene un `git clone` de
  # nixos-config. Un `$HOME/workos/nixos-config/...` hardcodeado
  # funciona en la máquina de desarrollo pero no en la instalada - bug
  # real encontrado probando en la VM real, no supuesto).
  work-cli = pkgs.writeShellScriptBin "work-cli" (builtins.readFile ../work-os/cli/work);

  # work-os/cli/docs/ (Fase 9/11) - los .py se importan entre sí
  # (work_docs.py y sync_docs.py hacen `import notion_adapter`, y ambos
  # `from doc_cache import cache_path`), así que necesitan vivir juntos
  # en el mismo directorio del store - writeShellScriptBin no sirve para
  # esto (un solo archivo), por eso runCommand copia todo el módulo.
  # Los -bin solo arrancan uv (ya global, Fase 3) sobre el entrypoint
  # correspondiente - uv resuelve pyyaml/httpx solo, vía el header
  # PEP 723 de cada script.
  work-docs-src = pkgs.runCommand "work-docs-src" { } ''
    mkdir -p "$out"
    cp ${../work-os/cli/docs/work_docs.py} "$out/work_docs.py"
    cp ${../work-os/cli/docs/sync_docs.py} "$out/sync_docs.py"
    cp ${../work-os/cli/docs/notion_adapter.py} "$out/notion_adapter.py"
    cp ${../work-os/cli/docs/slack_adapter.py} "$out/slack_adapter.py"
    cp ${../work-os/cli/docs/doc_cache.py} "$out/doc_cache.py"
  '';
  work-docs-bin = pkgs.writeShellScriptBin "work-docs" ''
    exec ${pkgs.uv}/bin/uv run "${work-docs-src}/work_docs.py" "$@"
  '';
  work-docs-sync-bin = pkgs.writeShellScriptBin "work-docs-sync" ''
    exec ${pkgs.uv}/bin/uv run "${work-docs-src}/sync_docs.py" "$@"
  '';
  # `work vault ...` (DECISIONS.md #15). PATH se antepone, no se reemplaza:
  # fusermount tiene que seguir saliendo de /run/wrappers (setuid).
  workos-vault = pkgs.writeShellScriptBin "workos-vault" ''
    export PATH=${pkgs.lib.makeBinPath [ pkgs.gocryptfs pkgs.rsync pkgs.util-linux pkgs.rbw pkgs.git pkgs.diffutils pkgs.findutils pkgs.localsend ]}:$PATH
    exec ${pkgs.bash}/bin/bash ${../work-os/scripts}/vault.sh "$@"
  '';
in
{
  programs.zsh = {
    enable = true;
    # Los de Fedora (/usr/share/zsh-syntax-highlighting, etc) son
    # opciones nativas del módulo acá, no hay que instalar/sourcear nada
    # a mano.
    syntaxHighlighting.enable = true;
    autosuggestion.enable = true;

    history = {
      size = 1000;
      save = 1000;
      path = "$HOME/.zsh_history";
      ignoreAllDups = true;
      share = true;
    };

    shellAliases = {
      ll = "lsd -lh --group-dirs=first";
      la = "lsd -a --group-dirs=first";
      l = "lsd --group-dirs=first";
      lla = "lsd -lha --group-dirs=first";
      ls = "lsd --group-dirs=first";
      cat = "bat";
      kitty = "kitty --single-instance";
      # asume la estructura de carpetas que ya usás, vía $HOME (no
      # /home/$USER a mano) - portable para cualquier persona/máquina.
      # ~/Documentos viene de xdg.userDirs (ver common.nix).
      cdgithub = "cd $HOME/Documentos/Repos/My-Github/";
      # Repos reales de trabajo/personales (migrate-pc.sh, "Repos/<Empresa>"
      # y "Repos/Externos" - ver DECISIONS.md #14). Un alias por empresa
      # (cd<empresa>) va en el repo privado.
      cdrepos = "cd $HOME/Repos";
      cdexternos = "cd $HOME/Repos/Externos";
      sail = "[ -f sail ] && bash sail || bash vendor/bin/sail";
      # Dos cuentas de Claude Pro (trabajo/personal): CLAUDE_CONFIG_DIR
      # separa las credenciales de cada una, sin relogin en cada switch.
      claudew = "CLAUDE_CONFIG_DIR=$HOME/.claude-work claude";
      claudep = "CLAUDE_CONFIG_DIR=$HOME/.claude-personal claude";
    };

    initContent = ''
      # Powerlevel10k instant prompt - debe ir primero.
      if [[ -r "''${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-''${(%):-%n}.zsh" ]]; then
        source "''${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-''${(%):-%n}.zsh"
      fi

      bindkey -e

      source ${pkgs.zsh-powerlevel10k}/share/zsh/themes/powerlevel10k/powerlevel10k.zsh-theme
      source ${./assets/p10k.zsh}

      # Doble-ESC en la linea de comando: antepone sudo (reemplaza el
      # plugin zsh-sudo de oh-my-zsh, sin traer todo oh-my-zsh por esto).
      sudo-command-line() {
        [[ -z $BUFFER ]] && zle up-history
        if [[ $BUFFER == sudo\ * ]]; then
          LBUFFER="''${LBUFFER#sudo }"
        else
          LBUFFER="sudo $LBUFFER"
        fi
      }
      zle -N sudo-command-line
      bindkey "\e\e" sudo-command-line

      # Funciones propias
      function mkt(){
        mkdir {nmap,content,exploits,scripts}
      }

      function extractPorts(){
        ports="$(cat $1 | grep -oP '\d{1,5}/open' | awk '{print $1}' FS='/' | xargs | tr ' ' ',')"
        ip_address="$(cat $1 | grep -oP '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}' | sort -u | head -n 1)"
        echo -e "\n[*] Extracting information...\n" > extractPorts.tmp
        echo -e "\t[*] IP Address: $ip_address"  >> extractPorts.tmp
        echo -e "\t[*] Open ports: $ports\n"  >> extractPorts.tmp
        echo $ports | tr -d '\n' | wl-copy
        echo -e "[*] Ports copied to clipboard\n"  >> extractPorts.tmp
        cat extractPorts.tmp; rm extractPorts.tmp
      }

      function man() {
        env \
        LESS_TERMCAP_mb=$'\e[01;31m' \
        LESS_TERMCAP_md=$'\e[01;31m' \
        LESS_TERMCAP_me=$'\e[0m' \
        LESS_TERMCAP_se=$'\e[0m' \
        LESS_TERMCAP_so=$'\e[01;44;33m' \
        LESS_TERMCAP_ue=$'\e[0m' \
        LESS_TERMCAP_us=$'\e[01;32m' \
        man "$@"
      }

      function fzf-lovely(){
        if [ "$1" = "h" ]; then
          fzf -m --reverse --preview-window down:20 --preview '[[ $(file --mime {}) =~ binary ]] &&
                        echo {} is a binary file ||
                         (bat --style=numbers --color=always {} ||
                          highlight -O ansi -l {} ||
                          coderay {} ||
                          rougify {} ||
                          cat {}) 2> /dev/null | head -500'
        else
          fzf -m --preview '[[ $(file --mime {}) =~ binary ]] &&
                         echo {} is a binary file ||
                         (bat --style=numbers --color=always {} ||
                          highlight -O ansi -l {} ||
                          coderay {} ||
                          rougify {} ||
                          cat {}) 2> /dev/null | head -500'
        fi
      }

      function rmk(){
        scrub -p dod $1
        shred -zun 10 -v $1
      }

      # Work OS CLI (Fase 5, work-os/cli/work, empaquetado como work-cli
      # más arriba) - envuelto en función de shell porque "enter" hace
      # cd: un binario no puede cambiar el directorio del shell que lo
      # llamó, solo una función puede.
      function work(){
        local bin="${work-cli}/bin/work-cli"
        if [ "$1" = "enter" ]; then
          local dest
          dest="$("$bin" "$@")" || return $?
          cd "$dest"
        else
          "$bin" "$@"
        fi
      }
    '';
  };

  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
  };

  home.packages = with pkgs; [
    zsh-powerlevel10k
    scrub # usado por rmk
    # lsd - usado por los alias ll/la/l/lla/ls de arriba. Bug real
    # (encontrado en uso real, no en una auditoría): estaba declarado en
    # shellAliases pero nunca instalado, los alias fallaban con
    # "command not found: lsd".
    lsd
    # work-cli en el PATH (además de la función `work` de arriba, que
    # es la que usa un humano a mano) - lo necesita el MCP server de
    # secretos (work-os/mcp/secrets/server.py, Fase 6) para invocar
    # `work secret get` sin depender de que zsh cargue funciones.
    work-cli
    # work-docs en el PATH (Fase 9) - lo invoca `work docs` (work-os/cli/work)
    # después de resolver la empresa/company-context del proyecto actual.
    work-docs-bin
    # work-docs-sync en el PATH (Fase 11) - lo invoca `work docs sync`.
    work-docs-sync-bin
    # work vault (vault/ cifrado con gocryptfs).
    workos-vault
  ];

  # secrets-policy.yaml en ~/.config/work-os/ la publica
  # modules/workos.nix (opción workos.secretsPolicy): a diferencia de
  # projects.conf/companies.conf, esta SÍ la gestiona Nix - es la policy
  # de seguridad, tiene que salir de un repo versionado (el privado), no
  # de un archivo que cualquier proceso local podría editar.

  # Fase 11 (pedido explícito): sync de company-context docs al
  # iniciar sesión, además de "work docs sync" a mano. Type=oneshot, sin
  # reintentos agresivos - si Bitwarden todavía no está desbloqueado en
  # ese momento (la IA nunca lo desbloquea, eso es siempre manual, ver
  # DECISIONS.md #2), sync_docs.py falla ese secreto puntual con un
  # aviso y sigue con el resto, no rompe el login. Vuelve a estar al día
  # la próxima vez que se corra (a mano, o el siguiente login).
  systemd.user.services.company-context-docs-sync = {
    Unit.Description = "Sync de company-context docs (Fase 11, work docs sync)";
    Service = {
      Type = "oneshot";
      ExecStart = "${work-docs-sync-bin}/bin/work-docs-sync";
    };
    Install.WantedBy = [ "default.target" ];
  };
}
