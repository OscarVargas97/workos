#!/usr/bin/env bash
# Barra de estado de Claude Code: el badge de ponytail (si está instalado)
# más la última skill cargada en la sesión. Claude Code le pasa por stdin un
# JSON con `transcript_path`; la skill sale de ahí y no de un hook, así
# funciona en cualquier repo sin configurar nada por proyecto.
set -euo pipefail

input=$(cat)
dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Badge de ponytail: su propio script, de la versión instalada más nueva
# (la ruta del cache cambia con cada actualización del plugin).
pony=$(compgen -G "$dir/plugins/cache/ponytail/ponytail/*/hooks/ponytail-statusline.sh" | sort -V | tail -n1 || true)
[ -n "$pony" ] && bash "$pony" || true

transcript=$(printf '%s' "$input" | sed -n 's/.*"transcript_path" *: *"\([^"]*\)".*/\1/p')
[ -f "$transcript" ] || exit 0

# Última skill: la cargó el modelo (tool Skill) o la persona (/plugin:skill;
# los comandos sin ":" son built-ins como /clear y no cuentan). grep solo
# preselecciona líneas; jq confirma la estructura, para no contar una skill
# que aparece citada dentro de un comando o de un archivo.
# ponytail: tac lee el transcript entero en cada refresco; con decenas de MB
# conviene cachear por tamaño de archivo.
skill=$(tac "$transcript" \
  | grep -E '"name":"Skill"|<command-name>/' \
  | head -n 50 \
  | jq -r '
      if .type == "assistant" then
        .message.content[]? | select(.type == "tool_use" and .name == "Skill") | .input.skill
      elif .type == "user" and (.message.content | type) == "string" then
        .message.content | capture("<command-name>/(?<s>[A-Za-z0-9_-]+:[A-Za-z0-9:_-]+)</command-name>")?.s
      else empty end' 2>/dev/null \
  | head -n1 || true)

case "$skill" in
  "" | ponytail*) exit 0 ;;
esac
printf ' \033[38;5;75m[%s]\033[0m' "${skill#*:}"
