#!/usr/bin/env bash
# Motor genérico de "work infra" por empresa: túneles SSM puntuales,
# shell/comandos en pods, migraciones y dumps. No conoce cuentas, tags
# ni servicios reales — todo entra por variables CLOUDOPS_* (las pone
# el paquete Nix que envuelve este script por cada entorno declarado en
# workos.cloudOps.environments, ver modules/workos.nix). Un binario por
# entorno (ej. "acme-dev"), para que el entorno nunca sea un flag
# que se puede olvidar - es la primera palabra del comando.
#
# Namespace y deployment de un servicio nunca se guardan acá: se
# resuelven en vivo contra el cluster (kubectl get deployments -A), así
# que un servicio nuevo aparece solo. Lo único que no se puede
# descubrir en vivo -el comando de migración de cada servicio y a qué
# base de datos corresponde- vive en CLOUDOPS_MIGRATE_CONFIG (tsv:
# deployment<TAB>db_name<TAB>check_cmd<TAB>apply_cmd, "-" = no aplica).
set -euo pipefail

NAME="${CLOUDOPS_NAME:?falta CLOUDOPS_NAME}"
ENV_LABEL="${CLOUDOPS_ENV_LABEL:?falta CLOUDOPS_ENV_LABEL}"
AWS_PROFILE="${CLOUDOPS_AWS_PROFILE:?falta CLOUDOPS_AWS_PROFILE}"
AWS_ACCOUNT_ID="${CLOUDOPS_AWS_ACCOUNT_ID:?falta CLOUDOPS_AWS_ACCOUNT_ID}"
REGION="${CLOUDOPS_REGION:-us-east-1}"
K3S_TAG="${CLOUDOPS_K3S_TAG:-}"
BASTION_TAG="${CLOUDOPS_BASTION_TAG:-}"
RDS_IDENTIFIER="${CLOUDOPS_RDS_IDENTIFIER:-}"
DB_SECRET_PREFIX="${CLOUDOPS_DB_SECRET_PREFIX:-}"
TERRAFORM_REPO="${CLOUDOPS_TERRAFORM_REPO:-}"
TERRAFORM_DIR="${CLOUDOPS_TERRAFORM_DIR:-}"
REQUIRE_CONFIRM="${CLOUDOPS_REQUIRE_CONFIRM:-false}"
MIGRATE_CONFIG="${CLOUDOPS_MIGRATE_CONFIG:-}"
SEED_CONFIG="${CLOUDOPS_SEED_CONFIG:-}"

BASE="${WORKOS_BASE:-$HOME/Repos/Externos/workos}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/workos-cloud-ops/$NAME"
KUBECONFIG_CACHE="$CACHE_DIR/kubeconfig.yaml"
mkdir -p "$CACHE_DIR"

aws_() { aws --profile "$AWS_PROFILE" --region "$REGION" "$@"; }

# Se pide para cualquier acción que toque algo real (no para login/tf-graph,
# que son de solo lectura) - el entorno va tipeado a mano, no un "s/n".
confirm_real_action() {
  [ "$REQUIRE_CONFIRM" = true ] || return 0
  echo "Vas a ejecutar esto contra $NAME (cuenta AWS $AWS_ACCOUNT_ID)." >&2
  read -rp "Escribí '$ENV_LABEL' para confirmar: " a
  [ "$a" = "$ENV_LABEL" ] || { echo "Cancelado." >&2; exit 1; }
}

find_instance() {
  aws_ ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text \
    | tr '\t\n' '  ' | awk '{print $1}'
}

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3<&- 3>&-; return 0; }; return 1; }

wait_port() {
  local port=$1 tries=30
  while ! port_open "$port"; do
    tries=$((tries - 1))
    [ "$tries" -gt 0 ] || { echo "El túnel no levantó el puerto $port a tiempo." >&2; return 1; }
    sleep 1
  done
}

