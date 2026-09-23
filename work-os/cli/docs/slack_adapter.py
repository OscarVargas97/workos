"""Adaptador de Slack (Fase 9) - un caso concreto de "fuente de chat".

Misma idea que notion_adapter.py: la interfaz genérica es la firma de
`fetch_recent_messages` (channel_id, token, limit) -> lista de
mensajes. Nivel 1 (fetch en vivo, sin sync/cache - eso es Fase 11).

Cada mensaje se devuelve marcado `confidence: unverified` (DECISIONS.md
#4 de docs/DECISIONS.md, SCHEMA.md sección 4 de company-context): una
conversación de Slack nunca es una regla vigente por sí sola.
"""
from __future__ import annotations

from typing import Callable

SLACK_API = "https://slack.com/api"

HttpGet = Callable[[str, dict, dict], dict]


def _default_http_get(url: str, headers: dict, params: dict) -> dict:
    import httpx

    resp = httpx.get(url, headers=headers, params=params, timeout=15)
    resp.raise_for_status()
    return resp.json()


def fetch_recent_messages(channel_id: str, token: str, limit: int = 20, http_get: HttpGet = _default_http_get) -> list[dict]:
    """Trae los últimos `limit` mensajes de un canal, en vivo (nivel 1, sin sync)."""
    headers = {"Authorization": f"Bearer {token}"}
    data = http_get(f"{SLACK_API}/conversations.history", headers, {"channel": channel_id, "limit": limit})
    if not data.get("ok"):
        raise RuntimeError(f"Slack API error: {data.get('error', 'desconocido')}")
    return [
        {
            "user": m.get("user", "?"),
            "text": m.get("text", ""),
            "ts": m.get("ts", ""),
            "confidence": "unverified",
        }
        for m in data.get("messages", [])
    ]
