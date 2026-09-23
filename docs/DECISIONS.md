# Decisiones de arquitectura

Registro de las decisiones de diseño de `workos`. La numeración es
estable: el código y los comentarios la referencian (`DECISIONS.md #N`).

## 1. Migración / dual-boot

**Decisión:** probar primero en una máquina virtual. El objetivo final es
NixOS puro (sin la distro anterior conviviendo a largo plazo), pero no se
instala nada sobre la máquina real hasta tener todo listo (flake, docs de
instalación) para que la persona haga la instalación por su cuenta.

**Impacto:** ningún comando de instalación/particionado se ejecuta
automáticamente — sigue siendo `[REQUIERE APROBACIÓN]` y manual.

## 2. Gestor de secretos

**Decisión:** modelo mixto, no una sola herramienta:

- **sops-nix** para secretos de sistema que se necesitan antes de tener
  sesión interactiva (WiFi, LUKS) — Bitwarden no sirve ahí, requiere
  desbloqueo manual.
- **Bitwarden** (`bw`/`rbw`) como backend para tokens que sí usan agentes
  (Notion, GitHub, Slack). `work secret get <nombre>` en el CLI de
  `work-os` actúa como wrapper: solo funciona con la sesión ya
  desbloqueada por una persona (la IA nunca desbloquea el vault), y una
  policy de allowlist (`workos.secretsPolicy`, plantilla en
  `work-os/cli/secrets-policy.yaml`) define qué nombre de secreto puede
  pedir cada skill/agente — default-deny.
- Exposición a agentes vía MCP propio (`work-os/mcp/secrets/`): el agente
  pide por nombre, la policy decide, nunca navega el vault crudo.

## 3. Proyecto(s) piloto

**Decisión:** el company-context de una empresa se modela arrancando por
los proyectos con stacks corriendo activamente (según la auditoría
inicial de la máquina), más de uno desde el inicio, usando el tooling
agnóstico de `company-context/tooling/`.

## 4. Slack

**Decisión:** incluido como fuente del Company Context Layer. Igual que
Notion, necesita modelo de provenance propio — y con más cuidado
todavía: una conversación de Slack es por defecto
`confidence: unverified` / tipo `conversación`, nunca se trata como regla
empresarial vigente salvo que quede promovida explícitamente a una
`decision` en `decisions/` de la instancia.

## 5. Terminal / multiplexor / agentes persistentes

**Decisión:** Hyprland tiling + zsh, sin tmux/zellij — Hyprland ya cubre
splits/workspaces, no hace falta multiplexor clásico.

