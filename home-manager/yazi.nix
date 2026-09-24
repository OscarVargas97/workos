# yazi como file manager de terminal. enableZshIntegration agrega la
# función `y` (wrapper estándar de yazi): al salir, cd a la carpeta en la
# que quedó parado - sin esto, salir de yazi te devuelve a la carpeta
# donde lo lanzaste, no a donde navegaste.
{ pkgs, ... }:
{
  programs.yazi = {
    enable = true;
    enableZshIntegration = true;
  };

  home.packages = with pkgs; [
    # Dependencias opcionales que yazi usa para el previsualizador
    # integrado - sin ellas cae en silencio a "no preview available" en
    # vez de mostrar el contenido. ripgrep/fd ya están en common.nix
    # (los reusa para buscar). kitty ya habla su protocolo de imágenes
    # nativo, así que no hace falta chafa/ueberzugpp acá.
    file
    unar
    jq
    poppler-utils
    ffmpegthumbnailer
  ];

  # yazi-kitty (mismo patrón que nvim-kitty en common.nix): "abrir esta
  # carpeta en el explorador de archivos" desde Brave/otras apps cae acá
  # en vez de no tener ningún inode/directory handler.
  xdg.desktopEntries.yazi-kitty = {
    name = "Yazi";
    genericName = "Explorador de archivos";
    exec = "kitty -e yazi %f";
    terminal = false;
    type = "Application";
    mimeType = [ "inode/directory" ];
    categories = [ "Utility" "FileManager" ];
  };

  xdg.mimeApps.defaultApplications."inode/directory" = "yazi-kitty.desktop";
}
