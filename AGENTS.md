# AGENTS.md — workos

Contexto para agentes de IA (Claude Code, Codex, Cursor, etc.) que trabajan
en este repo o que ayudan a una persona a instalar el sistema. La guía para
humanos es [`README.md`](./README.md); este archivo no la repite, la
estructura para ejecutarla.

## 1. Qué es este repo

Librería pública de un sistema NixOS completo ("Work OS"). **No se instala
directamente**: la instala el repo privado de cada persona, que es un flake
que importa este como input `workos` y le pasa los datos personales.

| Repo | Rol | Dónde está su contexto |
|---|---|---|
| `workos` (este) | Módulos NixOS/Home Manager, CLI `work`, scripts, esquema de company-context | este archivo |
| `workos-template` | Molde público del repo privado (+ `scripts/setup.sh`, `scripts/check.sh`) | su `AGENTS.md` |
| `workos-private` | Instancia privada de una persona, creada desde el template | su `AGENTS.md` |
| `cyber-shell` | HUD de escritorio (TS sobre AGS v3), input `flake = false` | su `AGENTS.md` |

Layout local esperado por los scripts (carpetas hermanas):
`<base>/workos`, `<base>/workos-private`, `<base>/iso/*.iso`, `<base>/vault/`
(por defecto `<base>` = `~/Repos/Externos/workos`).

## 2. Invariantes (no romper nunca)

1. **Cero datos personales en este repo**: ni nombres, emails, usuarios,
   hostnames reales, IPs, claves SSH, rutas `/home/<alguien>`, nombres de
   empresas o proyectos reales, IDs de Notion/Slack. Lo variable es una
   opción en `modules/workos.nix` con el valor en el repo privado, se
   descubre en runtime, o se pregunta por consola. Aplica también a
   comentarios, ejemplos y mensajes de commit.
2. **Cero secretos en cualquier repo** (tampoco en el privado): contraseñas
   y passphrases se piden por consola y se pasan por stdin/archivos `0600`
   temporales, nunca por argv; los tokens de agentes van en Bitwarden
   (`work secret get`, allowlist default-deny).
3. **Nada destructivo sin confirmación humana**: `prepare-installer-usb.sh`,
   `nixos-anywhere-deploy.sh` y cualquier cosa que particione, formatee o
   borre. Un agente nunca pasa `--yes` por su cuenta.
4. **Todo declarativo**: un cambio de sistema es un cambio en un `.nix`
   versionado, no un paso manual en la máquina.
5. **La IA nunca desbloquea Bitwarden** ni maneja la contraseña maestra.

## 3. Mapa del repo

| Ruta | Responsabilidad | Tocar cuando |
|---|---|---|
| `flake.nix` | Inputs pineados; outputs `lib.mkHost`, `nixosModules.{disko-default,vm}` | se agrega un input o un módulo exportado |
| `modules/security.nix` | `workos.security.{totp,sshTotp,lockTimeout}`: TOTP en PAM (hyprlock/login/greetd con secreto del usuario, sudo/sshd con secreto de root), servicio PAM propio de hyprlock, `workos-totp-setup` | cambios de autenticación: SIEMPRE correr `tests/security.nix` |
| `modules/workos.nix` | Declara `workos.user.{name,fullName,email,sshKeys}` y `workos.secretsPolicy`; crea el usuario y su home | se necesita un dato nuevo de la persona |
| `hosts/vm/configuration.nix` | Base del sistema para TODO host (boot, red, nix, podman, Hyprland, greetd, sshd, firewall) | cambia algo común a todas las máquinas |
| `hosts/vm/disko-config.nix` | Disco: GPT, ESP 512M, LUKS `crypted` + ext4 | cambia el esquema de disco |
| `hosts/vm/hardware-configuration.nix` | Perfil de VM QEMU | nunca para hardware real (eso va al privado) |
| `home-manager/common.nix` | Entrada de Home Manager: paquetes de usuario, xdg, git, apps por defecto | |
| `home-manager/{hyprland,zsh,kitty,neovim,devenv,herdr,cyber-shell}.nix` | Un módulo por área; `zsh.nix` empaqueta el CLI `work` | |
| `work-os/cli/work` | CLI `work` (bash): `enter`, `secret get`, `docs` | |
| `work-os/cli/docs/` | `work docs`: adaptadores Notion/Slack (Python, `uv run`, PEP 723) | tests: `uv run work-os/cli/docs/test_adapters.py` |
| `work-os/mcp/secrets/server.py` | MCP que expone `work secret get` | |
| `init.sh` | Punto de entrada: baja o crea el repo privado, lo configura, valida y publica | modo sin preguntas con `WORKOS_*` (§6) |
| `work-os/scripts/vault.sh` | vault cifrado con gocryptfs (`work vault`); clave en Bitwarden `workos-vault`. `env list/pull/push [--all]/send` sincroniza los `.env` de cualquier repo (misma ruta relativa al home); `reorg` usa `lib-repos.sh`. Nunca abre el vault solo | |
| `tests/` | `security.nix` (VMs, `nix build .#checks.x86_64-linux.security`), `e2e-install.sh` (instalación completa en VM con swtpm) | ver §5 |
| `work-os/scripts/` | USB, deploy, post-install, mapeo de repos (`map-repos.sh` + `lib-repos.sh`), migración, auditoría; `make` lista el orden | leen `../workos-private/work-os/scripts.env` |
| `company-context/` | `SCHEMA.md`, JSON Schema, tooling (`validate.py`, `new-entity.py`, `semantic_search.py`) | las instancias viven en el privado, `companies/<empresa>/` |
| `docs/DECISIONS.md` | Decisiones numeradas; el código las cita como `DECISIONS.md #N` | mantener la numeración estable |

