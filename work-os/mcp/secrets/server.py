#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp"]
# ///
"""MCP server para `work secret get` (Fase 6, DECISIONS.md #2).

Un solo tool: pide un secreto por nombre. La identidad del skill que
llama (WORK_OS_SKILL) la fija quien configuró este servidor en
.mcp.json - nunca la elige el modelo, así no puede autodeclararse otro
skill para saltarse la allowlist de secrets-policy.yaml. Este server no
desbloquea Bitwarden solo: asume que una persona ya corrió `rbw unlock` -
si no, `rbw get` falla y ese error se devuelve tal cual.
"""
import os
import subprocess

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("work-os-secrets")


@mcp.tool()
def get_secret(name: str) -> str:
    """Pide un secreto por nombre a Bitwarden (rbw), sujeto a la allowlist del skill."""
    skill = os.environ.get("WORK_OS_SKILL")
    if not skill:
        return "Error: WORK_OS_SKILL no está configurado para este servidor MCP (falta en .mcp.json)."
    result = subprocess.run(
        ["work-cli", "secret", "get", name, "--skill", skill],
        capture_output=True,
        text=True,
        timeout=15,
    )
    if result.returncode != 0:
        return f"Error: {result.stderr.strip()}"
    return result.stdout.strip()


if __name__ == "__main__":
    mcp.run()
