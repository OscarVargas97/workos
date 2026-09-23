#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml", "httpx"]
# ///
"""work docs sync [empresa] - Fase 11.

Sincroniza TODO lo mapeado (mappings/notion.yaml + mappings/slack.yaml)
de una empresa - o de todas las registradas en companies.conf si no se
pasa ninguna - a disco (~/.local/share/company-context-docs/, ver
doc_cache.py). Mismas llamadas HTTP que ya hacía `work docs` en vivo
(Fase 9) - nada de IA en el medio, esto es la única fuente de tráfico
de red del mecanismo completo. `work docs <concept_id>` después lee
de acá primero, sin red, y solo cae al fetch en vivo si todavía no se
sincronizó nada para ese concept_id.

Pensado para correr disparado por un servicio de systemd --user al
iniciar sesión, o a mano cuando se quiera forzar un refresh.
"""
import os
import subprocess
import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import notion_adapter  # noqa: E402
import slack_adapter  # noqa: E402
from doc_cache import cache_path  # noqa: E402

SKILL = "work-docs"
COMPANIES_FILE = Path(
    os.environ.get("WORK_OS_COMPANIES_FILE", str(Path.home() / ".config" / "work-os" / "companies.conf"))
)


def get_secret(name: str) -> str | None:
    result = subprocess.run(
        ["work-cli", "secret", "get", name, "--skill", SKILL],
        capture_output=True, text=True, timeout=15,
    )
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def load_mapping(context_path: Path, filename: str) -> dict:
    path = context_path / "mappings" / filename
    if not path.exists():
        return {}
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


def load_companies() -> dict[str, Path]:
    """empresa -> ruta a su company-context, desde companies.conf (mismo formato que work-os/cli/work)."""
    companies = {}
    if not COMPANIES_FILE.exists():
        return companies
    for line in COMPANIES_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, path = line.split("=", 1)
        companies[name] = Path(path)
    return companies


def sync_company(company: str, context_path: Path) -> tuple[int, int]:
    ok = 0
    failed = 0
    notion_map = load_mapping(context_path, "notion.yaml")
    slack_map = load_mapping(context_path, "slack.yaml")

    notion_token = None
    if notion_map:
        notion_token = get_secret(f"notion-token-{company}")
        if notion_token is None:
            print(f"  [{company}] saltando Notion: sin permiso/token para notion-token-{company}", file=sys.stderr)

    for concept_id, page_id in notion_map.items():
        if notion_token is None:
            failed += 1
            continue
        try:
            text = notion_adapter.fetch_page_plaintext(page_id, notion_token)
            dest = cache_path(company, concept_id)
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(text, encoding="utf-8")
            print(f"  [{company}] {concept_id} <- Notion OK")
            ok += 1
        except Exception as e:
            print(f"  [{company}] {concept_id} <- Notion ERROR: {e}", file=sys.stderr)
            failed += 1

    slack_token = None
    if slack_map:
        slack_token = get_secret(f"slack-token-{company}")
        if slack_token is None:
            print(f"  [{company}] saltando Slack: sin permiso/token para slack-token-{company}", file=sys.stderr)

    for concept_id, channel_id in slack_map.items():
        if slack_token is None:
            failed += 1
            continue
        try:
            messages = slack_adapter.fetch_recent_messages(channel_id, slack_token)
            text = "\n".join(f"[{m['confidence']}] {m['user']}: {m['text']}" for m in messages)
            dest = cache_path(company, concept_id)
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(text, encoding="utf-8")
            print(f"  [{company}] {concept_id} <- Slack OK")
            ok += 1
        except Exception as e:
            print(f"  [{company}] {concept_id} <- Slack ERROR: {e}", file=sys.stderr)
            failed += 1

    return ok, failed


def main() -> int:
    only = sys.argv[1] if len(sys.argv) > 1 else None
    companies = load_companies()
    if only:
        if only not in companies:
            print(f"'{only}' no está en {COMPANIES_FILE}.", file=sys.stderr)
            return 1
        companies = {only: companies[only]}

    if not companies:
        print(f"No hay empresas registradas en {COMPANIES_FILE}.", file=sys.stderr)
        return 1

    total_ok = total_failed = 0
    for company, context_path in companies.items():
        if not context_path.is_dir():
            print(f"  [{company}] ruta no existe: {context_path}", file=sys.stderr)
            continue
        ok, failed = sync_company(company, context_path)
        total_ok += ok
        total_failed += failed

    print(f"Sync completo: {total_ok} OK, {total_failed} con error.")
    return 1 if total_failed and not total_ok else 0


if __name__ == "__main__":
    raise SystemExit(main())