**[herdr.dev](https://herdr.dev/)** es el runtime de sesiones
persistentes para agentes de coding (Rust, binario único). Mantiene
agentes (Claude Code, Codex, Cursor, opencode, etc.) corriendo aunque se
cierre la laptop, se reinicie o se corte la red; detecta si cada agente
está trabajando/bloqueado/inactivo; soporta multi-máquina vía SSH.
`work enter <proyecto>` puede registrar/adjuntarse a la sesión de herdr
correspondiente en vez de lanzar un proceso efímero.

**Reproducibilidad:** herdr no está en nixpkgs y upstream se instala vía
`curl | sh`. Resuelto con releases pineadas por tag + hash
(`home-manager/herdr.nix`, `fetchurl` de binarios musl estáticos).

## 6. Canal NixOS y actualización

**Decisión:** canal estable (el vigente al instalar) + actualización
mensual programada, revisada con diff antes de aplicar.

## 7. Confirmación de comandos destructivos

**Decisión:** en comandos que puedan romper algo, prompt interactivo
sí/no por defecto, más flag `--yes` disponible para automatizaciones
propias. Nunca invocado por un agente sin que la persona lo haya tipeado
explícitamente.

## 8. Entorno gráfico

**Navegador:** Brave. Chromium por debajo (mismas DevTools/extensiones que
Chrome), bastante menos RAM que Chrome gracias a su bloqueador de
ads/trackers integrado (menos JS de terceros por pestaña).

**Slack:** app nativa (Electron), no solo navegador.

**Display manager:** greetd + tuigreet (mínimo, basado en texto, sin
GNOME/KDE de fondo).

**VPNs/herramientas de una empresa puntual** (ej. Twingate): no van en
este repo, se agregan desde el repo privado.

## 9. Dotfiles como código

**Decisión:** todo lo que se porte de una máquina anterior (zsh, kitty,
apps por defecto, shortcuts) se maneja **vía home-manager**, no como
archivos copiados/versionados sueltos.

- **Nunca copiar un dotfile tal cual.** Un `~/.zshrc`/`kitty.conf` real
  suele tener rutas absolutas de la máquina de origen, plugins
  instalados con `git clone` a mano, o referencias a paquetes que en
  NixOS vienen de otro lado. Se traduce su contenido/intención a
  opciones de home-manager (`programs.zsh.*`, `programs.kitty.*`,
  etc.), no se pega el archivo.
- **Rutas relativas/portables, nunca absolutas fijas.** Si algo
  necesita el home del usuario, usar `config.home.homeDirectory` o
  `$HOME` en runtime — nunca `/home/<usuario>` a mano.
- **La "mantención automática" es el propio flujo de home-manager:**
  cambiar un dotfile = editar el `.nix` correspondiente, commitear,
  pushear, `rebuild`. No hay un mecanismo de sync aparte que mantener —
  el mecanismo YA es git + Nix.
- Plugins de zsh: paquetes de nixpkgs o `programs.zsh.plugins` con
  `src` pineado por flake input si no está en nixpkgs — no
  `oh-my-zsh`/`git clone` imperativo dentro de la home.

## 10. Público vs. privado: un sistema, tres repos

**Decisión:** el sistema (NixOS + Home Manager) y el CLI/tooling de
agentes (`work-os`) viven juntos en **un solo repo público**, `workos`,
agnóstico a cualquier persona o empresa. Todo lo que identifica a una
persona o empresa vive en su **repo privado**, que es el flake de
entrada del sistema e importa `workos` como input:

- `workos` (público): módulos (`lib.mkHost`, `nixosModules.*`), opciones
  de identidad (`modules/workos.nix` — solo declaradas, sin valores),
  CLI, scripts, esquema y tooling de company-context.
- `workos-template` (público): el esqueleto vacío del repo privado —
  de ahí sale el de cada persona ("Use this template", que a diferencia
  de un fork permite que la copia sea privada).
- Repo privado de cada persona: valores de identidad (usuario, email,
  claves SSH, zona horaria), hosts reales y su hardware, extras
  personales/de empresa, instancias de company-context
  (`companies/<empresa>/`), perfil de máquina de los scripts
  (`work-os/scripts.env`, `work-os/repo-companies.conf`) y la
  secrets-policy real.
- `vault/` (dumps, `.env` de proyectos) no va a ningún repo — local,
  sin git.

**Por qué:** un solo sistema (no se mantienen dos configuraciones
paralelas): lo privado es solo datos y extensiones sobre los mismos
módulos. Cualquiera puede usar `workos` tal cual y generar su propio
privado desde el template.

## 11. Multi-empresa: una instancia de company-context por empresa

**Decisión: el "sistema empresarial" y el uso personal son dos cosas
separadas, no una sola con una opción multi-tenant adentro.**

1. **Una instancia de company-context por empresa**, sin namespaces ni
   permisos internos entre empresas. Esto es lo que cualquier empresa
   adoptaría como su propio sistema.
2. **El uso personal es multi-empresa por naturaleza**: una persona
   puede correr varias instancias del punto 1 en paralelo (una por
   empresa/cliente) desde su repo privado — `work-os` sabe a qué
   instancia resolver según el proyecto (`work enter`, `companies.conf`).
   Esa coordinación vive en la capa personal, **no** en el sistema
   empresarial en sí.
3. **Lo que mantiene a todas compatibles es seguir el mismo esquema**
   (`company-context/SCHEMA.md`) — la capa personal las trata a todas
   igual, sin lógica especial por empresa.
4. **No se construye ningún mecanismo de sharing/permisos entre
   instancias de empresa** hasta que haya un caso real.
5. La clave de empresa (`companies.conf`, nombres de secretos como
   `notion-token-<empresa>`) va en minúscula.

## 12. Resumen para IA

**Decisión:** cada repo tiene un `AGENTS.md` (con `CLAUDE.md` apuntando a él) que mapea convenciones, esquemas y
criterios por sección, pensado para que una IA pueda, sin releer todo el
historial: (a) auditar un sistema existente contra estas reglas, o (b)
repetir este mismo proceso en una máquina/empresa nueva.

## 13. Hardening declarativo + pentest activo, sin perder superusuario

**Decisión:** todo control de seguridad que se agregue queda como
código Nix versionado (nunca un paso manual de una sola vez) — el mismo
criterio de "dotfiles como código" (#9) aplicado a seguridad. A la vez,
el hardening no le resta acceso total de superusuario a la persona (sudo
sigue pidiendo contraseña, como siempre).

**Qué se implementó bajo este criterio:**
- `networking.firewall.enable`, `rp_filter` estricto, secretos de
  `nixos-anywhere-deploy.sh` fuera de argv (stdin/env-file/temp files
  con `chmod 600`) — en `hosts/vm/configuration.nix` / los scripts, no
  pasos manuales.
- Cifrado de disco (LUKS) vía `disko-config.nix` +
  `--disk-encryption-keys` de `nixos-anywhere` — la passphrase se pide
  interactiva o se toma de `scripts.env` (mismo patrón que
  `LOGIN_PASSWORD`), nunca se guarda en ningún lado. Deliberadamente
  sin `keyFile` de auto-desbloqueo: eso anularía la protección (la
  llave viajaría con el disco robado) — "replicable" significa que el
  *proceso* de pedir/usar la passphrase es el mismo en cada máquina, no
  que la passphrase se auto-provea.
- En hardware real con TPM2: `systemd-cryptenroll` (desde el repo
  privado, por host) — la clave queda sellada al chip y solo se libera
  si el firmware/bootloader no cambiaron; un disco robado sin la placa
  sigue sin servir.

**Pentest activo (no solo revisión estática):** los controles se
prueban contra el sistema vivo (nmap externo, intento de bypass SSH,
intento de escalación vía grupo podman/socket), no se da por sentado
que un `.nix` bien escrito ya "funciona" en la práctica.

**Regla derivada:** cualquier cambio de seguridad se declara en
Nix/script versionado, se prueba activamente contra el sistema real, y
no le agrega fricción a la persona como superusuario salvo que ella
misma la pida.

## 14. Estructura de carpetas para repos reales

**Decisión:** los repos que migra `migrate-pc.sh` van bajo
`~/Repos/<Empresa>/` (una por empresa) o `~/Repos/Externos/` (repos
personales/de terceros, sin company-context asociado) — mayúscula
inicial en la carpeta, clave de empresa en minúscula.

- El mapeo repo→empresa/nombre-destino vive en
  `work-os/repo-companies.conf` del repo privado (perfil de la máquina).
- Alias de acceso rápido en `home-manager/zsh.nix`: `cdrepos`,
  `cdexternos`; uno por empresa (`cd<empresa>`) desde el repo privado.
- Cada repo migrado se registra en `~/.config/work-os/projects.conf`
  del destino con su ruta nueva bajo `Repos/`.
- `workos` en sí vive en `~/Repos/Externos/workos/` (`workos/`,
  `workos-private/`, `vault/`) — proyecto personal, clasifica como
  externo.

## 15. Segundo factor sin hardware extra y vault cifrado

**Contexto:** el sistema es replicable a propósito, pero lo que viaja con
la replicación (vault con `.env` y dumps, claves, sesiones) y lo que se
abre con un solo factor (disco con TPM2 sin PIN, sudo, bloqueo de
pantalla) quedaban expuestos a quien tuviera el disco, la laptop
desbloqueable o una copia. Se descartó una llave física (FIDO2) por
logística: hay que cargarla y tener respaldo. El segundo factor pasa a
ser **el teléfono** (TOTP) y la raíz de confianza **Bitwarden**
(contraseña maestra + 2FA de la cuenta).

**Decisión** (`modules/security.nix`, todo apagado por defecto, lo activa
el repo privado con `workos.security.*`):

| Qué | Cómo |
|---|---|
| Disco | TPM2 **+ PIN** (post-install-setup.sh). Sin PIN, el desbloqueo automático por TPM2 es vulnerable a reemplazar la partición cifrada con acceso físico breve; con PIN no. PCR 7 (no 0+7) para no re-enrolar en cada actualización de BIOS. La passphrase de LUKS queda como recuperación (en Bitwarden). |
| Bloqueo de pantalla, login de consola, pantalla de inicio | contraseña + código **"desbloqueo"** (`totp.enable`). Las tres a la vez: si solo el bloqueo pidiera código, se lo esquiva cambiando a una consola de texto. El secreto vive en el home (hyprlock corre como el usuario y no puede leer uno de root): protege contra quien tiene la laptop en la mano, no contra malware en la sesión. |
| sudo, su, polkit (pkexec y diálogos gráficos de permisos) | contraseña + código **"sudo"**, secreto de root en `/var/lib/workos/totp/<usuario>` (`user=root`): un proceso del usuario no lo puede leer ni reemplazar. Código distinto del de desbloqueo. Las tres vías a root a la vez: si una quedara solo con contraseña, sería la forma de esquivar el código. |
| SSH | solo clave desde `sshTotp.trustedNetworks`; clave + código "sudo" desde cualquier otra red (`sshTotp.enable`). Dentro de la red de confianza el TOTP rompería scripts, herdr y `pc`. La contraseña de Unix nunca sirve por SSH. Ojo: la red se reconoce por IP, y `192.168.1.0/24` también la usan muchos wifis públicos; ahí igual hace falta la clave privada. |
| Menú de arranque | sin editor de la línea del kernel (`systemd-boot.editor = false`): con acceso físico permitía agregar `init=/bin/sh` o similares. |
| Códigos | un solo uso (`-d`), máx. 3 intentos cada 30 s (`-r 3 -R 30`, frena la fuerza bruta), ±30 s de desfase de reloj. |
| vault | **cifrado con gocryptfs** (`work vault`, `work-os/scripts/vault.sh`): solo existe cifrado (`vault.enc`); se monta al abrirlo con la clave de Bitwarden (`workos-vault`). Solo viaja cifrado entre máquinas. gocryptfs y no age: cifra archivo por archivo, sirve para dumps de varios GB sin cargarlos en RAM. |
| Token de GitHub en `/root/.config/nix/nix.conf` | eliminado: `rebuild` usa los clones locales. |

**Salvaguardas:**
- Por defecto el PAM con TOTP usa `nullok`: sin secreto creado, entra con
  contraseña (nadie queda afuera entre la instalación y
  `workos-totp-setup`). El secreto de sudo es de root, así que borrarlo
  requiere ya ser root; pero el de desbloqueo está en el home, y borrarlo
  haría que el bloqueo vuelva a pedir solo la contraseña, en silencio. Por
  eso, **después** de `workos-totp-setup`, se activa `totp.enforce`
  (sin nullok): sin secreto no entra nadie.
- Cada código genera 5 códigos de emergencia de un uso: impresos y fuera
  del teléfono y la laptop. Los códigos TOTP NO van en Bitwarden (sería
  guardar los dos factores en un solo lugar).
- Si algo de PAM queda mal: arrancar la generación anterior desde el menú
  de arranque (requiere el PIN del disco).
- Probado en VMs, incluidos ataques: `nix build .#checks.x86_64-linux.security`
  (tests/security.nix: su/pkexec sin código, reusar un código, fuerza
  bruta, cruzar los dos códigos, SSH con contraseña, borrar el secreto,
  TPM2 sin PIN, nombres visibles en el vault) y la instalación completa en
  `tests/e2e-install.sh`.
- PIN del disco: al menos 6 dígitos; el TPM bloquea tras varios intentos
  fallidos, pero un PIN de 4 dígitos se adivina antes.

**Límites conocidos:** sin Secure Boot (lanzaboote) un atacante con
acceso físico prolongado podría alterar el arranque para capturar el PIN;
tras reiniciar por SSH la máquina queda esperando el PIN en su consola;
una actualización de BIOS puede pedir la passphrase de recuperación y
re-enrolar (`post-install-setup.sh` de nuevo).

## Regla general — sin datos personales fijos, prácticas seguras siempre

Aplica a **todo** este repo (código, scripts y comentarios):

- Nada en este repo nombra ni hardcodea datos de una persona, empresa o
  máquina específica (usuarios, emails, rutas de home, IPs, hostnames,
  nombres de repos privados, listas de proyectos, contraseñas, tokens).
  Lo que varía se declara como opción (`modules/workos.nix`) con el
  valor en el repo privado, se descubre dinámicamente, o se pide
  interactivamente por consola — nunca se asume.
- Cada prompt interactivo va acompañado de una explicación breve de qué
  es y para qué se usa, no solo la etiqueta del campo.
- Preferir descubrimiento dinámico (ej. buscar repos git reales) sobre
  listas mantenidas a mano.
- Ningún secreto se imprime en logs ni se guarda en texto plano en un
  archivo versionado — tampoco en el repo privado.
- Confirmación explícita antes de acciones destructivas (ver #7).