# Túneles compartidos entre invocaciones concurrentes: dos "acme-dev k"
# en paralelo tienen que usar el MISMO port-forward sin pisarse al abrir ni
# cortarle el piso al otro al cerrar. Contador de uso por puerto en
# $TUNNELS_DIR/<puerto>.count, protegido por flock ($TUNNELS_DIR/<puerto>.lock)
# - no importa quién lo abrió, se mata el proceso SSM cuando el contador llega
# a 0 (el último en salir apaga la luz), nunca antes.
TUNNELS_DIR="$CACHE_DIR/tunnels"
mkdir -p "$TUNNELS_DIR"
LOCK_FD=

tunnel_lock() { exec {LOCK_FD}<>"$TUNNELS_DIR/$1.lock"; flock "$LOCK_FD"; }
tunnel_unlock() { flock -u "$LOCK_FD"; exec {LOCK_FD}<&-; LOCK_FD=; }

# tunnel_acquire <puerto> <args de "aws ssm start-session"...>
tunnel_acquire() {
  local port=$1; shift
  local count_f="$TUNNELS_DIR/$port.count" pid_f="$TUNNELS_DIR/$port.pid"
  tunnel_lock "$port"
  local count=0; [ -f "$count_f" ] && count=$(<"$count_f")
  # Contador > 0 pero no hay nada real detrás: el PID murió (kill -9 de otra
  # corrida) o el .pid directamente no está (la corrida que lo sostenía se
  # cayó a mitad de tunnel_release - terminal cerrada de golpe, SSH cortado,
  # laptop que suspendió - entre borrar el .pid y reescribir el .count). Las
  # dos formas dejan el mismo contador huérfano, así que las dos se
  # autocorrigen igual en vez de quedar leakeado para siempre.
  if [ "$count" -gt 0 ] && { [ ! -f "$pid_f" ] || ! kill -0 "$(<"$pid_f")" 2>/dev/null; }; then count=0; fi
  if [ "$count" -eq 0 ] && ! port_open "$port"; then
    local logf; logf=$(mktemp)
    aws_ ssm start-session "$@" >"$logf" 2>&1 &
    echo "$!" > "$pid_f"
    if ! wait_port "$port"; then
      cat "$logf" >&2; rm -f "$logf" "$pid_f"
      echo 0 > "$count_f"; tunnel_unlock; return 1
    fi
    rm -f "$logf"
  fi
  echo "$((count + 1))" > "$count_f"
  tunnel_unlock
}

tunnel_release() {
  local port=$1
  tunnel_lock "$port"
  local count_f="$TUNNELS_DIR/$port.count" pid_f="$TUNNELS_DIR/$port.pid"
  local count=0; [ -f "$count_f" ] && count=$(<"$count_f")
  count=$((count - 1))
  if [ "$count" -le 0 ]; then
    count=0
    # Sin pid_f = el túnel de este puerto no lo abrimos nosotros (uno externo
    # que ya estaba ahí): se deja como estaba, no se mata nada ajeno.
    if [ -f "$pid_f" ]; then
      local pid; pid=$(<"$pid_f")
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$pid_f"
    fi
  fi
  echo "$count" > "$count_f"
  tunnel_unlock
}

# with_tunnel <puerto-local> <args de "aws ssm start-session"...> -- <comando...>
with_tunnel() {
  local port=$1; shift
  local ssm_args=()
  while [ "$1" != -- ]; do ssm_args+=("$1"); shift; done
  shift
  tunnel_acquire "$port" "${ssm_args[@]}" || return 1
  trap 'tunnel_release "'"$port"'"' RETURN INT TERM
  "$@"
}

