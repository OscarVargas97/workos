#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["sentence-transformers", "pyyaml", "torch"]
#
# [tool.uv.sources]
# torch = [{ index = "pytorch-cpu" }]
#
# [[tool.uv.index]]
# name = "pytorch-cpu"
# url = "https://download.pytorch.org/whl/cpu"
# explicit = true
# ///
"""Búsqueda semántica sobre company-context (Fase 12).

Embeddings LOCALES (sentence-transformers, modelo chico ~90MB,
descargado una sola vez y cacheado por HuggingFace/uv) - a propósito,
no una API paga: pedido explícito de evitar el consumo de
tokens/costo de una API externa para esto (mismo motivo por el que la
Fase 11, cache/sync, quedó diferida). Corre en CPU, sin límite de uso,
sin llamadas a internet después de la primera descarga del modelo.

torch fijado a la variante CPU-only (`[tool.uv.sources]`/
`[[tool.uv.index]]` arriba, apuntando al índice de PyTorch para CPU) -
sin esto, uv resuelve por defecto la build con CUDA completa
(~5.6GB de dependencias nvidia_*, probado y confirmado real en esta
misma máquina, que no tiene GPU) en vez de la de CPU (~1.2GB). Mismo
tipo de descuido que dejó el disco de la VM lleno en la Fase 3 - acá
se evitó a propósito, no fue casualidad.

Sin índice persistente a propósito: con la escala actual de
company-context (puñado de entidades) recalcular los embeddings en
cada búsqueda tarda bien menos de un segundo - evita el problema que
justamente preocupa en la Fase 11 (un índice/cache que se desincroniza
del contenido real). Si company-context crece mucho y esto se pone
lento, ese es el momento de agregar un índice cacheado, no antes
(mismo criterio YAGNI del resto del proyecto).

Uso:
  uv run tooling/semantic_search.py "cómo se comunican el backend y el worker"
  uv run tooling/semantic_search.py --top 5 "algo"
"""
import argparse
import os
import sys
from pathlib import Path

import yaml
from sentence_transformers import SentenceTransformer, util

# Instancia (companies/<empresa>/ del repo privado).
ROOT = Path(os.environ.get("COMPANY_CONTEXT_ROOT", ".")).resolve()
FOLDERS = ["company", "projects", "systems", "services", "conventions", "decisions"]
MODEL_NAME = "all-MiniLM-L6-v2"


def load_entities() -> list[dict]:
    entities = []
    for folder in FOLDERS:
        d = ROOT / folder
        if not d.is_dir():
            continue
        for path in sorted(d.glob("*.md")):
            if path.name == "README.md":
                continue
            text = path.read_text(encoding="utf-8")
            if not text.startswith("---\n"):
                continue
            end = text.find("\n---", 4)
            if end == -1:
                continue
            frontmatter = yaml.safe_load(text[4:end]) or {}
            body = text[end + 4:].strip()
            entities.append(
                {
                    "concept_id": frontmatter.get("concept_id", path.stem),
                    "name": frontmatter.get("name", path.stem),
                    "path": str(path.relative_to(ROOT)),
                    # El texto que se embebe: nombre + body, no el YAML
                    # crudo (fechas/tipos no aportan significado semántico).
                    "text": f"{frontmatter.get('name', '')}\n{body}",
                }
            )
    return entities


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("query")
    p.add_argument("--top", type=int, default=3)
    args = p.parse_args()

    entities = load_entities()
    if not entities:
        print("No hay entidades en company-context todavía (ver projects/, systems/, etc.).", file=sys.stderr)
        return 1

    model = SentenceTransformer(MODEL_NAME)
    corpus_embeddings = model.encode([e["text"] for e in entities], convert_to_tensor=True)
    query_embedding = model.encode(args.query, convert_to_tensor=True)

    scores = util.cos_sim(query_embedding, corpus_embeddings)[0]
    ranked = sorted(zip(entities, scores.tolist()), key=lambda x: x[1], reverse=True)

    for entity, score in ranked[: args.top]:
        print(f"{score:.3f}  {entity['concept_id']:20s} {entity['name']}  ({entity['path']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
