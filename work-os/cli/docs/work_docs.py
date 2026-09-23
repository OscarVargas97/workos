#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml", "httpx"]
# ///
"""work docs <concept_id> - Fase 9/11.

Busca `concept_id` en mappings/notion.yaml o mappings/slack.yaml de la
instancia de company-context del proyecto actual (resuelta por la
función de shell `work`, ver work-os/cli/work).

Prioridad (Fase 11, pedido explícito - "que la IA priorice lo
que ya está en el sistema primero"): si `sync_docs.py` ya sincronizó
ese concept_id a disco, lo muestra directo, sin red. Solo si no hay
nada sincronizado todavía cae al fetch en vivo (Fase 9 original) y
listo - nunca guarda lo que trae en vivo, eso es trabajo de
`work docs sync`, no de esta lectura puntual.
"""
import subprocess
import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import notion_adapter  # noqa: E402
import slack_adapter  # noqa: E402
from doc_cache import cache_path  # noqa: E402

SKILL = "work-docs"


def get_secret(name: str) -> str:
    result = subprocess.run(
        ["work-cli", "secret", "get", name, "--skill", SKILL],
        capture_output=True, text=True, timeout=15,
    )
    if result.returncode != 0:
        print(result.stderr.strip(), file=sys.stderr)
        sys.exit(1)
    return result.stdout.strip()


def load_mapping(context_path: Path, filename: str) -> dict:
    path = context_path / "mappings" / filename
    if not path.exists():
        return {}
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


def main() -> int:
    import os

    if len(sys.argv) != 2:
        print("Uso: work docs <concept_id>", file=sys.stderr)
        return 1
    concept_id = sys.argv[1]

    context_path_str = os.environ.get("WORK_OS_COMPANY_CONTEXT")
    company = os.environ.get("WORK_OS_COMPANY")
    if not context_path_str or not company:
        print("Falta WORK_OS_COMPANY_CONTEXT/WORK_OS_COMPANY (usá la función de shell `work docs`, no este script directo).", file=sys.stderr)
        return 1
    context_path = Path(context_path_str)

    cached = cache_path(company, concept_id)
    if cached.exists():
        print(cached.read_text(encoding="utf-8"))
        return 0

    notion_map = load_mapping(context_path, "notion.yaml")
    slack_map = load_mapping(context_path, "slack.yaml")

    try:
        if concept_id in notion_map:
            token = get_secret(f"notion-token-{company}")
            text = notion_adapter.fetch_page_plaintext(notion_map[concept_id], token)
            print(text)
            return 0

        if concept_id in slack_map:
            token = get_secret(f"slack-token-{company}")
            messages = slack_adapter.fetch_recent_messages(slack_map[concept_id], token)
            for m in messages:
                print(f"[{m['confidence']}] {m['user']}: {m['text']}")
            return 0
    except Exception as e:  # fetch en vivo contra una API real - fuera de nuestro control, no debe tirar traceback
        print(f"Error trayendo '{concept_id}': {e}", file=sys.stderr)
        return 1

    print(f"'{concept_id}' no está en mappings/notion.yaml ni mappings/slack.yaml de {context_path}.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
