# workos

Un entorno de trabajo completo y reproducible sobre **NixOS**: escritorio
Hyprland con HUD propio, terminal y editor configurados, herramientas de
desarrollo, un CLI (`work`) para trabajar con agentes de IA de forma segura
y un modelo versionado del contexto de cada empresa en la que trabajás.

Todo está declarado como código: la misma configuración instala una máquina
nueva idéntica en minutos, y cualquier cambio es un commit.

> **Para agentes de IA:** el contexto técnico de este repo está en
> [`AGENTS.md`](./AGENTS.md).

---

## Contenido

1. [Cómo está armado (3 repos)](#1-cómo-está-armado-3-repos)
2. [Requisitos](#2-requisitos)
3. [Paso a paso](#3-paso-a-paso)
   - [3.1 Descargar workos y preparar tu repo privado](#31-descargar-workos-y-preparar-tu-repo-privado)
   - [3.2 Configurar](#32-configurar-lo-hace-initsh)
   - [3.3 Validar y publicar](#33-validar-y-publicar-lo-hace-initsh)
   - [3.4 Preparar el pendrive](#34-preparar-el-pendrive)
   - [3.5 Instalar](#35-instalar)
   - [3.6 Post-instalación](#36-post-instalación)
   - [3.7 Traer tus datos (opcional)](#37-traer-tus-datos-opcional)
4. [Uso diario](#4-uso-diario) · [Seguridad](#41-seguridad)
5. [Probar primero en una VM](#5-probar-primero-en-una-vm)
6. [Qué incluye el sistema](#6-qué-incluye-el-sistema)
7. [Estructura de este repo](#7-estructura-de-este-repo)
8. [Problemas frecuentes](#8-problemas-frecuentes)

---

## 1. Cómo está armado (3 repos)

`workos` no tiene datos de nadie. Lo que es tuyo vive en **tu repo
privado**, que importa este como una librería:

```
┌─────────────────────────────────────────┐
│ workos  (este repo, público)            │  módulos NixOS/Home Manager,
│                                         │  CLI `work`, scripts de instalación,
│                                         │  esquema de company-context
└──────────────────▲──────────────────────┘
                   │ input "workos" del flake
┌──────────────────┴──────────────────────┐
│ workos-private  (TU repo, privado)      │  tu usuario, email y claves SSH,
│   creado desde workos-template          │  tus máquinas, tus empresas
└─────────────────────────────────────────┘
      + vault.enc/  (local, cifrado, sin git)  .env y dumps de tus proyectos
```

| Repo | Visibilidad | Para qué |
|---|---|---|
| [`workos`](https://github.com/OscarVargas97/workos) | público | El sistema. No lo modificás para usarlo. |
| [`workos-template`](https://github.com/OscarVargas97/workos-template) | público (template) | El molde de tu repo privado. |
| `workos-private` | **privado, tuyo** | Tus datos. Es el que instalás. |
| [`cyber-shell`](https://github.com/OscarVargas97/cyber-shell) | público | El HUD/barra del escritorio (lo trae `workos` solo). |

En tu computadora los repos van como **carpetas hermanas** (los scripts lo
asumen):

```
~/Repos/Externos/workos/          (o cualquier carpeta, en Windows también)
├── workos/                       este repo
├── workos-private/               tu repo privado
├── iso/                          el ISO de NixOS (paso 3.4)
├── vault.enc/                    opcional: .env y dumps de tus proyectos, CIFRADO (nunca en git)
└── vault/                        vista descifrada, solo mientras está abierto (work vault open)
```

---

## 2. Requisitos

### La máquina donde se instala (destino)

- PC o laptop **x86_64** con arranque **UEFI** (desactivá *Secure Boot* en la BIOS).
- **Todo el disco** elegido se borra y se cifra (LUKS). Mínimo recomendado:
  50 GB de disco y 8 GB de RAM.
- Red: cable al mismo router que la máquina de instalación, o wifi
  (se configura desde el pendrive con `nmtui`).
- Opcional: chip TPM2 (casi todas las laptops desde 2018) para no escribir
  la passphrase del disco en cada arranque.

### La máquina desde donde instalás (la que ya tenés)

Para **configurar y validar** (pasos 3.1 a 3.3) sirve cualquier sistema:
Linux, macOS o Windows con Git Bash.

- `git` y [`gh`](https://cli.github.com/) (GitHub CLI) con sesión iniciada: `gh auth login`.
- Para validar: [`nix`](https://nixos.org/download) **o** Docker/Podman
  (el validador usa un contenedor si no hay Nix).

Para **grabar el pendrive e instalar** (pasos 3.4 en adelante) hace falta
**Linux** (los scripts usan `lsblk`, `dd`, red de Docker en modo host):

- Docker o Podman, `ssh` + `ssh-keygen`, `rsync`, `sudo`, `mtools`,
  `mkpasswd` (paquete `whois` en Debian/Ubuntu/Fedora), `ip`.
- Una clave SSH propia: si no tenés, `ssh-keygen -t ed25519`.
- Un pendrive de 4 GB o más (se borra).

Instalación de dependencias en Fedora / Debian-Ubuntu:

```bash
sudo dnf install git gh docker rsync mtools whois          # Fedora
sudo apt install git gh docker.io rsync mtools whois       # Debian/Ubuntu
```

---

## 3. Paso a paso

### 3.1 Descargar workos y preparar tu repo privado

Todo sale de este repo. Con un solo comando:

```bash
mkdir -p ~/Repos/Externos/workos && cd ~/Repos/Externos/workos
gh repo clone OscarVargas97/workos
workos/init.sh
```

`init.sh` hace los pasos 3.1 a 3.3 por vos:

1. **Tu repo privado:** te pregunta si ya tenés uno (lo descarga) o si
   querés uno nuevo (lo crea **privado** desde `workos-template`, en tu
   cuenta o en una organización). Queda en `workos-private/`, al lado.
2. **Configuración:** corre el configurador del repo privado (3.2).
3. **Validación:** evalúa cada máquina sin instalar nada (3.3).
4. **Publicación:** fija versiones, commitea y pushea (te pregunta antes).

Se puede correr de nuevo cuando quieras: si el repo privado ya está, lo
usa y solo ofrece reconfigurarlo, validarlo y publicarlo.

> Sin preguntas (para automatizarlo o para que un agente de IA lo corra
> con los datos que te pidió): todas las respuestas se pueden pasar como
> variables `WORKOS_*`; ver el encabezado de `init.sh` y de
> `workos-private/scripts/setup.sh`, y [`AGENTS.md`](./AGENTS.md) §6.

### 3.2 Configurar (lo hace `init.sh`)

Para reconfigurar después, a mano:

```bash
cd ~/Repos/Externos/workos/workos-private
scripts/setup.sh
```

El script pregunta, explicando cada dato, y escribe los archivos:

| Pregunta | Dónde queda |
|---|---|
| Usuario, nombre completo, email | `identity.nix` |
| Claves SSH públicas que pueden entrar | `identity.nix` |
| Zona horaria y formato regional | `identity.nix` |
| Hostname y disco de la máquina a instalar | `hosts/<hostname>/` + `flake.nix` |
| Empresa (opcional) | `companies/<empresa>/` |
| Clave SSH privada y email de Bitwarden | `work-os/scripts.env` |

Se puede correr de nuevo: muestra lo actual como valor por defecto. Nunca
pide contraseñas (esas se piden al instalar y no se guardan).

Opcional, a mano:

- `home.nix`: paquetes y aliases solo tuyos (ej. la VPN de tu empresa).
- `companies/<empresa>/`: proyectos y mappings a Notion/Slack
  (ver [`company-context/README.md`](./company-context/README.md)).
- `work-os/secrets-policy.yaml`: qué secretos puede pedir cada agente.

### 3.3 Validar y publicar (lo hace `init.sh`)

Para repetirlo a mano después de cambiar algo:

```bash
scripts/check.sh
```

Evalúa cada máquina del flake sin instalar nada. Tiene que decir `OK` en
todas. Si hay un error, lo muestra con el archivo y la línea.

Después, fijá las versiones exactas (`flake.lock`) y subí tu configuración.
La instalación la descarga de GitHub, así que tiene que estar pusheada:

```bash
scripts/check.sh --lock
git add -A && git commit -m "Configuración inicial" && git push
```

### 3.4 Preparar el pendrive

1. Bajá el **ISO mínimo** de NixOS (el vigente, x86_64) desde
   <https://nixos.org/download/#nixos-iso> y guardalo en la carpeta `iso/`
   (al lado de `workos/`). Verificá su SHA-256 contra el de la página.
2. Conectá el pendrive y corré:

```bash
cd ~/Repos/Externos/workos/workos/work-os/scripts
./prepare-installer-usb.sh
```

Te deja elegir el pendrive (solo muestra USB extraíbles), pide confirmación
y lo graba con tu clave SSH ya autorizada: no hace falta tocar nada en la
consola de la máquina destino.

### 3.5 Instalar

> ⚠️ Esto **borra todo el disco** de la máquina destino.

1. En la máquina destino: booteá desde el pendrive en modo **UEFI**. Si es
   por wifi, escribí `nmtui` en su consola y conectate.
2. En tu máquina:

```bash
./nixos-anywhere-deploy.sh
```

El script:

1. Encuentra solo el pendrive en tu red (o te pide la IP).
2. Te deja elegir qué máquina de tu repo privado instalar.
3. Detecta el hardware real y te muestra el `hardware-configuration.nix`;
   escribí `si` para commitearlo y pushearlo a tu repo privado.
4. Te pide la **contraseña de tu usuario** y la **passphrase del disco**
   (guardala bien: sin ella el disco es irrecuperable).
5. Pide confirmación final (`si`) y instala. La máquina se reinicia sola.

Primer arranque: la máquina pide la passphrase del disco en su consola
(una sola vez si tiene TPM2, después del paso 3.6).

### 3.6 Post-instalación

Cuando la máquina ya arrancó con NixOS:

```bash
./post-install-setup.sh
```

Se puede re-correr las veces que haga falta. Hace:

- **Disco: TPM2 + PIN.** Desde ahí, al encender se escribe un PIN corto en
  vez de la passphrase. Te pide tu contraseña (sudo), la passphrase actual
  y el PIN nuevo. La passphrase sigue sirviendo como recuperación: guardala
  en Bitwarden.
- Configura `gh` en la máquina nueva con tu token.
- Clona `workos` y `workos-private` en `~/Repos/Externos/workos/` y copia
  el vault **cifrado** (`vault.enc`; nunca uno en claro).
- Crea `~/.config/work-os/companies.conf` y `projects.conf`.
- Si tu `home.nix` instala Twingate o Moonlight, te guía para activarlos.
- **Códigos TOTP** (si activaste `workos.security.totp`): muestra dos QR
  para escanear con la app de códigos del teléfono, "desbloqueo" y "sudo",
  cada uno con 5 códigos de emergencia (imprimilos). Después, activá
  `workos.security.totp.enforce = true` en tu repo privado y `rebuild`: sin
  eso, borrar el archivo del código desactivaría el del bloqueo. Ver
  [sección 4.1](#41-seguridad).
- Te indica cómo iniciar sesión en Bitwarden (`rbw`), que siempre es manual.

### 3.7 Traer tus datos (opcional)

Desde tu máquina anterior (Linux), con `workos` y tu `workos-private`
clonados al lado igual que en 3.1.

**1. Mapear tus repos** (a dónde va cada uno en la máquina nueva):

```bash
./map-repos.sh --list     # qué repos hay, su remote y cuáles faltan mapear
./map-repos.sh            # pregunta solo los que faltan
```

Reglas del mapeo:

| Si el repo es… | Empresa | Queda en |
|---|---|---|
| de una empresa | su clave en minúscula (la de `companies/<empresa>`), ej. `acme` | `~/Repos/Acme/<destino>` |
| personal o de terceros | vacío | `~/Repos/Externos/<destino>` |
| un duplicado o algo que no querés | cualquiera, destino `-` | no se migra |

El destino puede ser `Proyecto/repo` para agrupar repos hermanos de un mismo
proyecto (lo suelto de esa carpeta, como `docs/`, también se migra). El
mapeo queda en `work-os/repo-companies.conf` de tu repo privado: commitealo
y sirve para la próxima máquina.

**2. Migrar:**

```bash
./migrate-pc.sh
```

Copia tus repos según el mapeo, `~/.ssh`, sesiones de `gh`/`docker`/`aws`,
configuración de Claude Code, historial de zsh, conexiones de DBeaver y el
perfil de Brave. Si encuentra un repo sin mapear, te lo pregunta en el
momento.

`make` en `work-os/scripts/` muestra todos estos comandos en orden.

---

## 4. Uso diario

| Tarea | Cómo |
|---|---|
| Aplicar un cambio de tu configuración | editar `workos-private`, luego `rebuild` (o `Super+Ctrl+R`) |
| Probar un cambio de `workos` sin pushearlo | editarlo en `../workos` y `rebuild`: usa el clon local si existe |
| Actualizar `workos` al último commit | `nix flake update workos` en `workos-private`, commit, `rebuild` |
| Actualizar NixOS y paquetes | `nix flake update` en `workos-private`, commit, `rebuild` |
| Volver a la versión anterior | elegirla en el menú de arranque |
| Entrar a un proyecto | `work enter <proyecto>` (ver [`work-os/README.md`](./work-os/README.md)) |
| Usar los `.env`/dumps de tus proyectos | `work vault open` → están en `~/Repos/Externos/workos/vault/`; `work vault close` al terminar |
| Ver los atajos de teclado | `Super+K` |

### 4.1 Seguridad

Lo que está en GitHub no alcanza para entrar a nada: los secretos viven
cifrados o en Bitwarden, y cada acceso pide algo que sabés y algo que
tenés (el teléfono o el chip de la máquina). Se activa en tu repo
privado con `workos.security` (ejemplo en el `home.nix` del template);
detalles y límites en [`docs/DECISIONS.md` #15](./docs/DECISIONS.md).

| Para… | Te pide |
|---|---|
| Encender la laptop | PIN del disco (TPM2) |
| Desbloquear la pantalla | contraseña y código **"desbloqueo"** juntos en el mismo campo, sin espacio (hyprlock tiene un solo campo) |
| Login de consola, pantalla de inicio | contraseña, y después el código **"desbloqueo"** |
| `sudo`, `rebuild`, `su`, `pkexec` y diálogos de permisos | contraseña + código **"sudo"** de la app |
| SSH desde tu red (`trustedNetworks`) | tu clave SSH |
| SSH desde otra red | tu clave SSH + código "sudo" |
| Abrir el vault (`work vault open`) | Bitwarden desbloqueado (`rbw unlock`: contraseña maestra; la cuenta con su 2FA) |

Cada código sirve una sola vez, y se consume aunque la contraseña esté
mal: si te equivocás, esperá el código siguiente de la app (máx. 30 s).
Tras 3 intentos en 30 s hay que esperar un poco (frena la fuerza bruta).
Ojo con `sudo`: si el código falla vuelve a preguntar (hasta 3 veces) y
cada reintento gasta un intento; mejor cortá con Ctrl-C y esperá 30 s.

**Recuperación** (guardalo antes de necesitarlo):

- **Perdí el teléfono:** entrá con un código de emergencia (los 5 que
  imprimiste) y regenerá los códigos con `workos-totp-setup --force`.
- **Olvidé el PIN del disco / actualicé la BIOS:** el arranque pide la
  passphrase de recuperación (en Bitwarden); después corré
  `post-install-setup.sh` para volver a enrolar el PIN.
- **Algo de PAM quedó mal y no puedo hacer sudo:** elegí la generación
  anterior en el menú de arranque.
- Los códigos TOTP van en una app del teléfono (Aegis, Google
  Authenticator), **no** en Bitwarden: si los guardás ahí, la bóveda tiene
  los dos factores juntos.

**Vault:** `work vault init` la primera vez (crea la clave `workos-vault`
en Bitwarden), `work vault import <carpeta>` para cifrar un vault viejo en
claro (verifica la copia y ofrece borrar el original), `open`/`close`/`status`.

---

## 5. Probar primero en una VM

Tu repo privado ya trae la máquina `vm` (QEMU/GNOME Boxes, disco `/dev/vda`):

1. Creá una VM UEFI con 4 GB de RAM y 40 GB de disco.
2. Preparale el ISO en vez de un pendrive:
   `./prepare-installer-usb.sh copia-del.iso` (modifica ese archivo).
3. Conectale ese archivo como **disco USB** (no como CD: el menú preparado
   busca la partición EFI del "pendrive", que como CD no existe y el
   arranque cae a la consola de GRUB), arrancala y seguí desde el paso 3.5
   eligiendo `vm`. En QEMU:
   `-device qemu-xhci -drive file=copia-del.iso,format=raw,if=none,id=u -device usb-storage,drive=u`.

### Pruebas automáticas

En una máquina Linux con KVM y Nix (cualquier máquina ya instalada con
workos sirve), desde este repo:

```bash
# Seguridad en VMs: TOTP en sudo/bloqueo/login, SSH dentro y fuera de la
# red de confianza, TPM2 + PIN, vault cifrado (~5 min).
nix build .#checks.x86_64-linux.security -L

# Instalación completa en una VM con TPM emulado, con los scripts reales:
# ISO -> deploy -> passphrase -> post-install (TPM2+PIN, TOTP) -> PIN -> sudo con código.
tests/e2e-install.sh
```

No tocan nada fuera de sus directorios de trabajo; `e2e-install.sh` usa un
repo privado de prueba creado desde el template.

---

## 6. Qué incluye el sistema

- **Escritorio:** Hyprland (tiling, Wayland), HUD [cyber-shell](https://github.com/OscarVargas97/cyber-shell),
  tema oscuro, greetd como pantalla de login.
- **Terminal:** kitty + zsh con Powerlevel10k, autosugerencias, fzf.
- **Editor:** Neovim como IDE y editor por defecto.
- **Desarrollo:** devenv/direnv por proyecto, Podman compatible con Docker,
  Node 22, pnpm, uv (Python), DBeaver, AWS CLI, GNOME Boxes.
- **Agentes de IA:** Claude Code, [herdr](https://herdr.dev) (sesiones
  persistentes de agentes), CLI `work`, MCP de secretos con allowlist.
- **Secretos:** Bitwarden (`rbw` para scripts, app gráfica para uso manual).
- **Seguridad:** disco cifrado (LUKS + TPM2 opcional), firewall, SSH solo
  por clave, sin login de root.
- **Apps:** Brave, Slack, Discord, mpv, imv, zathura.

Las decisiones de diseño detrás de cada elección están en
[`docs/DECISIONS.md`](./docs/DECISIONS.md).

---

## 7. Estructura de este repo

```
init.sh                   punto de entrada: prepara tu repo privado (3.1)
flake.nix                 lib.mkHost + nixosModules (la API que usa tu repo privado)
modules/workos.nix        opciones de identidad (workos.user.*, workos.secretsPolicy)
modules/security.nix      2FA con TOTP (bloqueo, login, sudo, SSH) y tiempo de bloqueo (workos.security.*)
tests/security.nix        test en VMs de todo lo de seguridad (nix build .#checks.x86_64-linux.security)
tests/e2e-install.sh      instalación completa en una VM con TPM emulado, con los scripts reales
hosts/vm/                 base del sistema (configuration.nix), disco (disko), VM
home-manager/             escritorio, terminal, editor, herdr, cyber-shell, devenv
work-os/cli/              CLI `work` y `work docs` (Notion/Slack)
work-os/mcp/              servidor MCP de secretos
work-os/scripts/          pendrive, instalación, post-instalación, mapeo de repos, migración
company-context/          esquema, JSON Schema y tooling de company-context
docs/DECISIONS.md         decisiones de arquitectura
```

Lo que expone `flake.nix`:

| Output | Qué es |
|---|---|
| `lib.mkHost [ módulos ]` | Arma una máquina completa: base + Home Manager + `modules/workos.nix` + tus módulos |
| `nixosModules.disko-default` | Disco completo LUKS + ext4 (cambiá `disko.devices.disk.main.device`) |
| `nixosModules.vm` | Hardware y disco de una VM QEMU/Boxes |

---

## 8. Problemas frecuentes

| Síntoma | Causa / solución |
|---|---|
| `check.sh` falla con `HTTP error 404` al bajar un input | El repo no existe o es privado sin acceso: revisá `gh auth status`. |
| `nixos-anywhere-deploy.sh` no encuentra el pendrive | La máquina destino no tiene red, o bootea en modo BIOS: usá UEFI. Podés escribir la IP a mano (`ip a` en su consola). |
| Pide la passphrase del disco en cada arranque | Falta enrolar el TPM2: corré `post-install-setup.sh`. |
| `rebuild` dice que no encuentra el repo privado | Clonalo en `~/Repos/Externos/workos/workos-private` o usá `WORKOS_PRIVATE=<ruta> rebuild`. |
| No puedo entrar por SSH | Solo entran las claves de `workos.user.sshKeys` en `identity.nix`. |
