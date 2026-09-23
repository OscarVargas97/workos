#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml"]
# ///
"""Genera el archivo de una entidad nueva con frontmatter válido (Fase 8).

Agnóstico - no sabe nada de ninguna empresa, solo aplica el esquema de
SCHEMA.md. `status: draft` y `confidence: unverified` por defecto: una
entidad recién creada a mano todavía no pasó por ninguna revisión -
cambiar esos campos a mano una vez confirmada (o vía `validate.py`
corrido después de revisarla).

Uso:
  uv run tooling/new-entity.py --type project --concept-id project-x --name "Proyecto X"
"""
import argparse
import datetime
import os
import sys
from pathlib import Path

import yaml

# Instancia (companies/<empresa>/ del repo privado).
ROOT = Path(os.environ.get("COMPANY_CONTEXT_ROOT", ".")).resolve()

TYPE_TO_FOLDER = {
    "team": "company",
    "person": "company",
    "project": "projects",
    "system": "systems",
    "service": "services",
    "convention": "conventions",
    "decision": "decisions",
}


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--type", required=True, choices=sorted(TYPE_TO_FOLDER))
    p.add_argument("--concept-id", required=True, help="formato <tipo>-<slug>, ej. project-x")
    p.add_argument("--name", required=True)
    p.add_argument("--source", default="manual", choices=["notion", "slack", "manual"])
    args = p.parse_args()

    if not args.concept_id.startswith(f"{args.type}-"):
        print(f"error: concept_id debe empezar con '{args.type}-' (SCHEMA.md, sección 3.3)", file=sys.stderr)
        return 1

    folder = ROOT / TYPE_TO_FOLDER[args.type]
    target = folder / f"{args.concept_id}.md"
    if target.exists():
        print(f"error: {target.relative_to(ROOT)} ya existe", file=sys.stderr)
        return 1

    frontmatter = {
        "concept_id": args.concept_id,
        "type": args.type,
        "name": args.name,
        "source": args.source,
        "status": "draft",
        "confidence": "unverified",
        "updated": datetime.date.today().isoformat(),
    }
    body = f"---\n{yaml.safe_dump(frontmatter, sort_keys=False, allow_unicode=True)}---\n\n# {args.name}\n\n(completar)\n"
    target.write_text(body, encoding="utf-8")
    print(f"Creado: {target.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
