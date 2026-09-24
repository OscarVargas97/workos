# Variables de identidad del sistema. Este repo solo declara las
# opciones; los valores reales (usuario, nombre, email, claves SSH) los
# pone el repo privado de cada persona (ver example/identity.nix).
{ config, lib, pkgs, ... }:
let
  cfg = config.workos;
  inherit (lib) mkOption types;
in
{
  options.workos = {
    user = {
      name = mkOption { type = types.str; description = "Usuario de login."; };
      fullName = mkOption { type = types.str; description = "Nombre para los commits de git."; };
      email = mkOption { type = types.str; description = "Email para los commits de git."; };
      sshKeys = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Claves públicas autorizadas por SSH. Solo estas - cualquier clave
          no listada queda afuera aunque antes funcionara.
        '';
      };
    };
    secretsPolicy = mkOption {
      type = types.path;
      default = ../work-os/cli/secrets-policy.yaml;
      description = "Allowlist de secretos por skill (default-deny, DECISIONS.md #2).";
    };

    cloudOps.environments = mkOption {
      # Un binario <name> por entorno (work-os/scripts/cloud-ops.sh) - el
      # entorno va en el nombre del comando, nunca como flag que se puede
      # olvidar. Cuentas/tags/repos reales los pone el privado (empresa
      # con datos reales); este módulo no conoce ninguno.
      type = types.listOf (types.submodule {
        options = {
          name = mkOption { type = types.str; description = "Nombre del binario generado (ej. \"acme-dev\")."; };
          envLabel = mkOption { type = types.str; description = "Palabra a tipear para confirmar una acción real (ej. \"dev\", \"prod\")."; };
          awsProfile = mkOption { type = types.str; description = "Profile de AWS CLI (\"aws login --profile <esto>\")."; };
          awsAccountId = mkOption { type = types.str; description = "Cuenta AWS - solo se muestra antes de ejecutar algo, no autentica nada."; };
          region = mkOption { type = types.str; default = "us-east-1"; description = "Región AWS."; };
          k3sNodeTag = mkOption { type = types.nullOr types.str; default = null; description = "Tag Name de la EC2 con el nodo k3s. null = sin kubectl/exec/migrate en este entorno."; };
          bastionTag = mkOption { type = types.nullOr types.str; default = null; description = "Tag Name del bastion SSM hacia RDS. null = sin dump en este entorno."; };
          rdsIdentifier = mkOption { type = types.nullOr types.str; default = null; description = "DBInstanceIdentifier de RDS."; };
          dbSecretPrefix = mkOption { type = types.nullOr types.str; default = null; description = "Prefijo de Secrets Manager: \"<prefijo>/db/<nombre>\"."; };
          terraformRepo = mkOption { type = types.nullOr types.str; default = null; description = "\"owner/repo\" de Terraform. null = sin tf-graph."; };
          terraformDir = mkOption { type = types.nullOr types.str; default = null; description = "Root de Terraform dentro del repo (ej. \"envs/dev\")."; };
          requireConfirmation = mkOption { type = types.bool; default = false; description = "Pedir confirmación tipeada antes de dump/migrate/exec reales."; };
          migrateConfig = mkOption { type = types.nullOr types.path; default = null; description = "tsv: deployment<TAB>db_name<TAB>check_cmd<TAB>apply_cmd."; };
        };
      });
      default = [ ];
      description = "Comandos por entorno para operar infra en AWS/k8s.";
    };
  };

  config = {
    users.users.${cfg.user.name} = {
      isNormalUser = true;
      extraGroups = [ "wheel" "networkmanager" "podman" "libvirtd" ];
      shell = pkgs.zsh;
      openssh.authorizedKeys.keys = cfg.user.sshKeys;
      # Hash de contraseña inyectado por work-os/scripts/nixos-anywhere-deploy.sh
      # vía --extra-files (nunca se pide ni se guarda en ningún repo). Sin
      # esto, el login gráfico y sudo quedan sin forma de autenticar.
      hashedPasswordFile = "/etc/secrets/${cfg.user.name}-password-hash";
    };

    home-manager.users.${cfg.user.name} = {
      imports = [ ../home-manager/common.nix ];
      home.username = cfg.user.name;
      home.homeDirectory = "/home/${cfg.user.name}";
      programs.git.settings.user = { inherit (cfg.user) email; name = cfg.user.fullName; };
      xdg.configFile."work-os/secrets-policy.yaml".source = cfg.secretsPolicy;

      # pg_dump/jq/flock: lo único que cloud-ops.sh necesita y common.nix no
      # instala ya (awscli2/kubectl/gh/ssm-session-manager-plugin sí están,
      # PATH se hereda del shell que llama - mismo criterio que workos-vault,
      # que también declara util-linux a propósito aunque el sistema lo tenga
      # global).
      home.packages = map
        (e: pkgs.writeShellScriptBin e.name ''
          export PATH=${lib.makeBinPath [ pkgs.postgresql pkgs.jq pkgs.util-linux ]}:$PATH
          export CLOUDOPS_NAME=${lib.escapeShellArg e.name}
          export CLOUDOPS_ENV_LABEL=${lib.escapeShellArg e.envLabel}
          export CLOUDOPS_AWS_PROFILE=${lib.escapeShellArg e.awsProfile}
          export CLOUDOPS_AWS_ACCOUNT_ID=${lib.escapeShellArg e.awsAccountId}
          export CLOUDOPS_REGION=${lib.escapeShellArg e.region}
          ${lib.optionalString (e.k3sNodeTag != null) "export CLOUDOPS_K3S_TAG=${lib.escapeShellArg e.k3sNodeTag}"}
          ${lib.optionalString (e.bastionTag != null) "export CLOUDOPS_BASTION_TAG=${lib.escapeShellArg e.bastionTag}"}
          ${lib.optionalString (e.rdsIdentifier != null) "export CLOUDOPS_RDS_IDENTIFIER=${lib.escapeShellArg e.rdsIdentifier}"}
          ${lib.optionalString (e.dbSecretPrefix != null) "export CLOUDOPS_DB_SECRET_PREFIX=${lib.escapeShellArg e.dbSecretPrefix}"}
          ${lib.optionalString (e.terraformRepo != null) "export CLOUDOPS_TERRAFORM_REPO=${lib.escapeShellArg e.terraformRepo}"}
          ${lib.optionalString (e.terraformDir != null) "export CLOUDOPS_TERRAFORM_DIR=${lib.escapeShellArg e.terraformDir}"}
          export CLOUDOPS_REQUIRE_CONFIRM=${if e.requireConfirmation then "true" else "false"}
          ${lib.optionalString (e.migrateConfig != null) "export CLOUDOPS_MIGRATE_CONFIG=${e.migrateConfig}"}
          exec ${pkgs.bash}/bin/bash ${../work-os/scripts}/cloud-ops.sh "$@"
        '')
        cfg.cloudOps.environments;
    };
  };
}
