# company-context

Esquema y tooling del modelo estructurado y versionado del contexto de
una empresa. Acá solo vive lo agnóstico; los datos reales de cada
empresa (una instancia por empresa) viven en el repo privado, en
`companies/<empresa>/`, con la misma estructura de carpetas.

No es una copia de Notion: Notion sigue siendo la fuente de documentación
viva. Una instancia guarda la metadata, las relaciones entre entidades y
el mapping hacia las páginas reales (`mappings/`), nunca el contenido
completo.

Esquema y contrato completo en [`SCHEMA.md`](./SCHEMA.md).

```
Instancia (repo privado, companies/<empresa>/):
company/       org, equipos, glosario
projects/      1 archivo por proyecto
systems/       sistemas y relaciones
services/      servicios (sin secretos, sin endpoints sensibles)
conventions/
decisions/     ADRs
mappings/      concept_id <-> notion_page_id / slack channel_id
agents/        índices de contexto para agentes

Este repo:
ontology/      tipos de entidad/relación (SCHEMA.md, sección 3)
schemas/       JSON Schema de frontmatter/provenance
tooling/       validate.py, new-entity.py, semantic_search.py
```

Ningún archivo de una instancia debe contener secretos ni tokens. Cada
entidad lleva frontmatter YAML con `source`, `status` y `confidence` —
ver [`SCHEMA.md`](./SCHEMA.md), sección 5, y
[`schemas/frontmatter.schema.json`](./schemas/frontmatter.schema.json)
para la validación.

El tooling se corre apuntando a la instancia con `COMPANY_CONTEXT_ROOT`:

```bash
COMPANY_CONTEXT_ROOT=../workos-private/companies/<empresa> uv run company-context/tooling/validate.py
```
