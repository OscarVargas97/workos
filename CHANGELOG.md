# Novedades

Lo que trae cada cambio de Work OS, lo más nuevo arriba.

## Calidad de ia-qa · en revisión

`ci/14-calidad` · #14 (solicitud ia-qa#27)

### Nuevo
- Calidad de ia-qa (catálogo 0.2.0, perfiles `python` y `nix`): hooks de git (`commit-msg`, `pre-push`), hook Stop de Claude, workflows `calidad`, `vigilancia-main` y `sonarcloud`, `.calidad/checks.sh` y `.calidad.yml`.
- Activar en el clon: `git config core.hooksPath .githooks`.

### Cambios
- Código Python formateado y corregido para ruff (`ruff.toml`); sin cambios de comportamiento.

## Espacio workos con su Project · en revisión

`docs/13-agents-project` · #13

### Cambios
- `AGENTS.md` enlaza el Project del espacio y resume «Cómo se trabaja» (flujo de ia-qa).

## Sin herdr · en desarrollo

`chore/10-fuera-herdr` (apilada sobre `feat/3-work-espacio`) · #10 (solicitud #9)

### Cambios
- **herdr sale del sistema**: se quita `home-manager/herdr.nix` y sus menciones. Los worktrees, terminales y agentes se manejan desde Orca.
- **`work espacio`** crea el espacio y lo registra en Orca (lo hace `ws.py nuevo`); ya no abre herdr.

## Crear un espacio en un paso · en revisión

`feat/3-work-espacio` · #2 (#3)

### Nuevo
- **`work espacio <nombre>`**: crea un espacio de ia-workspace en `~/Espacios/<nombre>`, lo registra en herdr y lo abre, llamando a `ws.py nuevo`. La base de ia-workspace se busca en `~/Repos/Externos/ia-workspace`; las dos rutas se cambian con `WORK_OS_IA_WORKSPACE` y `WORK_OS_ESPACIOS_DIR`.