fetch_kubeconfig() {
  local id=$1 cmdid
  cmdid=$(aws_ ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
    --parameters 'commands=["sudo cat /etc/rancher/k3s/k3s.yaml"]' \
    --query Command.CommandId --output text)
  aws_ ssm wait command-executed --command-id "$cmdid" --instance-id "$id" 2>/dev/null || true
  aws_ ssm get-command-invocation --command-id "$cmdid" --instance-id "$id" \
    --query StandardOutputContent --output text > "$KUBECONFIG_CACHE"
  chmod 600 "$KUBECONFIG_CACHE"
}

# run_k8s <comando...>: túnel puntual a 6443 + KUBECONFIG resuelto. Si falla
# (ej. el nodo se reemplazó y cambió la CA), refresca el kubeconfig una vez
# y reintenta - perderlo no cuesta nada, es una caché.
run_k8s() {
  [ -n "$K3S_TAG" ] || { echo "No hay nodo k3s configurado para $NAME." >&2; exit 1; }
  local id; id=$(find_instance "$K3S_TAG")
  [ -n "$id" ] || { echo "No encuentro el nodo k3s ($K3S_TAG) corriendo en $NAME." >&2; exit 1; }
  [ -f "$KUBECONFIG_CACHE" ] || fetch_kubeconfig "$id"
  if ! with_tunnel 6443 --target "$id" --document-name AWS-StartPortForwardingSession \
      --parameters portNumber=6443,localPortNumber=6443 -- \
      env KUBECONFIG="$KUBECONFIG_CACHE" "$@"; then
    echo "Falló - probando con un kubeconfig nuevo..." >&2
    fetch_kubeconfig "$id"
    with_tunnel 6443 --target "$id" --document-name AWS-StartPortForwardingSession \
      --parameters portNumber=6443,localPortNumber=6443 -- \
      env KUBECONFIG="$KUBECONFIG_CACHE" "$@"
  fi
}

# imprime "namespace deployment" o nada si no existe. Sin redirigir stderr acá
# -si algo falla (nodo no encontrado, túnel, kubectl) tiene que verse, no
# desaparecer junto con el "no lo encontré" que sigue.
find_deployment() {
  run_k8s kubectl get deployments -A -o json \
    | jq -r --arg n "$1" '.items[] | select(.metadata.name==$n) | "\(.metadata.namespace) \(.metadata.name)"'
}

list_deployments() {
  run_k8s kubectl get deployments -A --no-headers | awk '{print "  "$1"/"$2}'
}

# imprime "db_name<TAB>check_cmd<TAB>apply_cmd" de CLOUDOPS_MIGRATE_CONFIG.
migrate_row() {
  [ -n "$MIGRATE_CONFIG" ] && [ -f "$MIGRATE_CONFIG" ] \
    || { echo "No hay tabla de migraciones configurada (CLOUDOPS_MIGRATE_CONFIG)." >&2; exit 1; }
  awk -F'\t' -v d="$1" '/^#/ || /^[ \t]*$/ {next} $1==d {print $2"\t"$3"\t"$4; found=1} END{exit !found}' "$MIGRATE_CONFIG"
}

# imprime "deployment<TAB>clean_cmd<TAB>load_cmd<TAB>export_cmd" de
# CLOUDOPS_SEED_CONFIG para un rol ("primary" o "secondary"). Ver
# action_seed_run para qué significa cada uno.
seed_row() {
  [ -n "$SEED_CONFIG" ] && [ -f "$SEED_CONFIG" ] \
    || { echo "No hay tabla de seed configurada (CLOUDOPS_SEED_CONFIG)." >&2; exit 1; }
  awk -F'\t' -v r="$1" '/^#/ || /^[ \t]*$/ {next} $1==r {print $2"\t"$3"\t"$4"\t"$5; found=1} END{exit !found}' "$SEED_CONFIG"
}

action_login() { exec aws login --profile "$AWS_PROFILE" "$@"; }

