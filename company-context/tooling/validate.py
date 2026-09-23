#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml", "jsonschema"]
# ///
"""Valida todas las entidades de company-context (Fase 8).

Agnóstico: no conoce ninguna empresa, solo el esquema de
SCHEMA.md/schemas/frontmatter.schema.json. Corre contra lo que haya en
company/, projects/, systems/, services/, conventions/, decisions/ -
sirve tanto para un repo vacío (Fase 7, ahora) como para uno poblado
(Fase 10).

Comprueba, por cada archivo .md (menos README.md):
  1. El frontmatter valida contra el JSON Schema.
  2. El nombre de archivo coincide con concept_id (sección 3.3).
  3. El "type" del frontmatter corresponde a la carpeta donde vive.
  4. Toda relación (depends_on/owned_by/part_of/documented_in/
     supersedes) apunta a un concept_id que existe de verdad - no un
     link roto.
"""
import os
import sys
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator

# Instancia a validar (companies/<empresa>/ del repo privado); el schema
# siempre sale de este repo.
ROOT = Path(os.environ.get("COMPANY_CONTEXT_ROOT", ".")).resolve()
SCHEMA_PATH = Path(__file__).resolve().parent.parent / "schemas" / "frontmatter.schema.json"
RELATION_FIELDS = ["depends_on", "owned_by", "part_of", "documented_in", "supersedes"]

# Carpeta -> tipos de entidad válidos ahí (SCHEMA.md, secciones 2 y 3.1).
FOLDER_TYPES = {
    "company": {"team", "person"},
    "projects": {"project"},
    "systems": {"system"},
    "services": {"service"},
    "conventions": {"convention"},
    "decisions": {"decision"},
}


def load_frontmatter(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---\n"):
        raise ValueError("no empieza con frontmatter '---'")
    end = text.find("\n---", 4)
    if end == -1:
        raise ValueError("frontmatter sin cierre '---'")
    return yaml.safe_load(text[4:end]) or {}


def find_entities():
    for folder in FOLDER_TYPES:
        d = ROOT / folder
        if not d.is_dir():
            continue
        for path in sorted(d.glob("*.md")):
            if path.name == "README.md":
                continue
            yield folder, path


def main() -> int:
    import json

    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    validator = Draft202012Validator(schema)

    errors: list[str] = []
    all_concept_ids: set[str] = set()
    entities: list[tuple[str, Path, dict]] = []

    for folder, path in find_entities():
        rel = path.relative_to(ROOT)
        try:
            fm = load_frontmatter(path)
        except ValueError as e:
            errors.append(f"{rel}: {e}")
            continue

        for err in validator.iter_errors(fm):
            errors.append(f"{rel}: {err.message} (en {'.'.join(str(p) for p in err.path) or '<raíz>'})")

        concept_id = fm.get("concept_id")
        if concept_id and concept_id != path.stem:
            errors.append(f"{rel}: concept_id '{concept_id}' no coincide con el nombre de archivo '{path.stem}.md'")

        fm_type = fm.get("type")
        if fm_type and fm_type not in FOLDER_TYPES[folder]:
            errors.append(f"{rel}: type '{fm_type}' no corresponde a la carpeta '{folder}/' (esperado: {sorted(FOLDER_TYPES[folder])})")

        if concept_id:
            all_concept_ids.add(concept_id)
        entities.append((folder, path, fm))

    # Segunda pasada: relaciones tienen que apuntar a algo que existe.
    for folder, path, fm in entities:
        rel = path.relative_to(ROOT)
        for field in RELATION_FIELDS:
            for target in fm.get(field, []) or []:
                if target not in all_concept_ids:
                    errors.append(f"{rel}: {field} referencia '{target}', que no existe")

    if errors:
        print(f"✗ {len(errors)} error(es) en {len(entities)} entidad(es):\n", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1

    print(f"✓ {len(entities)} entidad(es) validadas, sin errores.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
