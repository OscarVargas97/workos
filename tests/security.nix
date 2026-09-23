# Test de modules/security.nix + work-os/scripts/vault.sh en VMs reales
# (nix flake check / nix build .#checks.x86_64-linux.security). Verifica
# con códigos TOTP reales (oathtool), no leyendo la config:
#   - sin secretos creados, todo entra solo con contraseña (nullok);
#   - sudo pide código "sudo" (secreto de root, ilegible para el usuario);
#   - hyprlock/login piden código "desbloqueo", también corriendo como el
#     usuario (como hyprlock de verdad);
#   - SSH: solo clave desde la red de confianza, clave + código desde afuera;
#   - TPM2 + PIN: el mismo systemd-cryptenroll de post-install-setup.sh;
#   - vault cifrado: init/open/close/import, y que no quede nada en claro;
#   - ataques: su/pkexec sin código, reusar un código, fuerza bruta, cruzar
#     códigos, SSH con contraseña, borrar el secreto (nullok vs enforce),
#     TPM2 sin PIN, nombres visibles en el vault.
{ pkgs, self }:
let
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
  vault = pkgs.writeShellScriptBin "workos-vault" ''
    export PATH=${pkgs.lib.makeBinPath [ pkgs.gocryptfs pkgs.rsync pkgs.util-linux ]}:$PATH
    exec ${pkgs.bash}/bin/bash ${../work-os/scripts/vault.sh} "$@"
  '';
  client = {
    virtualisation.vlans = [ 1 ];
    environment.systemPackages = [ pkgs.sshpass ];
  };
