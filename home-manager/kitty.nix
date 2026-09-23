# kitty portado de la config de Fedora original (Fira Code, keybinds) -
# ver DECISIONS.md #9. Colores cambiados de Catppuccin Mocha a la
# paleta cyan/magenta neon de cyber-shell (mismo esquema que el resto
# del sistema, y calza con el wallpaper). Transparencia via
# background_opacity — el blur lo pone Hyprland (decoration.blur en
# hyprland.nix, aplica a todas las ventanas, no hace falta duplicar acá.
{ pkgs, ... }:
{
  programs.kitty = {
    enable = true;
    font = {
      name = "Fira Code";
      size = 12;
    };
    settings = {
      enable_audio_bell = "no";
      bold_font = "Fira Code Bold";
      italic_font = "Fira Code Italic";
      bold_italic_font = "Fira Code Bold Italic";
      enable_ligatures = "true";
      # Fallback para glifos que Fira Code no trae.
      font_family = "Hack Nerd Font";
      color_profile = "sRGB";
      url_color = "#ff2bd6";
      url_style = "curly";
      cursor_shape = "beam";
      cursor_beam_thickness = "3.2";
      mouse_hide_wait = "3.0";
      detect_urls = "yes";
      repaint_delay = "10";
      input_delay = "3";
      sync_to_monitor = "yes";
      window_border_width = "0";
      tab_bar_style = "powerline";

      # Transparencia - el blur de fondo lo pone Hyprland globalmente.
      background_opacity = "0.85";
      dynamic_background_opacity = "yes";

      # Netrunner (cyan/magenta), mismo esquema que cyber-shell/GTK/waybar.
      foreground = "#c5d1de";
      background = "#0a0e14";
      selection_foreground = "#0a0e14";
      selection_background = "#ff2bd6";
      cursor = "#00fff9";
      cursor_text_color = "#0a0e14";
      active_border_color = "#00fff9";
      inactive_border_color = "#3a3f4b";
      bell_border_color = "#ffcc00";
      wayland_titlebar_color = "#0a0e14";
      active_tab_foreground = "#0a0e14";
      active_tab_background = "#00fff9";
      inactive_tab_foreground = "#c5d1de";
      inactive_tab_background = "#0a0e14";
      tab_bar_background = "#0a0e14";
      mark1_foreground = "#0a0e14";
      mark1_background = "#00fff9";
      mark2_foreground = "#0a0e14";
      mark2_background = "#ff2bd6";
      mark3_foreground = "#0a0e14";
      mark3_background = "#5ca0ff";
      color0 = "#0a0e14"; color8 = "#3a3f4b";
      color1 = "#ff2b4d"; color9 = "#ff5c72";
      color2 = "#00ff9f"; color10 = "#5cffc4";
      color3 = "#ffcc00"; color11 = "#ffe066";
      color4 = "#2b7fff"; color12 = "#5ca0ff";
      color5 = "#ff2bd6"; color13 = "#ff6be8";
      color6 = "#00fff9"; color14 = "#6bfff9";
      color7 = "#c5d1de"; color15 = "#e8f0f7";
    };
    keybindings = {
      "ctrl+left" = "neighboring_window left";
      "ctrl+right" = "neighboring_window right";
      "ctrl+up" = "neighboring_window up";
      "ctrl+down" = "neighboring_window down";
      "f1" = "copy_to_buffer a";
      "f2" = "paste_from_buffer a";
      "f3" = "copy_to_buffer b";
      "f4" = "paste_from_buffer b";
      "ctrl+shift+z" = "toggle_layout stack";
    };
  };

  fonts.fontconfig.enable = true;
  home.packages = with pkgs; [ fira-code nerd-fonts.hack ];
}