action_exec() {
  local svc=${1:?"Uso: $NAME exec <deployment> [-- comando]"}; shift
  confirm_real_action
  local rows; rows=$(find_deployment "$svc")
  if [ -z "$rows" ]; then
    echo "No encontré el deployment '$svc' en $NAME. Deployments disponibles:" >&2
    list_deployments >&2
    exit 1
  fi
  local ns dep; read -r ns dep <<<"$rows"
  echo ">> $NAME: exec en $dep (namespace $ns, cuenta $AWS_ACCOUNT_ID)" >&2
  [ "${1:-}" = -- ] && shift
  if [ $# -gt 0 ]; then
    run_k8s kubectl exec "deploy/$dep" -n "$ns" -- "$@"
  else
    run_k8s kubectl exec -it "deploy/$dep" -n "$ns" -- sh
  fi
}

action_cp() {
  local svc=${1:?"Uso: $NAME cp <deployment> <local> [remoto]"}
  local local_path=${2:?"Uso: $NAME cp <deployment> <local> [remoto]"}
  local remote_path=${3:-/tmp/$(basename "$local_path")}
  confirm_real_action
  local rows; rows=$(find_deployment "$svc")
  if [ -z "$rows" ]; then
    echo "No encontré el deployment '$svc' en $NAME. Deployments disponibles:" >&2
    list_deployments >&2
    exit 1
  fi
  local ns dep; read -r ns dep <<<"$rows"
  # kubectl cp pide un pod, no un deployment - se asume el patrón estándar
  # de nombre de pod "<deployment>-<hash>" (ReplicaSet+pod), el mismo que
  # usa Kubernetes por defecto.
  local pod; pod=$(run_k8s kubectl get pods -n "$ns" --no-headers \
    | awk -v d="$dep-" 'index($1,d)==1{print $1; exit}')
  [ -n "$pod" ] || { echo "No encontré un pod corriendo para '$dep' en namespace $ns." >&2; exit 1; }
  echo ">> $NAME: copiando $local_path -> $dep/$pod:$remote_path (namespace $ns)" >&2
  run_k8s kubectl cp "$local_path" "$ns/$pod:$remote_path"
  echo "OK: $remote_path en $pod"
}

action_migrate() {
  local svc=${1:?"Uso: $NAME migrate <deployment> [--apply]"}
  local apply=false; [ "${2:-}" = --apply ] && apply=true
  local row; row=$(migrate_row "$svc") \
    || { echo "No hay entrada de migración para '$svc' en $MIGRATE_CONFIG." >&2; exit 1; }
  local db_name check_cmd apply_cmd
  IFS=$'\t' read -r db_name check_cmd apply_cmd <<<"$row"
  [ "$check_cmd" != "-" ] || { echo "$svc no tiene migraciones (según $MIGRATE_CONFIG)." >&2; exit 1; }
  local rows; rows=$(find_deployment "$svc")
  [ -n "$rows" ] || { echo "No encontré el deployment '$svc' en $NAME." >&2; exit 1; }
  local ns dep; read -r ns dep <<<"$rows"
  if [ "$apply" = true ]; then
    confirm_real_action
    echo ">> $NAME: APLICANDO migración en $dep (namespace $ns, cuenta $AWS_ACCOUNT_ID)" >&2
    run_k8s kubectl exec "deploy/$dep" -n "$ns" -- sh -c "$apply_cmd"
  else
    echo ">> $NAME: --check (dry-run) en $dep (namespace $ns). Para aplicar: $NAME migrate $svc --apply" >&2
    run_k8s kubectl exec "deploy/$dep" -n "$ns" -- sh -c "$check_cmd"
  fi
}

# seed-run <csv-local> --label <label>: limpia y recarga datos fake en dos
# sistemas que dependen entre sí a partir del mismo CSV de una corrida -
# pensado para LMS+KMS en dev (CLOUDOPS_SEED_CONFIG define el "primary", que
# además exporta un manifiesto de lo que el "secondary" necesita, y el
# "secondary", que lo consume) pero este script no sabe nada de ninguno de
# los dos: todo el conocimiento de qué comando corre cada lado vive en la
# tabla. Las plantillas de comando pueden usar {csv}/{label}/{manifest},
# que se sustituyen acá por las rutas reales dentro de cada pod.
action_seed_run() {
  local csv_local=${1:?"Uso: $NAME seed-run <csv> --label <label>"}; shift
  [ "${1:-}" = --label ] || { echo "Uso: $NAME seed-run <csv> --label <label>" >&2; exit 1; }
  local label=${2:?"Uso: $NAME seed-run <csv> --label <label>"}
  [ -f "$csv_local" ] || { echo "No existe el CSV: $csv_local" >&2; exit 1; }
  confirm_real_action

  local prim sec
  prim=$(seed_row primary) || { echo "Sin fila 'primary' en $SEED_CONFIG." >&2; exit 1; }
  sec=$(seed_row secondary) || { echo "Sin fila 'secondary' en $SEED_CONFIG." >&2; exit 1; }
  local p_dep p_clean p_load p_export s_dep s_clean s_load _s_export
  IFS=$'\t' read -r p_dep p_clean p_load p_export <<<"$prim"
  IFS=$'\t' read -r s_dep s_clean s_load _s_export <<<"$sec"

  local remote_csv="/tmp/seed-$label.csv"
  local remote_manifest="/tmp/seed-$label-manifest.csv"
  local local_manifest; local_manifest=$(mktemp)
  # EXIT y no RETURN: un error más abajo sale con "exit 1" (no "return"), que
  # un trap RETURN no vería -- EXIT cubre los dos casos.
  trap 'rm -f "$local_manifest"' EXIT

  subst() {
    local s=$1
    s=${s//\{csv\}/$remote_csv}
    s=${s//\{label\}/$label}
    s=${s//\{manifest\}/$remote_manifest}
    echo "$s"
  }

  echo ">> $NAME: limpiando $p_dep y $s_dep..." >&2
  action_exec "$p_dep" -- sh -c "$p_clean"
  action_exec "$s_dep" -- sh -c "$s_clean"

  echo ">> $NAME: cargando $csv_local en $p_dep (label $label)..." >&2
  action_cp "$p_dep" "$csv_local" "$remote_csv"
  action_exec "$p_dep" -- sh -c "$(subst "$p_load")"

  echo ">> $NAME: exportando manifiesto de kits desde $p_dep..." >&2
  action_exec "$p_dep" -- sh -c "$(subst "$p_export")"

  # kubectl cp no entiende deployments, solo pods - mismo truco de nombre
  # estándar "<deployment>-<hash>" que ya usa action_cp.
  local p_rows p_ns p_pod_dep p_pod
  p_rows=$(find_deployment "$p_dep")
  read -r p_ns p_pod_dep <<<"$p_rows"
  p_pod=$(run_k8s kubectl get pods -n "$p_ns" --no-headers \
    | awk -v d="$p_pod_dep-" 'index($1,d)==1{print $1; exit}')
  [ -n "$p_pod" ] || { echo "No encontré un pod corriendo para '$p_dep'." >&2; exit 1; }
  run_k8s kubectl cp "$p_ns/$p_pod:$remote_manifest" "$local_manifest"

  echo ">> $NAME: cargando el manifiesto en $s_dep..." >&2
  action_cp "$s_dep" "$local_manifest" "$remote_manifest"
  action_exec "$s_dep" -- sh -c "$(subst "$s_load")"

  echo ">> $NAME: limpiando archivos temporales en los pods..." >&2
  action_exec "$p_dep" -- rm -f "$remote_csv" "$remote_manifest"
  action_exec "$s_dep" -- rm -f "$remote_manifest"

  echo "OK: datos fake de '$label' cargados en $p_dep y $s_dep." >&2
}

# Namespace de ArgoCD: convención estándar en todos los entornos que lo
# usan, no depende de la empresa - por eso no es una opción de Nix, solo
# un override para el caso raro de que alguna instalación lo mueva.
argocd_ns() { echo "${CLOUDOPS_ARGOCD_NS:-argocd}"; }

action_argocd() {
  run_k8s kubectl get applications -n "$(argocd_ns)" "$@"
}

# Headlamp es la app de escritorio (nix run, herramienta de un solo uso -
# no se instala), no un servicio del cluster: lee el kubeconfig como
# cualquier cliente k8s (KUBECONFIG/client-go estándar), así que alcanza
# con correrla adentro de run_k8s para que tenga el túnel + kubeconfig
# cacheado sin duplicar esa lógica.
action_headlamp() {
  echo ">> $NAME: abriendo Headlamp (cerrá la ventana para cortar el túnel)" >&2
  run_k8s nix run nixpkgs#headlamp
}

action_argocd_ui() {
  local port=${CLOUDOPS_ARGOCD_UI_PORT:-8080}
  local ns; ns=$(argocd_ns)
  port_open "$port" && { echo "Ya hay algo escuchando en :$port - elegí otro con CLOUDOPS_ARGOCD_UI_PORT." >&2; exit 1; }
  echo ">> $NAME: ArgoCD UI -> https://localhost:$port (Ctrl+C corta el túnel)" >&2
  run_k8s kubectl -n "$ns" port-forward svc/argocd-server "$port:443" &
  local pf=$!
  trap 'kill "$pf" 2>/dev/null; wait "$pf" 2>/dev/null' EXIT INT TERM
  wait_port "$port" || exit 1
  xdg-open "https://localhost:$port" >/dev/null 2>&1 &
  wait "$pf"
}

action_dump() {
  local svc=${1:?"Uso: $NAME dump <deployment>"}
  confirm_real_action
  [ -n "$BASTION_TAG" ] && [ -n "$RDS_IDENTIFIER" ] && [ -n "$DB_SECRET_PREFIX" ] \
    || { echo "Acceso a base de datos no configurado todavía para $NAME." >&2; exit 1; }
  local row; row=$(migrate_row "$svc") \
    || { echo "No hay entrada para '$svc' en $MIGRATE_CONFIG." >&2; exit 1; }
  local db_name _c _a; IFS=$'\t' read -r db_name _c _a <<<"$row"
  [ "$db_name" != "-" ] || { echo "$svc no tiene base de datos (según $MIGRATE_CONFIG)." >&2; exit 1; }

  local vault="$BASE/vault"
  mountpoint -q "$vault" 2>/dev/null \
    || { echo "El vault no está abierto: work vault open (y close al terminar)." >&2; exit 1; }

  local secret_id="$DB_SECRET_PREFIX/db/$db_name"
  local rds_host
  rds_host=$(aws_ rds describe-db-instances --db-instance-identifier "$RDS_IDENTIFIER" \
    --query 'DBInstances[0].Endpoint.Address' --output text)
  [ -n "$rds_host" ] && [ "$rds_host" != None ] \
    || { echo "No encontré la instancia RDS '$RDS_IDENTIFIER'." >&2; exit 1; }

  local bastion; bastion=$(find_instance "$BASTION_TAG")
  [ -n "$bastion" ] || { echo "No encontré el bastion '$BASTION_TAG' corriendo en $NAME." >&2; exit 1; }

  local creds user pass
  creds=$(aws_ secretsmanager get-secret-value --secret-id "$secret_id" --query SecretString --output text)
  user=$(jq -r '.username // .user' <<<"$creds")
  pass=$(jq -r '.password' <<<"$creds")

  local out_dir="$vault/dumps/$NAME/$svc"
  mkdir -p "$out_dir"
  local out="$out_dir/$ENV_LABEL-$(date +%Y%m%d-%H%M%S).sql"

  echo ">> $NAME: dump de $db_name ($svc) -> $out" >&2
  with_tunnel 5432 --target "$bastion" --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "host=$rds_host,portNumber=5432,localPortNumber=5432" -- \
    env PGPASSWORD="$pass" pg_dump -h 127.0.0.1 -p 5432 -U "$user" -d "$db_name" --no-owner -f "$out"
  chmod 600 "$out"
  echo "OK: $out"
}

# Solo lectura: clona el repo de terraform a un scratch temporal (nunca se
# commitea nada ahí), genera el grafo con terraform+graphviz vía "nix shell"
# (herramientas de un solo uso, no se instalan) y lo deja en workos/scratch/.
action_tf_graph() {
  [ -n "$TERRAFORM_REPO" ] && [ -n "$TERRAFORM_DIR" ] \
    || { echo "Terraform no configurado todavía para $NAME." >&2; exit 1; }
  command -v gh >/dev/null || { echo "Falta gh en el PATH." >&2; exit 1; }
  local tmp; tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  echo ">> Clonando (solo lectura) $TERRAFORM_REPO..." >&2
  gh repo clone "$TERRAFORM_REPO" "$tmp/repo" -- --depth 1 -q
  echo ">> Generando el grafo (nix shell terraform + graphviz)..." >&2
  nix shell nixpkgs#terraform nixpkgs#graphviz --command bash -c "
    cd '$tmp/repo/$TERRAFORM_DIR' &&
    terraform init -backend=false -input=false >/dev/null &&
    terraform graph
  " | dot -Tsvg > "$tmp/graph.svg"
  local out_dir="$BASE/scratch"; mkdir -p "$out_dir"
  local out="$out_dir/terraform-$NAME-$(date +%Y%m%d-%H%M%S).svg"
  cp "$tmp/graph.svg" "$out"
  echo "OK: $out"
  xdg-open "$out" >/dev/null 2>&1 &
}

# $1 = código de salida (0 desde -h/--help, 1 desde una acción inválida) -
# el panel COMANDOS de cyber-shell (shortcuts.ts) arma sus páginas de
# `<comando> --help` en vivo y descarta lo que salga con exit != 0, así que
# --help tiene que terminar en 0 para aparecer ahí igual que git/nix/work.
usage() {
  cat >&2 <<EOF
Uso: $NAME <acción> [args]

  login                            aws login --profile $AWS_PROFILE
  k <comando kubectl...>           kubectl contra $NAME, túnel puntual
  exec <deployment> [-- comando]   shell (sin comando) o un comando puntual
  cp <deployment> <local> [remoto] sube un archivo al pod (default /tmp/<nombre>)
  migrate <deployment> [--apply]   --check (dry-run) por defecto
  seed-run <csv> --label <label>   limpia y recarga datos fake en los dos
                                   sistemas de CLOUDOPS_SEED_CONFIG desde ese CSV
  dump <deployment>                pg_dump -> vault/dumps/$NAME/<deployment>/
  argocd [args kubectl get...]     estado de sync de las apps de ArgoCD
  argocd-ui                        port-forward + abre la UI de ArgoCD en el navegador
  headlamp                         abre Headlamp (nix run) contra $NAME
  tf-graph                         terraform graph -> svg (solo lectura)
EOF
  exit "${1:-1}"
}

case "${1:-}" in
  login) shift; action_login "$@" ;;
  k) shift; run_k8s kubectl "$@" ;;
  exec) shift; action_exec "$@" ;;
  cp) shift; action_cp "$@" ;;
  migrate) shift; action_migrate "$@" ;;
  seed-run) shift; action_seed_run "$@" ;;
  dump) shift; action_dump "$@" ;;
  argocd) shift; action_argocd "$@" ;;
  argocd-ui) action_argocd_ui ;;
  headlamp) action_headlamp ;;
  tf-graph) action_tf_graph ;;
  -h|--help) usage 0 ;;
  *) usage 1 ;;
esac