in
pkgs.testers.runNixOSTest {
  name = "workos-security";
  nodes = {
    lan = client; # 192.168.1.1: red de confianza
    wan = client // { virtualisation.vlans = [ 2 ]; }; # afuera (red 192.168.2.0/24)
    machine = { ... }: {
      imports = [ ../modules/security.nix ];
      virtualisation.vlans = [ 1 2 ]; # 192.168.1.2 y 192.168.2.2
      virtualisation.tpm.enable = true;
      workos.security = {
        totp.enable = true;
        sshTotp = { enable = true; trustedNetworks = [ "192.168.1.0/24" ]; };
      };
      services.openssh = { enable = true; settings.PasswordAuthentication = false; };
      users.users.alice = {
        isNormalUser = true;
        password = "pw";
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = [ keys.snakeOilPublicKey ];
      };
      users.users.bob = { isNormalUser = true; password = "bob"; }; # para probar su desde otro usuario
      # su/sudo reales en una pty: expect corre como el usuario (sin su anidado,
      # que colgaba el test) y responde contraseña y código.
      environment.etc."workos-test/pty.exp".text = ''
        set timeout 20
        set mode [lindex $argv 0]
        set code [lindex $argv 1]
        if {$mode eq "su"} { spawn /run/wrappers/bin/su alice -c true } else { spawn sh -c "sudo -k; sudo true" }
        expect {
          -re {[Pp]assword} { send "pw\r"; exp_continue }
          -re {Verification code} { send "$code\r"; exp_continue }
          timeout { puts TIMEOUT; exit 3 }
          eof
        }
        catch wait r
        exit [lindex $r 3]
      '';
      environment.systemPackages = with pkgs; [ oath-toolkit pamtester google-authenticator cryptsetup vault expect ];
    };
    # totp.enforce: sin nullok, que falte el secreto no abre nada.
    strict = { ... }: {
      imports = [ ../modules/security.nix ];
      workos.security.totp = { enable = true; enforce = true; };
      users.users.alice = { isNormalUser = true; password = "pw"; };
      environment.systemPackages = [ pkgs.pamtester ];
    };
  };

  testScript = ''
    import time
    # -C: sin el paso "ingresá un código de la app" (acá no hay teléfono).
    GA = "google-authenticator -t -d -f -C -r 3 -R 30 -w 3 -Q NONE"

    def code(secret_file):
        return machine.succeed(f"oathtool --totp -b $(head -1 {secret_file})").strip()

    def auth(service, answers, as_alice=False):
        # pamtester responde los prompts de PAM en orden, una línea por prompt.
        cmd = f"printf '%s\\n' {' '.join(repr(a) for a in answers)} | pamtester {service} alice authenticate"
        if as_alice:
            cmd = f"su alice -s /bin/sh -c {repr(cmd)}"
        return cmd

    def next_window():
        # -d prohíbe reusar un código y -r 3 -R 30 limita intentos:
        # cada caso usa una ventana de 30 s nueva.
        time.sleep(31 - int(time.time()) % 30)

    def lock(text):
        # Como hyprlock de verdad: corre como alice, tiene un solo campo y
        # responde lo mismo a cada pregunta de PAM.
        return auth("hyprlock", [text] * 3, as_alice=True)

    def interactive(user, mode, code_answer):
        # su/sudo reales en una pty (pty.exp); devuelve el exit status.
        status, out = machine.execute(f"su {user} -c 'expect /etc/workos-test/pty.exp {mode} \"{code_answer}\"'")
        print(out)
        assert "TIMEOUT" not in out, f"{mode}: no mostró lo esperado"
        return status

    start_all()
    machine.wait_for_unit("sshd.service")
    lan.wait_for_unit("network.target")
    wan.wait_for_unit("network.target")

    # En el PAM de NixOS la contraseña va primero (unix-early) y el código
    # después; en sshd no hay contraseña, solo el código.
    for svc in ["sudo", "su", "polkit-1", "login", "greetd"]:
        pam = machine.succeed(f"cat /etc/pam.d/{svc}")
        assert pam.index("pam_unix") < pam.index("pam_google_authenticator"), svc
    # hyprlock: una sola pregunta (contraseña+código), ver lock() abajo.
    pam = machine.succeed("grep ^auth /etc/pam.d/hyprlock")
    assert "forward_pass" in pam and pam.index("pam_google_authenticator") < pam.index("pam_unix"), pam
    sshd = machine.succeed("grep ^auth /etc/pam.d/sshd")
    assert "pam_unix" not in sshd and "pam_google_authenticator" in sshd, sshd

    with subtest("sin secretos creados: solo contraseña (nullok, nadie queda afuera)"):
        machine.succeed(auth("sudo", ["pw"]))
        machine.succeed(lock("pw"))

    with subtest("crear secretos como workos-totp-setup"):
        machine.succeed(f"{GA} -l sudo -s /var/lib/workos/totp/alice && chmod 400 /var/lib/workos/totp/alice")
        machine.succeed(f"su alice -c '{GA} -l desbloqueo -s ~/.google_authenticator && chmod 400 ~/.google_authenticator'")
        machine.fail("su alice -c 'cat /var/lib/workos/totp/alice'")
        machine.succeed("su alice -c 'test -e /var/lib/workos/totp/alice'")

    with subtest("sudo: código 'sudo' + contraseña"):
        next_window()
        machine.fail(auth("sudo", ["pw", "000000"]))
        machine.succeed(auth("sudo", ["pw", code("/var/lib/workos/totp/alice")]))
        next_window()
        # el código de desbloqueo NO sirve para sudo
        machine.fail(auth("sudo", ["pw", code("/home/alice/.google_authenticator")]))

    with subtest("bloqueo de pantalla (como alice) y login: código 'desbloqueo' + contraseña"):
        next_window()
        machine.fail(lock("pw000000"))
        machine.succeed(lock("pw" + code("/home/alice/.google_authenticator")))
        next_window()
        machine.fail(lock("mal" + code("/home/alice/.google_authenticator")))  # contraseña mala, código bueno
        next_window()
        machine.fail(lock(code("/home/alice/.google_authenticator")))  # solo el código
        next_window()
        machine.fail(auth("login", ["mal", code("/home/alice/.google_authenticator")]))
        # Con contraseña mala PAM igual valida (y gasta) el código: el
        # siguiente intento necesita un código nuevo.
        next_window()
        machine.succeed(auth("login", ["pw", code("/home/alice/.google_authenticator")]))

    with subtest("SSH: solo clave desde la red de confianza"):
        for c in [lan, wan]:
            c.succeed("install -m600 ${keys.snakeOilPrivateKey} /root/id")
        lan.succeed("ssh -i /root/id -o StrictHostKeyChecking=no -o BatchMode=yes alice@192.168.1.2 true")

    with subtest("SSH: clave + código 'sudo' desde afuera"):
        wan.fail("ssh -i /root/id -o StrictHostKeyChecking=no -o BatchMode=yes alice@192.168.2.2 true")
        next_window()
        wan.fail("sshpass -P 'Verification code' -p 000000 ssh -i /root/id -o StrictHostKeyChecking=no alice@192.168.2.2 true")
        c = code("/var/lib/workos/totp/alice")
        wan.succeed(f"sshpass -P 'Verification code' -p {c} ssh -i /root/id -o StrictHostKeyChecking=no alice@192.168.2.2 true")

    # --- Ataques: cada uno intenta esquivar una protección y tiene que fallar ---

    with subtest("ataque: su y polkit (pkexec) también piden el código 'sudo'"):
        next_window()
        machine.fail(auth("polkit-1", ["pw"]))  # solo contraseña
        machine.succeed(auth("polkit-1", ["pw", code("/var/lib/workos/totp/alice")]))
        # su real (setuid), desde OTRO usuario sin privilegios (bob -> alice):
        # pamtester corre como root y el PAM de su deja pasar a root (pam_rootok).
        next_window()
        assert interactive("bob", "su", "") != 0, "su aceptó solo la contraseña"
        assert interactive("bob", "su", code("/var/lib/workos/totp/alice")) == 0, "su rechazó contraseña + código"

    with subtest("ataque: un código no se puede reusar"):
        next_window()
        c = code("/var/lib/workos/totp/alice")
        machine.succeed(auth("sudo", ["pw", c]))
        machine.fail(auth("sudo", ["pw", c]))

    with subtest("ataque: fuerza bruta frenada (máx. 3 intentos cada 30 s)"):
        next_window()
        for _ in range(3):
            machine.fail(auth("sudo", ["pw", "000000"]))
        # agotados los intentos, ni el código correcto entra
        machine.fail(auth("sudo", ["pw", code("/var/lib/workos/totp/alice")]))

    with subtest("sudo real (terminal, con sus 3 reintentos): el límite de intentos también aplica"):
        # sudo de verdad en una pty (no pamtester): contraseña y código en cada
        # reintento, como una persona que se equivoca de código.
        time.sleep(31)  # sin intentos de los subtests anteriores en la ventana
        next_window()
        assert interactive("alice", "sudo", "000000") != 0  # 3 reintentos con código malo
        # recién después, el correcto también se rechaza: se agotaron los 3
        # intentos de estos 30 s (la protección anti fuerza bruta)
        assert interactive("alice", "sudo", code("/var/lib/workos/totp/alice")) != 0
        time.sleep(31)
        next_window()
        assert interactive("alice", "sudo", code("/var/lib/workos/totp/alice")) == 0

    with subtest("ataque: el código 'sudo' no desbloquea la pantalla"):
        next_window()
        machine.fail(lock("pw" + code("/var/lib/workos/totp/alice")))

    with subtest("ataque: SSH con contraseña, desde cualquier red"):
        lan.fail("sshpass -p pw ssh -o PubkeyAuthentication=no -o StrictHostKeyChecking=no alice@192.168.1.2 true")
        wan.fail("sshpass -p pw ssh -o PubkeyAuthentication=no -o StrictHostKeyChecking=no alice@192.168.2.2 true")
        next_window()
        # la contraseña escrita en el prompt del código tampoco sirve
        wan.fail("sshpass -P 'Verification code' -p pw ssh -i /root/id -o StrictHostKeyChecking=no alice@192.168.2.2 true")

    with subtest("ataque: borrar el secreto de desbloqueo (nullok vs totp.enforce)"):
        machine.succeed("su alice -c 'cp ~/.google_authenticator ~/ga-bak && rm -f ~/.google_authenticator'")
        # sin enforce el bloqueo vuelve a entrar solo con contraseña: por eso
        # se activa totp.enforce después de workos-totp-setup
        machine.succeed(lock("pw"))
        machine.succeed("su alice -c 'mv ~/ga-bak ~/.google_authenticator'")
        # con enforce, sin secreto no entra nadie (ni a sudo ni al bloqueo)
        strict.wait_for_unit("multi-user.target")
        strict.fail(auth("sudo", ["pw"]))
        strict.fail(lock("pw"))

    with subtest("TPM2 + PIN (el enrolamiento de post-install-setup.sh)"):
        machine.succeed("truncate -s 64M /tmp/disk && echo -n pass | cryptsetup luksFormat -q --pbkdf pbkdf2 /tmp/disk -")
        machine.succeed("PASSWORD=pass NEWPIN=1234 systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin=yes /tmp/disk")
        # JSON de LUKS (la misma comprobación que post-install-setup.sh): no
        # depende de que cryptsetup cargue el plugin de tokens de systemd.
        print(machine.succeed("cryptsetup luksDump --dump-json-metadata /tmp/disk"))
        machine.succeed("cryptsetup luksDump --dump-json-metadata /tmp/disk | grep -Eq '\"tpm2-pin\": ?true'")
        machine.fail("systemd-cryptsetup attach t /tmp/disk - tpm2-device=auto,headless=true")  # sin PIN
        machine.fail("PIN=9999 systemd-cryptsetup attach t /tmp/disk - tpm2-device=auto,headless=true")
        machine.succeed("PIN=1234 systemd-cryptsetup attach t /tmp/disk - tpm2-device=auto,headless=true")
        machine.succeed("systemd-cryptsetup detach t")

    with subtest("vault cifrado"):
        env = "WORKOS_BASE=/home/alice/w WORKOS_VAULT_PASS_CMD='echo clave-de-test'"
        def v(args):
            return f"su alice -c \"{env} workos-vault {args}\""
        machine.succeed("su alice -c 'mkdir -p ~/w/viejo/proy && echo SECRETO_DB=xyz > ~/w/viejo/proy/.env'")
        machine.succeed("echo si | " + v("import /home/alice/w/viejo"))
        machine.fail("test -e /home/alice/w/viejo")  # el original en claro se borró
        machine.succeed("su alice -c 'grep -q SECRETO_DB ~/w/vault/proy/.env'")
        # FUSE: el vault abierto solo lo ve quien lo abrió (ni root, ni otro usuario).
        machine.fail("grep -q SECRETO_DB /home/alice/w/vault/proy/.env")
        machine.succeed(v("close"))
        machine.fail("grep -rq SECRETO_DB /home/alice/w/vault.enc /home/alice/w/vault")
        # ni los nombres se ven: una copia de vault.enc no dice qué proyectos hay
        machine.fail("find /home/alice/w/vault.enc | grep -Eq 'proy|\\.env'")
        machine.succeed("test -z \"$(ls -A /home/alice/w/vault)\"")  # cerrado = vacío
        machine.succeed(v("status") + " | grep -q Cerrado")
        machine.fail("su alice -c \"WORKOS_BASE=/home/alice/w WORKOS_VAULT_PASS_CMD='echo mala' workos-vault open\"")
        machine.succeed(v("open"))
        machine.succeed("su alice -c 'grep -q SECRETO_DB ~/w/vault/proy/.env'")
        machine.succeed(v("close"))
  '';
}
