# tooling/

Scripts agnósticos (Fase 8/12) que aplican el esquema de [`../SCHEMA.md`](../SCHEMA.md).
Ninguno sabe nada de ninguna empresa: operan sobre la instancia en
`$COMPANY_CONTEXT_ROOT` (por defecto, el directorio actual) - ej.
`cd workos-private/companies/<empresa>` y correr los comandos de abajo
con la ruta a este `tooling/`.

## validate.py

Valida todas las entidades existentes: frontmatter contra
`schemas/frontmatter.schema.json`, `concept_id` == nombre de archivo,
`type` correcto para la carpeta, y que toda relación
(`depends_on`/`owned_by`/`part_of`/`documented_in`/`supersedes`) apunte
a un `concept_id` que existe de verdad.

```bash
uv run tooling/validate.py
```

## new-entity.py

Genera el archivo de una entidad nueva con frontmatter válido
(`status: draft`, `confidence: unverified` por defecto — se ajustan a
mano una vez revisada).

```bash
uv run tooling/new-entity.py --type project --concept-id project-x --name "Proyecto X"
```

## semantic_search.py (Fase 12)

Búsqueda semántica sobre todas las entidades, con embeddings **locales**
(sin API paga, sin límite de uso — ver el comentario del propio
archivo para el motivo). Primera corrida descarga ~1.2GB de
dependencias (torch CPU-only + el modelo de embeddings) una sola vez,
cacheado por `uv`/HuggingFace — corridas siguientes son instantáneas.

```bash
uv run tooling/semantic_search.py "cómo se comunican el backend y el worker"
uv run tooling/semantic_search.py --top 5 "algo"
```
