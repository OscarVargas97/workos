# Busca en la LAN qué máquina acepta esta clave SSH para $LOGIN_USER (puerto
# 22 abierto + login por clave en batch mode) - compartido entre
# post-install-setup.sh y migrate-pc.sh, mismo criterio exacto en los dos,
# para no mantenerlo duplicado. Requiere SSH_KEY y LOGIN_USER ya resueltos
# por quien lo source-ea.
find_installed_host() {
  local net i h
  for net in $(ip -4 -o addr show scope global | awk '{print $4}' | grep '/24$' | cut -d. -f1-3); do
    for i in $(seq 1 254); do
      ( timeout 1 bash -c "echo >/dev/tcp/$net.$i/22" 2>/dev/null && echo "$net.$i" ) &
    done
  done | sort -u | while read -r h; do
    ssh -n -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i "$SSH_KEY" "$LOGIN_USER@$h" \
      'echo ok' 2>/dev/null | grep -q '^ok$' && echo "$h"
  done
}
