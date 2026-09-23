# Segundo factor sin hardware extra (docs/DECISIONS.md #15): códigos TOTP
# de una app del teléfono. Todo apagado por defecto; el repo privado lo
# activa. Los secretos se crean después de instalar con
# `workos-totp-setup` (post-install-setup.sh lo corre) - hasta entonces
# cada entrada funciona sin código (nullok), para no dejar a nadie afuera.
{ config, lib, pkgs, ... }:
let
  cfg = config.workos.security;
  inherit (lib) mkOption mkEnableOption mkIf mkMerge types concatMapStringsSep;

  # Secreto de sudo/SSH: de root, en un directorio que el usuario puede
  # atravesar (para saber si existe) pero no leer. sudo y sshd corren como
  # root, así que pueden leerlo con user=root; un proceso del usuario
  # (malware en la sesión) no lo puede leer ni reemplazar.
  # nullok (sin secreto creado, entra sin código) mientras no se active
  # totp.enforce: sin esto nadie queda afuera entre la instalación y
  # workos-totp-setup, pero borrar ~/.google_authenticator desactivaría el
  # código de desbloqueo en silencio - por eso enforce, después del setup.
  nullOk = !cfg.totp.enforce;
  rootSecret = {
    googleAuthenticator = { enable = true; allowNullOTP = nullOk; };
    rules.auth.google_authenticator.settings = {
      secret = "/var/lib/workos/totp/\${USER}";
      user = "root";
    };
  };
  # Secreto de desbloqueo local: en el home, porque hyprlock corre con el
  # usuario (no puede leer uno de root). Protege contra quien tiene la
  # laptop en la mano, no contra malware en la sesión - por eso es un
  # código distinto del de sudo.
  userSecret = {
    googleAuthenticator = { enable = true; allowNullOTP = nullOk; };
  };
  # hyprlock tiene UN solo campo y responde con lo mismo a cada pregunta de
  # PAM (contraseña y código): nunca entraba. Con forward_pass se escribe
  # contraseña+código juntos en una sola pregunta; el módulo valida los
  # últimos 6 dígitos y le pasa el resto a pam_unix (try_first_pass). Sin
  # secreto (nullok) no pregunta nada y pam_unix pide la contraseña sola.
  hyprlockSecret = lib.recursiveUpdate userSecret {
    rules.auth.unix-early.enable = lib.mkForce false;
    rules.auth.google_authenticator.settings.forward_pass = lib.mkForce true;
  };

  totpSetup = pkgs.writeShellScriptBin "workos-totp-setup" ''
    export PATH=${lib.makeBinPath [ pkgs.google-authenticator pkgs.coreutils ]}:$PATH
    exec ${pkgs.bash}/bin/bash ${../work-os/scripts/totp-setup.sh} "$@"
  '';
in
{
  options.workos.security = {
    totp.enable = mkEnableOption ''
      código TOTP (app del teléfono) además de la contraseña en: bloqueo de
      pantalla, login de consola y pantalla de inicio (código "desbloqueo"),
      y sudo/su/pkexec (código "sudo", con secreto de root)'';

    totp.enforce = mkEnableOption ''
      exigir el código aunque falte el secreto (sin nullok). Activalo
      DESPUÉS de correr workos-totp-setup: antes, te dejaría sin sudo'';

    sshTotp = {
      enable = mkEnableOption "código TOTP (el de sudo) para SSH desde fuera de las redes de confianza";
      trustedNetworks = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "192.168.1.0/24" ];
        description = "Redes (CIDR) desde las que SSH entra solo con clave, sin código.";
      };
    };

    lockTimeout = mkOption {
      type = types.ints.positive;
      default = 300;
      description = "Segundos de inactividad hasta bloquear la pantalla (suspende al doble).";
    };
  };

  config = mkMerge [
    {
      # Servicio PAM propio de hyprlock: sin esto usa el de `su` como
      # respaldo, y el TOTP del bloqueo no se podría separar del de su.
      security.pam.services.hyprlock = { };
    }

    (mkIf cfg.totp.enable {
      # Toda vía a root pide el código "sudo": sudo, su y polkit (pkexec y
      # los diálogos gráficos de permisos) - si faltara una, esa sería la
      # forma de esquivar el código.
      security.pam.services = {
        hyprlock = hyprlockSecret;
        login = userSecret;
        greetd = userSecret;
        sudo = rootSecret;
        su = rootSecret;
        polkit-1 = rootSecret;
      };
      systemd.tmpfiles.rules = [ "d /var/lib/workos/totp 0711 root root -" ];
      environment.systemPackages = [ totpSetup ];
    })

    (mkIf cfg.sshTotp.enable {
      assertions = [{
        assertion = cfg.totp.enable;
        message = "workos.security.sshTotp necesita workos.security.totp.enable (usa el mismo secreto de sudo).";
      }];
      # Dentro de las redes de confianza, solo clave; desde cualquier otra,
      # clave + código. La contraseña de Unix no se pide nunca por SSH.
      services.openssh.settings = {
        KbdInteractiveAuthentication = true;
        AuthenticationMethods = "publickey";
      };
      services.openssh.extraConfig = ''
        Match Address *${concatMapStringsSep "" (n: ",!${n}") cfg.sshTotp.trustedNetworks}
          AuthenticationMethods publickey,keyboard-interactive:pam
      '';
      # En SSH la clave ya es el primer factor: PAM solo tiene que validar
      # el código. Sin la regla de unix y con el código como "sufficient",
      # un código mal ingresado cae en pam_deny - nunca se puede cambiar
      # por la contraseña.
      # (unixAuth tiene que quedar activo igual: el módulo de PAM de NixOS
      # solo arma la regla del código cuando lo está - el de OpenSSH lo
      # apaga porque PasswordAuthentication = false.)
      security.pam.services.sshd = lib.recursiveUpdate rootSecret {
        unixAuth = lib.mkForce true;
        rules.auth.unix-early.enable = lib.mkForce false;
        rules.auth.unix.enable = lib.mkForce false;
        rules.auth.google_authenticator.control = lib.mkForce "sufficient";
      };
    })
  ];
}