## 4. Cómo se conectan las piezas

```
workos-private/flake.nix
  └─ workos.lib.mkHost [ ./identity.nix ./home.nix <host> ]
       ├─ disko.nixosModules.disko
       ├─ hosts/vm/configuration.nix        (base común)
       ├─ modules/workos.nix                (opciones + usuario + home-manager.users.<name>)
       │    └─ home-manager/common.nix → hyprland, zsh(+work CLI), kitty, neovim, devenv, herdr, cyber-shell
       └─ módulos del privado               (valores de workos.*, hardware, extras)
```

- Home Manager corre como módulo de NixOS (`useGlobalPkgs`, `useUserPackages`).
- Los módulos de Home Manager del privado se agregan en
  `home-manager.users.${config.workos.user.name}` (se fusionan con los de acá).
- `specialArgs`/`extraSpecialArgs` pasan `ags` y `cyberShell` a los módulos.
- `rebuild` (en `hyprland.nix`) = `nixos-rebuild --flake <privado>#$(hostname)`
  con `--override-input workos <clon local>` si `../workos` existe.

## 5. Verificar cambios

No hay CI. Antes de dar un cambio por bueno:

```bash
# desde workos-private (usa ../workos local automáticamente):
scripts/check.sh               # evalúa todos los hosts; nix local o Docker
# con nix local, además:
nix flake check path:.         # en este repo (evalúa lib y módulos)
bash -n work-os/scripts/*.sh   # sintaxis de los scripts
```

Cambios de autenticación, PAM, TPM o vault: además, en una máquina con
KVM, `nix build .#checks.x86_64-linux.security -L` (y para cambios en los
scripts de instalación, `tests/e2e-install.sh`). Un PAM roto deja a la
persona sin sudo: no se entrega sin el test pasando.

Un cambio en este repo puede romper el privado de cualquiera: si cambiás
el nombre o tipo de una opción de `modules/workos.nix`, tratalo como
cambio incompatible y documentalo en `README.md` y en el template.

## 6. Runbook: dejar a una persona con el sistema instalado

Pasos para un agente que acompaña a alguien desde cero. `[HUMANO]` =
el agente se detiene y la persona lo hace; el agente no lo simula.

Los scripts funcionan de dos formas: interactivos (la persona responde en
la terminal) o **sin preguntas**, con las respuestas en variables
`WORKOS_*`. Como agente usá la segunda: preguntale a la persona lo de
§6.1 en la conversación, confirmá el resumen con ella y corré los
scripts con esos valores (§6.2). **Nunca inventes un valor**: si falta
uno, preguntalo. Contraseñas y passphrases NO se piden en la
conversación ni se pasan por variables: las tipea la persona en los
pasos [HUMANO].

### 6.1 Datos a pedir

| Variable | Qué preguntar | Cómo validarlo / sugerir |
|---|---|---|
| `WORKOS_REPO_MODE` | ¿Ya tenés un repo privado de workos o creamos uno nuevo? | `clone` / `create` |
| `WORKOS_REPO` | ¿En qué cuenta u organización de GitHub, y con qué nombre? | `dueño/nombre`; sugerí `<usuario de gh>/workos-private`. Si es para trabajo de una empresa, puede ir en la cuenta/organización de esa empresa |
| `WORKOS_USER` | Usuario de login en la máquina nueva | minúsculas, sin espacios |
| `WORKOS_FULLNAME`, `WORKOS_EMAIL` | Nombre y email para los commits de git | sugerí `git config user.name/email` |
| `WORKOS_SSH_KEYS` | Claves SSH públicas de las máquinas desde las que vas a entrar | una por línea; ofrecé `cat ~/.ssh/*.pub`. Sin claves no hay acceso por SSH |
| `WORKOS_TIMEZONE`, `WORKOS_LOCALE` | Zona horaria y formato de fecha/moneda | `Región/Ciudad`; locale `xx_YY` o vacío |
| `WORKOS_HOST` | Nombre de la máquina a instalar | minúsculas y `-` |
| `WORKOS_DISK` | Disco a **borrar** | confirmalo con `lsblk` en la máquina destino (desde el live); nunca lo supongas |
| `WORKOS_COMPANY` | ¿Para qué empresa trabajás en esta máquina? | clave en minúscula (`acme`), vacío = ninguna |
| `WORKOS_SSH_KEY` | Clave SSH **privada** con la que se instala | ruta, ej. `~/.ssh/id_ed25519` |
| `WORKOS_RBW_EMAIL` | Email de Bitwarden (opcional) | |

