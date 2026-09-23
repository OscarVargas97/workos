# Esquema de Company Context (Fase 7)

Contrato de organización, agnóstico a cualquier empresa — sin ningún
dato real. Cualquier instancia de company-context (una por empresa,
ver `docs/DECISIONS.md` #11) se construye con este mismo esquema y vive
en el repo privado de quien la usa, en `companies/<empresa>/`. Si algo
acá no calza con la realidad de una instancia, se ajusta ahí y se
actualiza este documento — no al revés.

## 1. Qué NO es este repo

No es una copia de Notion ni de Slack. Nunca contiene el contenido
completo de una página o conversación — solo metadata estructurada,
relaciones entre entidades, y el mapping hacia la fuente real
(`mappings/`). Si hace falta el contenido completo, se linkea a la
fuente, no se copia.

Tampoco contiene secretos, tokens, ni endpoints sensibles — eso vive en
Bitwarden (`work secret get`, allowlist) o `vault/` (Fase 4, local, sin
git). Ver la sección 4 para el contrato completo de "qué dato va a
dónde".

## 2. Estructura de carpetas

```
company/       org, equipos, glosario — quién es quién, cómo se llaman las cosas
projects/      1 archivo por proyecto
systems/       sistemas y relaciones entre ellos (qué depende de qué)
services/      servicios desplegados (sin secretos, sin endpoints sensibles)
conventions/   convenciones de código/organización propias de la empresa
decisions/     ADRs — decisiones ya tomadas, con vigencia
ontology/      tipos de entidad y de relación válidos (ver sección 3)
mappings/      concept_id <-> notion_page_id (y otros IDs externos)
agents/        índices de contexto pensados para que un agente los lea
schemas/       JSON Schema de frontmatter/provenance (ver sección 5)
```

Cada carpeta de contenido (`company/`, `projects/`, `systems/`,
`services/`, `conventions/`, `decisions/`) es Markdown con frontmatter
YAML (sección 5) — un archivo por entidad, nombrado por su `concept_id`
(sección 3.3).

## 3. Ontología (tipos de entidad y relación)

Base mínima, agnóstica — Fase 8/10 la extiende según haga falta, no al
revés (no se precompletan tipos "por si acaso").

### 3.1 Tipos de entidad

| Tipo         | Carpeta       | Qué es |
|---           |---            |---|
| `team`       | `company/`    | un equipo u organización interna |
| `person`     | `company/`    | una persona (rol, no datos personales sensibles) |
| `project`    | `projects/`   | un proyecto/producto |
| `system`     | `systems/`    | un sistema (ej. "backend de X") |
| `service`    | `services/`   | un servicio desplegado de un sistema |
| `convention` | `conventions/`| una convención vigente |
| `decision`   | `decisions/`  | un ADR — la única forma de que algo pase de "conversación" a "regla vigente" (ver `DECISIONS.md` #4) |

### 3.2 Tipos de relación

Van en el frontmatter de la entidad origen, nunca como archivo aparte
(evita un grafo paralelo desincronizado):

- `depends_on`: system/service → system/service
- `owned_by`: project/system/service → team/person
- `part_of`: service → system, system → project
- `documented_in`: cualquier entidad → mapping de Notion (sección 4)
- `supersedes`: decision → decision (una decisión reemplaza a otra)

### 3.3 `concept_id`

Identificador único y estable de cada entidad, formato
`<tipo>-<slug>` (ej. `project-x`, `system-x-backend`,
`decision-2026-migracion-nixos`). Es el nombre de archivo (sin
extensión) y lo que usa `mappings/` para apuntar a la fuente real. Se
elige una vez y no cambia — si el nombre visible de algo cambia,
`concept_id` queda igual, solo cambia el campo `name` del frontmatter.

## 4. Contrato: qué dato va a dónde

| Dato | Vive en | Por qué |
|---|---|---|
| Documentación viva, contenido narrativo | **Notion** | fuente de verdad para contenido — `company-context` solo la referencia (`mappings/`), nunca la copia |
| Conversaciones, decisiones informales | **Slack** | `confidence: unverified` siempre, tipo `conversación` — nunca se trata como regla vigente salvo que se promueva a una `decision` explícita en `decisions/` (`DECISIONS.md` #4) |
| Metadata estructurada, relaciones entre entidades, mapping hacia Notion/Slack | **`company-context/`** | este repo — versionado, sin secretos |
| `.env`/dumps `.sql`/credenciales locales de proyectos reales | **`vault/`** | local, sin git, per-máquina (Fase 4) |
| Secretos de sistema pre-sesión (WiFi, LUKS) | **sops-nix** | Bitwarden no sirve ahí, requiere desbloqueo manual (`DECISIONS.md` #2) |
| Tokens que usan agentes (Notion API, GitHub, Slack) | **Bitwarden vía `work secret get`** | allowlist default-deny por skill, la IA nunca desbloquea el vault (`DECISIONS.md` #2) |

## 5. Provenance (frontmatter YAML)

Todo archivo de contenido (secciones `company/`…`decisions/`) empieza
con este frontmatter — validado contra
`schemas/frontmatter.schema.json`:

```yaml
---
concept_id: project-x       # único, estable (sección 3.3)
type: project                  # uno de los tipos de la sección 3.1
name: "Proyecto X" # nombre visible, puede cambiar
source: notion                 # de dónde salió el dato: notion | slack | manual
status: active                 # active | deprecated | draft
confidence: verified           # verified | unverified (sección 5.1)
updated: 2026-09-22             # última vez que se tocó este archivo
---
```

`status` y `confidence` son campos **distintos a propósito**: `status`
es el ciclo de vida de la entidad en sí (¿sigue existiendo/vigente?),
`confidence` es qué tan confiable es el DATO (¿alguien lo verificó, o
es una inferencia/conversación sin confirmar?). Un proyecto puede estar
`active` con datos `unverified` (existe, pero lo que sabemos de él
viene de un canal de Slack sin confirmar todavía).

### 5.1 `confidence`

- `verified`: confirmado por una fuente autoritativa (Notion
  actualizado, o una `decision` explícita).
- `unverified`: default para cualquier dato que venga de Slack o de una
  inferencia — nunca se trata como regla vigente hasta que alguien lo
  promueva explícitamente (crear/actualizar una `decision` con
  `confidence: verified`).

## 6. `mappings/`

Un archivo por fuente externa (ej. `mappings/notion.yaml`), formato:

```yaml
project-x: <notion_page_id>
system-x-backend: <notion_page_id>
```

Solo IDs, nunca contenido. Sirve para que un agente (o una persona) que
tiene un `concept_id` pueda ir directo a la página real sin buscar.

## 7. `agents/`

Índices pensados para que un agente los lea de entrada, no para
personas — ej. `agents/projects-index.yaml` con un resumen de una línea
por proyecto y su `concept_id`, para no tener que leer todo
`projects/*.md` en cada sesión. Se generan/actualizan con tooling
(Fase 8), no a mano.
