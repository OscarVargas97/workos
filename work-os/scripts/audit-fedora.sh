#!/usr/bin/env bash
# Fase 0 — auditoría read-only de Fedora. No instala ni modifica nada.
set -euo pipefail

OUT="${1:-$HOME/Repos/Externos/workos/audit-report-$(date +%Y%m%d-%H%M).md}"

{
  echo "# Auditoría Fedora — $(date)"

  echo -e "\n## Hardware"
  echo '```'
  lscpu 2>/dev/null || true
  echo
  free -h
  echo
  lsblk -f 2>/dev/null || true
  echo
  df -h
  echo
  lspci -k 2>/dev/null || echo "lspci no disponible"
  echo '```'

  echo -e "\n## Paquetes instalados (rpm)"
  echo '```'
  rpm -qa --qf '%{NAME}\n' 2>/dev/null | sort
  echo '```'

  echo -e "\n## Flatpaks"
  echo '```'
  flatpak list --app 2>/dev/null || echo "flatpak no disponible"
  echo '```'

  echo -e "\n## Servicios habilitados (sistema)"
  echo '```'
  systemctl list-unit-files --state=enabled 2>/dev/null || true
  echo '```'

  echo -e "\n## Servicios habilitados (usuario)"
  echo '```'
  systemctl --user list-unit-files --state=enabled 2>/dev/null || true
  echo '```'

  echo -e "\n## Shell y aliases (revisar antes de compartir el reporte)"
  echo '```'
  echo "SHELL=$SHELL"
  alias 2>/dev/null || true
  echo '```'

  echo -e "\n## Variables de entorno (filtradas: sin token/key/secret/password/auth)"
  echo '```'
  env | grep -viE 'token|key|secret|password|auth' | sort
  echo '```'

  echo -e "\n## Herramientas CLI y versiones"
  echo '```'
  for t in git nvim vim python3 pip3 node npm docker podman psql redis-cli tmux rg fd direnv devenv nix; do
    if command -v "$t" >/dev/null 2>&1; then
      printf '%-12s %s\n' "$t" "$($t --version 2>&1 | head -1)"
    fi
  done
  echo '```'

  echo -e "\n## Repositorios git en \$HOME (hasta 4 niveles)"
  echo '```'
  find "$HOME" -maxdepth 4 -type d -name '.git' 2>/dev/null | sed 's/\/\.git$//' | sort
  echo '```'

  echo -e "\n## Contenedores"
  echo '```'
  if command -v podman >/dev/null 2>&1; then
    echo "-- podman ps -a"; podman ps -a
    echo "-- podman images"; podman images
  fi
  if command -v docker >/dev/null 2>&1; then
    echo "-- docker ps -a"; docker ps -a
    echo "-- docker images"; docker images
  fi
  echo '```'

  echo -e "\n## Uso de recursos (top 20 por memoria)"
  echo '```'
  ps aux --sort=-%mem | head -20
  echo '```'

} > "$OUT"

echo "Reporte generado en: $OUT"
