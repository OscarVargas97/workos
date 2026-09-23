#!/usr/bin/env bash
# Crea los códigos TOTP de esta máquina (workos.security.totp) y muestra un
# QR por cada uno para escanearlo con la app del teléfono (Aegis, Google
# Authenticator, etc. - NO en Bitwarden: el segundo factor tiene que estar
# fuera de la bóveda). Se instala como `workos-totp-setup`.
#
#   "<usuario>@<host> desbloqueo": bloqueo de pantalla, login de consola y
#                                   pantalla de inicio (~/.google_authenticator)
#   "<usuario>@<host> sudo":       sudo y SSH desde fuera de las redes de
#                                   confianza (/var/lib/workos/totp/<usuario>, de root)
#
# Cada uno imprime 5 códigos de emergencia de un solo uso: imprimilos y
# guardalos fuera del teléfono y de la laptop - son la salida si perdés el
# teléfono.
#
# Uso: workos-totp-setup [--force]   (--force regenera los que ya existen)
set -euo pipefail

FORCE=false
[ "${1:-}" = "--force" ] && FORCE=true
HOST=$(hostname)
# -t basado en tiempo, -d sin reusar un código, -r/-R máximo 3 intentos cada
# 30 s (frena la fuerza bruta), -w 3 tolera ±30 s de desfase de reloj.
OPTS=(-t -d -f -r 3 -R 30 -w 3 -Q UTF8 -i workos)

create() { # create "etiqueta" archivo [sudo]
  local label=$1 file=$2 as_root=${3:-}
  local exists
  if [ -n "$as_root" ]; then exists=$(sudo test -e "$file" && echo y || true)
  else exists=$([ -e "$file" ] && echo y || true); fi
  if [ -n "$exists" ] && ! $FORCE; then
    echo "  \"$label\" ya existe - no lo toco (--force para regenerarlo)."
    return
  fi
  echo
  echo "=== $label ==="
  echo "Escaneá este QR con la app del teléfono y anotá los códigos de emergencia."
  if [ -n "$as_root" ]; then
    sudo google-authenticator "${OPTS[@]}" -l "$label" -s "$file"
    sudo chmod 400 "$file"
  else
    google-authenticator "${OPTS[@]}" -l "$label" -s "$file"
    chmod 400 "$file"
  fi
  read -rp "Enter cuando lo hayas escaneado y guardado los códigos de emergencia..." _
}

echo "== Códigos TOTP de $USER@$HOST"
create "$USER@$HOST desbloqueo" "$HOME/.google_authenticator"
# El sudo de acá todavía no pide código: el secreto de root no existe (nullok).
create "$USER@$HOST sudo" "/var/lib/workos/totp/$USER" root

echo
echo "Listo. Probalo antes de cerrar esta sesión (si algo falla, seguís adentro):"
echo "  sudo -k; sudo true      -> pide contraseña y código \"sudo\""
echo "  Super+L                 -> bloquea; para desbloquear: contraseña y código \"desbloqueo\" JUNTOS, sin espacio (ej. miclave123456)"
echo
echo "Si los dos funcionan: activá workos.security.totp.enforce = true en tu repo"
echo "privado y rebuild. Sin eso, borrar ~/.google_authenticator desactivaría el"
echo "código del bloqueo en silencio."
