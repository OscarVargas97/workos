# Fase 3 — dev environments por proyecto. NVM/pnpm/conda de la laptop
# Fedora original NO van acá (ver Fase 2b/zsh.nix) - entran como
# runtimes por-proyecto vía devenv/direnv, para no contaminar el
# sistema global con versiones de Node/Python fijas para siempre.
{ pkgs, ... }:
{
  # nix-direnv: cachea los shells de devenv/nix en el store en vez de
  # reconstruirlos cada vez que se entra a la carpeta - sin esto, cada
  # "cd" a un proyecto con devenv sería lento. El hook de zsh (cargar/
  # descargar el entorno al entrar/salir de una carpeta con .envrc) lo
  # inyecta este mismo módulo solo, porque ya ve que programs.zsh está
  # habilitado (common.nix) - no hace falta tocar zsh.nix a mano.
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # `devenv` en sí (el binario que arma el shell reproducible por
  # proyecto, ver devenv.nix de cada repo) - direnv es el que
  # activa/desactiva ese shell solo al entrar/salir de la carpeta.
  home.packages = [ pkgs.devenv ];

  # direnvrc global (una sola vez, no por proyecto): da la función
  # "use_devenv" que cada .envrc de un proyecto llama con "use devenv".
  # Sin esto, direnv no sabe qué hacer con esa línea (falla con
  # "use_devenv: command not found"). Referenciado por ruta completa al
  # store, no por PATH en runtime - reproducible.
  home.file.".config/direnv/direnvrc".text = ''
    source <(${pkgs.devenv}/bin/devenv direnvrc)
  '';
}