### 6.2 Pasos

| # | Paso | Quién | Comando / acción | Listo cuando |
|---|---|---|---|---|
| 0 | Verificar requisitos (README §2) | agente | `git --version; gh auth status; command -v nix docker podman` | `gh` logueado (en la cuenta de `WORKOS_REPO`) y hay nix o docker/podman |
| 1 | Bajar workos | agente | `mkdir -p <base> && cd <base> && gh repo clone OscarVargas97/workos` | `<base>/workos` existe |
| 2 | Pedir los datos | agente ↔ persona | §6.1, y mostrarle el resumen para que lo confirme | la persona dijo que sí |
| 3 | Repo privado + configurar + validar | agente | `WORKOS_REPO_MODE=… WORKOS_REPO=… WORKOS_USER=… (resto de §6.1) WORKOS_PUBLISH=n workos/init.sh < /dev/null` | termina con `Todo OK.` (si una variable es inválida, el script lo dice: corregir con la persona) |
| 4 | Publicar | agente, con OK de la persona | `WORKOS_RECONFIGURE=n WORKOS_PUBLISH=s workos/init.sh < /dev/null` | push hecho |
| 5 | Bajar el ISO | [HUMANO] o agente | ISO mínimo x86_64 de nixos.org a `<base>/iso/`, verificar SHA-256 | archivo en `iso/` |
| 6 | Grabar pendrive | [HUMANO] | `workos/work-os/scripts/prepare-installer-usb.sh` (Linux; borra el pendrive) | script termina OK |
| 7 | Bootear el destino | [HUMANO] | UEFI, Secure Boot off, red (cable o `nmtui`) | la máquina muestra el live |
| 8 | Instalar | [HUMANO] | `nixos-anywhere-deploy.sh` (confirma con `si`, pide contraseña y passphrase) | reinicia al sistema instalado |
| 9 | Primer arranque | [HUMANO] | escribir la passphrase del disco en la consola | llega a greetd |
| 10 | Post-instalación | [HUMANO]: tipea contraseña, passphrase y PIN nuevo; escanea los QR de TOTP con su teléfono e imprime los códigos de emergencia | `post-install-setup.sh` | sin líneas `Falló`; `sudo -k; sudo true` pide contraseña + código |
| 11 | Mapear repos | agente ↔ persona, en la máquina vieja | §6.3 | `map-repos.sh --list` sin `pendiente` |
| 12 | Migrar datos | [HUMANO], opcional | `migrate-pc.sh` desde la máquina vieja | |
| 13 | Bitwarden | [HUMANO] | `rbw config set email <email> && rbw login` en la máquina nueva | |

Si un paso falla: leer el mensaje del script (explican la causa), consultar
README §8, corregir en el repo privado, volver al paso 3. Los scripts de
post-instalación y migración son re-ejecutables; el deploy vuelve a
particionar.

### 6.3 Mapear los repos de la máquina vieja

`work-os/scripts/map-repos.sh` (en la máquina vieja, con `workos` y el
privado clonados al lado) decide a dónde va cada repo en la nueva:

1. `map-repos.sh --list` → TSV: `estado ruta remote empresa destino ruta_final`.
2. Proponé un destino para cada `pendiente` y confirmalo con la persona
   (en lote está bien: una tabla con tu propuesta). Reglas:
   - Repo de trabajo de una empresa → `empresa` = su clave en minúscula
     (la misma de `companies/<empresa>` y `COMPANY_NAME`); queda en
     `~/Repos/<Empresa>/<destino>`. Pistas: el dueño del `remote`
     (organización de GitHub de la empresa) o la carpeta donde está hoy.
   - Personal o de terceros (forks, dotfiles, herramientas) → `empresa`
     vacía; queda en `~/Repos/Externos/<destino>`.
   - Duplicados, copias viejas, `temp/` → destino vacío (no se migra).
   - Repos hermanos de un mismo proyecto → destino `Proyecto/repo`
     (agrupa, y migra lo suelto de la carpeta del proyecto).
   - Ante la duda (¿empresa o externo?), preguntá; no lo decidas vos.
3. `map-repos.sh --set 'ruta=empresa=destino' ...` con lo confirmado (valida
   las reglas y rechaza valores inválidos).
4. Repetir `--list` hasta que no quede `pendiente`; commit + push del privado.

## 7. Convenciones

- Idioma de código, comentarios y docs: español.
- Comentarios: explican el **por qué** (bug real que evitan, decisión que
  aplican), no el qué.
- Scripts: `set -euo pipefail`, cada `read -rp` con una explicación de qué
  se pide y para qué, defaults entre corchetes, confirmación escrita (`si`)
  antes de destruir.
- Preferir opciones nativas de NixOS/Home Manager a scripts de activación;
  pinear todo lo que venga de afuera (inputs, `fetchurl` con hash).
- Commits: mensaje en español, qué cambia y por qué.
