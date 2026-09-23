#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# ///
"""Smoke test de los adaptadores (Fase 9) contra respuestas con la forma
real de las APIs de Notion/Slack (no pega a la red) - ver
DECISIONS.md #13 y la costumbre de esta sesión de probar de verdad, no
asumir. Correr: uv run work-os/cli/docs/test_adapters.py
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import notion_adapter  # noqa: E402
import slack_adapter  # noqa: E402

checks = 0
failures = 0


def check(label: str, got, expected):
    global checks, failures
    checks += 1
    if got != expected:
        failures += 1
        print(f"✗ {label}\n   esperado: {expected!r}\n   obtenido: {got!r}")
    else:
        print(f"✓ {label}")


# --- Notion: forma real de GET /v1/blocks/{id}/children ---
NOTION_RESPONSE = {
    "results": [
        {"type": "heading_1", "heading_1": {"rich_text": [{"plain_text": "Título"}]}},
        {"type": "paragraph", "paragraph": {"rich_text": [{"plain_text": "Un párrafo normal."}]}},
        {"type": "bulleted_list_item", "bulleted_list_item": {"rich_text": [{"plain_text": "Item 1"}]}},
        {"type": "to_do", "to_do": {"rich_text": [{"plain_text": "Tarea"}], "checked": True}},
        {"type": "paragraph", "paragraph": {"rich_text": []}},  # bloque vacío, debe ignorarse
        {"type": "image", "image": {"type": "external", "external": {"url": "https://x"}}},  # sin rich_text, debe ignorarse
    ]
}


def fake_notion_get(url, headers):
    check("notion: header de auth presente", "Bearer tok-123" in headers.get("Authorization", ""), True)
    check("notion: header de version presente", headers.get("Notion-Version"), notion_adapter.NOTION_VERSION)
    return NOTION_RESPONSE


text = notion_adapter.fetch_page_plaintext("page-abc", "tok-123", http_get=fake_notion_get)
check(
    "notion: bloques convertidos a texto en orden, vacíos/no-soportados omitidos",
    text,
    "# Título\nUn párrafo normal.\n- Item 1\n[x] Tarea",
)

# --- Slack: forma real de GET /api/conversations.history ---
SLACK_RESPONSE_OK = {
    "ok": True,
    "messages": [
        {"type": "message", "user": "U1", "text": "hola", "ts": "1.1"},
        {"type": "message", "user": "U2", "text": "che", "ts": "1.2"},
    ],
}
SLACK_RESPONSE_ERROR = {"ok": False, "error": "channel_not_found"}


def fake_slack_get_ok(url, headers, params):
    check("slack: header de auth presente", "Bearer tok-456" in headers.get("Authorization", ""), True)
    check("slack: parametro de canal correcto", params.get("channel"), "C123")
    return SLACK_RESPONSE_OK


messages = slack_adapter.fetch_recent_messages("C123", "tok-456", http_get=fake_slack_get_ok)
check(
    "slack: mensajes parseados con confidence unverified",
    messages,
    [
        {"user": "U1", "text": "hola", "ts": "1.1", "confidence": "unverified"},
        {"user": "U2", "text": "che", "ts": "1.2", "confidence": "unverified"},
    ],
)


def fake_slack_get_error(url, headers, params):
    return SLACK_RESPONSE_ERROR


try:
    slack_adapter.fetch_recent_messages("C_MALO", "tok", http_get=fake_slack_get_error)
    check("slack: error de API propaga excepción", False, True)
except RuntimeError as e:
    check("slack: error de API propaga excepción con el mensaje real", "channel_not_found" in str(e), True)

print(f"\n{checks - failures}/{checks} OK")
sys.exit(1 if failures else 0)
