"""Resolución de rutas del cache local de docs (Fase 11).

Un solo lugar para esto: work_docs.py (lectura) y sync_docs.py
(escritura) tienen que coincidir en dónde vive cada archivo.

~/.local/share/company-context-docs/<empresa>/<concept_id>.md - mismo
patrón que ~/.local/share/herdr-src/ (Fase de herdr): estado local de
máquina, no config de usuario ni nada que viva en git. `vault/` se
descartó a propósito: su propósito documentado es staging para migrar
a un pendrive (Fase 4), no un cache de uso continuo - mezclar los dos
props en la misma carpeta hubiera confundido de qué se trata cada cosa.
"""
from pathlib import Path


def cache_root() -> Path:
    return Path.home() / ".local" / "share" / "company-context-docs"


def cache_path(company: str, concept_id: str) -> Path:
    return cache_root() / company / f"{concept_id}.md"
