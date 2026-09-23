# Este sistema: WorkOS (NixOS declarativo)

Estás en una máquina WorkOS: NixOS + Home Manager, definida entera por dos
repos en `~/Repos/Externos/workos/`:

- `workos-private/`: el flake de entrada (identidad, máquinas, empresas).
- `workos/`: el sistema en sí (módulos, CLI `work`, scripts), público y
  sin datos personales.

Antes de cambiar algo del sistema, leé `AGENTS.md` en ambos repos.

## Reglas de operación

- **El sistema es el repo.** Nunca `nix-env -i`, `nix profile install`,
  editar `/etc`, ni dotfiles sueltos en `~`: no sobreviven y rompen la
  reproducibilidad. Para agregar o cambiar algo permanente: editar el repo
  que corresponda (lógica → `workos`, datos → `workos-private`) →
  `workos-private/scripts/check.sh` → commit/push → avisar que falta el
  `rebuild`.
- **Nada personal ni de una empresa en `workos`**: es público. Eso va en
  `workos-private`.
- **Herramientas de un solo uso**: `nix shell nixpkgs#<paquete>` o
  `nix run nixpkgs#<paquete> -- <args>` (no instala nada).
- **Runtimes de proyecto** (node, python, go, etc. con versión fija): por
  proyecto con devenv + direnv (`devenv.nix` / `.envrc`), nunca globales.
- **sudo pide contraseña (y un código TOTP del teléfono) y no los tenés.** Todo lo que requiera root (sobre
  todo `nixos-rebuild`) lo corre la persona: pedile `rebuild` o
  `Super+Ctrl+R`. Tu trabajo termina en "valida y está pusheado".
- **Nada destructivo sin confirmación explícita** (particionar, borrar
  datos, `git push --force`, `herdr server stop` que cierra paneles).
- **Nada hardcodeado** (rutas de una persona, IPs, secretos). Usar
  `$HOME` y descubrir en runtime.

## Dónde está cada cosa

| Qué | Dónde |
|---|---|
| Flake de entrada (identidad, hosts) | `~/Repos/Externos/workos/workos-private` |
| Sistema (módulos, CLI, scripts) | `~/Repos/Externos/workos/workos` |
| Metadata de cada empresa | `~/Repos/Externos/workos/workos-private/companies/<empresa>` |
| Secretos de proyectos (cifrados, sin git) | `~/Repos/Externos/workos/vault.enc`; `work vault open` los monta en `vault/` |
| Repos de trabajo | `~/Repos/<Empresa>/` |
| Repos personales/de terceros | `~/Repos/Externos/` |
| Registro de proyectos para `work` | `~/.config/work-os/{projects,companies}.conf` |
| Este archivo | generado por Home Manager (`docs/claude-system.md` de `workos`, más lo que sume `workos-private`); editarlo ahí, no acá |

## Comandos del sistema

- `rebuild [switch|boot|test]`: aplica `workos-private` (con `../workos`
  local si existe) al host actual (sudo).
- `work projects | enter <proyecto> | status | secret get <n> --skill <s> | docs <concept_id>`:
  CLI de Work OS. `work enter` hace `cd` y regenera el `CLAUDE.md` del
  proyecto con el contexto de su empresa.
- `herdr`: multiplexor de terminales/agentes (probablemente estás corriendo
  dentro de un panel de herdr).
- `ags request -i cyberpunk <pedido>`: habla con el HUD (menús, presets:
  `perf full|balanced|performance`, `apps-menu`, `toggle-hud`...).
- `gh` para GitHub (git usa sus credenciales por https); `rbw` para
  Bitwarden (nunca manejes la contraseña maestra).

## Entorno

- Escritorio: Hyprland + HUD cyber-shell (AGS/gjs), kitty, wofi, Brave.
  Atajos: `hyprctl binds -j` o `Super+K`.
- Contenedores: podman con compatibilidad Docker (`docker`,
  `docker-compose` funcionan; `DOCKER_HOST` apunta al socket de podman).
- VMs: libvirtd + GNOME Boxes.
- Shell: zsh (globs sin comillas fallan con "no matches found").
- Memoria: zram (swap comprimida en RAM). Una sesión de Claude Code usa
  ~550 MB: es normal.

## Si trabajás desde ssh o fuera de la sesión gráfica

Para `hyprctl`, `ags request` o apps gráficas exportá antes:

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export WAYLAND_DISPLAY=$(basename "$(ls $XDG_RUNTIME_DIR/wayland-? | head -1)")
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t $XDG_RUNTIME_DIR/hypr | head -1)
```

## Diagnóstico rápido

- RAM/CPU por proceso: `ps -eo rss,%cpu,comm --sort=-rss | head`; si
  `free` oscila pero ningún proceso lo muestra, mirá `AnonPages` en
  `/proc/meminfo` y muestreá varias veces (el GC de gjs limpia en ciclos).
- Binarios de Nix envueltos se llaman `.<nombre>-wrap` en `ps`: buscalos
  con `pgrep -f <ruta>`, no `pgrep -x`.
- Sin ptrace (`ptrace_scope=1`): no hay gdb/strace sobre procesos ajenos.
- Logs: `journalctl --user -b` (sesión) y `journalctl -b` (sistema).
