# work-os

CLI y herramientas del workflow de desarrollo, agnóstico a la empresa.
Subcarpeta del repo `workos` (ver `../docs/DECISIONS.md` #10) — las
decisiones de todo el repo (incluida esta parte) viven en
`../docs/DECISIONS.md`.

```
cli/        implementación del comando `work` (Fase 5/6)
skills/     skills de Claude Code (Fase 6)
mcp/        servidor MCP propio (Fase 6/11)
scripts/    utilidades read-only
```

## Configuración local (fuera del repo, por diseño)

`work` lee tres archivos en `~/.config/work-os/` — ninguno vive en git,
son datos locales o gestionados por Nix, no código:

- `projects.conf` (editable a mano, ver `cli/projects.conf.example`):
  registro de proyectos → ruta → empresa.
- `companies.conf` (editable a mano, ver `cli/companies.conf.example`):
  registro de empresa → ruta a su instancia de `company-context`.
- `secrets-policy.yaml`: symlink al store, gestionado por Nix (opción
  `workos.secretsPolicy`, el repo privado pone la suya) — no es
  editable a mano, cambiarlo es un commit + rebuild (ver
  `docs/DECISIONS.md` #2).

## cli/docs/ — `work docs <concept_id>` (Fase 9)

Fetch en vivo (sin cache/sync) del contenido mapeado a un `concept_id`
en `mappings/notion.yaml` o `mappings/slack.yaml` de la
`company-context` del proyecto actual (resuelto vía `projects.conf` +
`companies.conf`, igual que `work enter`). Requiere:

1. Estar parado en un proyecto registrado con empresa asignada.
2. Que `secrets-policy.yaml` tenga `work-docs` con
   `notion-token-<empresa>` y/o `slack-token-<empresa>` en su lista
   (default-deny, Fase 6) — acotado por empresa a propósito (el uso personal es
   multi-empresa por naturaleza, `DECISIONS.md` #11): activar
   `work-docs` para una empresa no da acceso al token de otra.
3. Haber cargado esos secretos en Bitwarden (`rbw`), con ese mismo
   nombre (`notion-token-<empresa>`).

`notion_adapter.py`/`slack_adapter.py` son la interfaz genérica: la
firma de sus funciones (`fetch_page_plaintext`, `fetch_recent_messages`)
es lo reusable — un segundo adaptador de wiki/chat implementaría la
misma firma sin tocar `work_docs.py`. Tests reales (sin pegarle a la
red) en `cli/docs/test_adapters.py`:

```bash
uv run work-os/cli/docs/test_adapters.py
```

## mcp/secrets/server.py

MCP server (Fase 6) que expone `work secret get` como tool `get_secret`.
La identidad del skill que llama (`WORK_OS_SKILL`) se fija en la config
de `.mcp.json` de ese skill, no la elige el modelo — ejemplo:

```json
{
  "mcpServers": {
    "work-secrets": {
      "command": "uv",
      "args": ["run", "/ruta/a/work-os/mcp/secrets/server.py"],
      "env": { "WORK_OS_SKILL": "nombre-del-skill" }
    }
  }
}
```

## scripts/audit-fedora.sh

Read-only, no modifica nada. Genera un reporte de la instalación actual de
Fedora para decidir qué migrar a `workos`.

```bash
bash scripts/audit-fedora.sh
```

El reporte se guarda en `~/Repos/Externos/workos/audit-report-<fecha>.md` (fuera de
cualquier repo git, para no commitearlo por error).
