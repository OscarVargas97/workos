"""Adaptador de Notion (Fase 9) - un caso concreto de "fuente tipo wiki".

No es el diseño en sí: la interfaz genérica es la firma de
`fetch_page_plaintext` (page_id, token) -> texto plano. Un segundo
adaptador de wiki (ej. Confluence) implementaría la misma firma, sin
tocar work_docs.py.

`http_get` es inyectable para poder testear sin pegarle a la API real
de Notion (ver work-os/cli/docs/test_adapters.py).
"""
from __future__ import annotations

from typing import Callable, Optional

NOTION_API = "https://api.notion.com/v1"
NOTION_VERSION = "2022-06-28"

HttpGet = Callable[[str, dict], dict]


def _default_http_get(url: str, headers: dict) -> dict:
    import httpx

    resp = httpx.get(url, headers=headers, timeout=15)
    resp.raise_for_status()
    return resp.json()


# ponytail: cubre los tipos de bloque más comunes (párrafo, headings,
# listas, to-do, quote) - un tipo no cubierto cae al fallback genérico
# en vez de fallar. Ampliar acá si Fase 10 se topa con uno que falte.
def _block_to_text(block: dict) -> Optional[str]:
    btype = block.get("type")
    data = block.get(btype, {})
    rich_text = data.get("rich_text")
    if rich_text is None:
        return None
    text = "".join(rt.get("plain_text", "") for rt in rich_text)
    if not text:
        return None
    prefix = {
        "heading_1": "# ",
        "heading_2": "## ",
        "heading_3": "### ",
        "bulleted_list_item": "- ",
        "numbered_list_item": "1. ",
        "to_do": ("[x] " if data.get("checked") else "[ ] "),
        "quote": "> ",
    }.get(btype, "")
    return f"{prefix}{text}"


def fetch_page_plaintext(page_id: str, token: str, http_get: HttpGet = _default_http_get) -> str:
    """Trae el contenido de una página de Notion como texto plano (nivel 1: fetch en vivo, sin cache/sync)."""
    headers = {"Authorization": f"Bearer {token}", "Notion-Version": NOTION_VERSION}
    data = http_get(f"{NOTION_API}/blocks/{page_id}/children?page_size=100", headers)
    lines = []
    for block in data.get("results", []):
        line = _block_to_text(block)
        if line is not None:
            lines.append(line)
    return "\n".join(lines)
