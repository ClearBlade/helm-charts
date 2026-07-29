#!/bin/bash
#
# GCP-side setup for a temporary streaming replica - automated variant.
#
# Same end result as configure_streaming.sh, but instead of prompting for
# every GCP/AWS/cluster detail by hand, this derives them from the
# customer's Helm values files in $CBOPS/deploy/helm-values:
#
#   {customer}-values.yaml      -> GCP project/region, namespace
#   {customer}-eks-values.yaml  -> AWS region, account ID, EKS cluster name,
#                                  namespace
#
# The GKE cluster name isn't recorded in the values files, so this queries
# gcloud for clusters in the derived project/region and asks you to pick one.
#
# Everything parsed/selected up front is printed for confirmation before any
# of the original script's steps (WAL settings, WireGuard pod, firewall
# rules, etc.) run. From that point on the flow is identical to
# configure_streaming.sh.
#
# "primary" = the GCP PG instance. "replica" = the remote (e.g. AWS) instance.

set -euo pipefail

OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/output"
mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
info()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m!!\033[0m %s\n' "$1"; }
die()   { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

confirm() {
  local prompt="$1"
  local reply
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not on PATH."
}

# Minimal YAML scalar lookup: yaml_get <file> <dotted.path>
# Handles both flat keys (global.gcpProject) and nested maps
# (global.gcp.project) by tracking each line's indentation as a path stack.
# Good enough for the simple global.* scalars this script needs - not a
# general YAML parser (no support for lists, anchors, multi-line strings).
yaml_get() {
  local file="$1" path="$2"
  awk -v path="$path" '
    BEGIN { n = split(path, want, ".") }
    {
      line = $0
      if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*$/) next
      match(line, /^[[:space:]]*/)
      indent = RLENGTH
      content = substr(line, indent+1)
      if (content !~ /^[^[:space:]:][^:]*:/) next
      colon = index(content, ":")
      key = substr(content, 1, colon-1)
      val = substr(content, colon+1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      gsub(/[[:space:]]+#.*$/, "", val)
      gsub(/^"|"$/, "", val)
      gsub(/^\x27|\x27$/, "", val)

      while (depth > 0 && stack_indent[depth] >= indent) depth--
      depth++
      stack_indent[depth] = indent
      stack_key[depth] = key

      if (depth == n) {
        match_ok = 1
        for (i = 1; i <= n; i++) {
          if (stack_key[i] != want[i]) { match_ok = 0; break }
        }
        if (match_ok && val != "") {
          print val
          exit
        }
      }
    }
  ' "$file"
}

# yaml_get_any <file> <path1> <path2> ... - first non-empty match wins.
yaml_get_any() {
  local file="$1"; shift
  local path val
  for path in "$@"; do
    val="$(yaml_get "$file" "$path")"
    if [[ -n "$val" ]]; then
      printf '%s' "$val"
      return 0
    fi
  done
  return 1
}

psql_primary() {
  # Runs a SQL string against the primary as the superuser.
  kubectl --context "$KCTX" exec -n "$NAMESPACE" "$PG_POD" -c cb-postgres -- \
    psql -U "$PG_SUPERUSER" -d "$PG_SUPERUSER_DB" -tAc "$1"
}

psql_primary_exec() {
  # Runs each argument as its OWN separate query (one -c flag per statement).
  # Needed for ALTER SYSTEM/CREATE DATABASE-class statements: psql -c with
  # multiple ;-separated statements sends them as a single simple-query
  # message, which Postgres wraps in an implicit transaction block - and
  # ALTER SYSTEM refuses to run inside one ("cannot run inside a transaction
  # block"). Separate -c flags avoid that entirely.
  local args=()
  for stmt in "$@"; do
    args+=(-c "$stmt")
  done
  kubectl --context "$KCTX" exec -n "$NAMESPACE" "$PG_POD" -c cb-postgres -- \
    psql -U "$PG_SUPERUSER" -d "$PG_SUPERUSER_DB" "${args[@]}"
}

for c in gcloud kubectl jq openssl aws; do require_cmd "$c"; done
[[ -n "${CBOPS:-}" ]] || die "\$CBOPS is not set - expected it to point at the clearblade-ops checkout."
[[ -d "$CBOPS/deploy/helm-values" ]] || die "\$CBOPS/deploy/helm-values not found (CBOPS=$CBOPS)."

# ---------------------------------------------------------------------------
# 0. Derive everything from the customer's Helm values files
# ---------------------------------------------------------------------------
info "Customer lookup"

read -r -p "Customer name: " CUSTOMER_NAME
[[ -n "$CUSTOMER_NAME" ]] || die "Customer name is required."

VALUES_DIR="$CBOPS/deploy/helm-values"
GCP_VALUES_FILE="$VALUES_DIR/${CUSTOMER_NAME}-values.yaml"
AWS_VALUES_FILE="$VALUES_DIR/${CUSTOMER_NAME}-eks-values.yaml"

[[ -f "$GCP_VALUES_FILE" ]] || die "Not found: $GCP_VALUES_FILE"
[[ -f "$AWS_VALUES_FILE" ]] || die "Not found: $AWS_VALUES_FILE"
info "Found $GCP_VALUES_FILE"
info "Found $AWS_VALUES_FILE"

GCP_PROJECT="$(yaml_get_any "$GCP_VALUES_FILE" global.gcpProject global.gcp.project)" \
  || die "Could not find global.gcpProject / global.gcp.project in $GCP_VALUES_FILE"
GCP_REGION="$(yaml_get_any "$GCP_VALUES_FILE" global.gcpRegion global.gcp.region)" \
  || die "Could not find global.gcpRegion / global.gcp.region in $GCP_VALUES_FILE"
NAMESPACE="$(yaml_get "$GCP_VALUES_FILE" global.namespace)"
[[ -n "$NAMESPACE" ]] || die "Could not find global.namespace in $GCP_VALUES_FILE"

REPLICA_AWS_REGION="$(yaml_get "$AWS_VALUES_FILE" global.awsRegion)"
[[ -n "$REPLICA_AWS_REGION" ]] || die "Could not find global.awsRegion in $AWS_VALUES_FILE"
AWS_HELM_ROLE_ARN="$(yaml_get "$AWS_VALUES_FILE" global.awsHelmRoleArn)"
[[ -n "$AWS_HELM_ROLE_ARN" ]] || die "Could not find global.awsHelmRoleArn in $AWS_VALUES_FILE"
REPLICA_NAMESPACE="$(yaml_get "$AWS_VALUES_FILE" global.namespace)"
[[ -n "$REPLICA_NAMESPACE" ]] || die "Could not find global.namespace in $AWS_VALUES_FILE"

REPLICA_AWS_ACCOUNT_ID="$(sed -E 's#^arn:aws:iam::([0-9]+):.*#\1#' <<<"$AWS_HELM_ROLE_ARN")"
[[ "$REPLICA_AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] \
  || die "Could not parse a 12-digit AWS account ID out of global.awsHelmRoleArn ('$AWS_HELM_ROLE_ARN')"
REPLICA_EKS_CLUSTER="$(sed -E 's#.*clearblade-helm-##' <<<"$AWS_HELM_ROLE_ARN")"
[[ -n "$REPLICA_EKS_CLUSTER" && "$REPLICA_EKS_CLUSTER" != "$AWS_HELM_ROLE_ARN" ]] \
  || die "Could not parse an EKS cluster name (after 'clearblade-helm-') out of global.awsHelmRoleArn ('$AWS_HELM_ROLE_ARN')"

info "Parsed GCP project=$GCP_PROJECT region=$GCP_REGION namespace=$NAMESPACE"
info "Parsed AWS region=$REPLICA_AWS_REGION account=$REPLICA_AWS_ACCOUNT_ID cluster=$REPLICA_EKS_CLUSTER namespace=$REPLICA_NAMESPACE"

# ---------------------------------------------------------------------------
# 0a. Pick the GKE cluster (not recorded in the values files)
# ---------------------------------------------------------------------------
info "Looking up GKE clusters in project '$GCP_PROJECT' near region '$GCP_REGION'..."

mapfile -t CLUSTER_LINES < <(gcloud container clusters list --project="$GCP_PROJECT" \
  --filter="location:${GCP_REGION}*" --format="csv[no-heading](name,location)" 2>/dev/null)

if [[ ${#CLUSTER_LINES[@]} -eq 0 ]]; then
  warn "No clusters found with location matching '${GCP_REGION}*' - listing all clusters in project '$GCP_PROJECT' instead."
  mapfile -t CLUSTER_LINES < <(gcloud container clusters list --project="$GCP_PROJECT" \
    --format="csv[no-heading](name,location)" 2>/dev/null)
fi
[[ ${#CLUSTER_LINES[@]} -gt 0 ]] || die "No GKE clusters found in project '$GCP_PROJECT'."

CLUSTER_NAMES=()
CLUSTER_LOCATIONS=()
for line in "${CLUSTER_LINES[@]}"; do
  CLUSTER_NAMES+=("${line%%,*}")
  CLUSTER_LOCATIONS+=("${line##*,}")
done

if [[ ${#CLUSTER_NAMES[@]} -eq 1 ]]; then
  GKE_CLUSTER="${CLUSTER_NAMES[0]}"
  GKE_LOCATION="${CLUSTER_LOCATIONS[0]}"
  info "Only one cluster found: $GKE_CLUSTER ($GKE_LOCATION)"
else
  echo "Multiple clusters found - pick one:"
  for i in "${!CLUSTER_NAMES[@]}"; do
    printf '  %d) %s (%s)\n' "$((i+1))" "${CLUSTER_NAMES[$i]}" "${CLUSTER_LOCATIONS[$i]}"
  done
  read -r -p "Selection [1-${#CLUSTER_NAMES[@]}]: " SELECTION
  [[ "$SELECTION" =~ ^[0-9]+$ && "$SELECTION" -ge 1 && "$SELECTION" -le ${#CLUSTER_NAMES[@]} ]] \
    || die "Invalid selection: '$SELECTION'"
  GKE_CLUSTER="${CLUSTER_NAMES[$((SELECTION-1))]}"
  GKE_LOCATION="${CLUSTER_LOCATIONS[$((SELECTION-1))]}"
fi
info "Selected GKE cluster: $GKE_CLUSTER ($GKE_LOCATION)"

# ---------------------------------------------------------------------------
# 0b. Postgres connection details (no way to derive these from the charts)
# ---------------------------------------------------------------------------
read -r -p "Postgres superuser name [cbuser]: " PG_SUPERUSER
PG_SUPERUSER=${PG_SUPERUSER:-cbuser}
read -r -p "Database to connect to for admin queries [admin]: " PG_SUPERUSER_DB
PG_SUPERUSER_DB=${PG_SUPERUSER_DB:-admin}

# ---------------------------------------------------------------------------
# 0c. Confirm before doing anything
# ---------------------------------------------------------------------------
echo
echo "Derived configuration for customer '$CUSTOMER_NAME':"
echo "  GCP project              : $GCP_PROJECT"
echo "  GCP region                : $GCP_REGION"
echo "  GKE cluster (location)    : $GKE_CLUSTER ($GKE_LOCATION)"
echo "  Namespace (primary)       : $NAMESPACE"
echo "  Postgres superuser / db   : $PG_SUPERUSER / $PG_SUPERUSER_DB"
echo "  AWS region (replica)      : $REPLICA_AWS_REGION"
echo "  AWS account ID (replica)  : $REPLICA_AWS_ACCOUNT_ID"
echo "  EKS cluster (replica)     : $REPLICA_EKS_CLUSTER"
echo "  Namespace (replica)       : $REPLICA_NAMESPACE"
echo
confirm "Does this all look correct? Continue?" || die "Aborted at user request before making any changes."

CONTEXT_ALIAS="gke-${GKE_CLUSTER}"
info "Fetching cluster credentials..."
gcloud container clusters get-credentials "$GKE_CLUSTER" \
  --project "$GCP_PROJECT" --region "$GKE_LOCATION" 2>/dev/null \
  || gcloud container clusters get-credentials "$GKE_CLUSTER" \
       --project "$GCP_PROJECT" --zone "$GKE_LOCATION"
KCTX="$(kubectl config current-context)"
kubectl config rename-context "$KCTX" "$CONTEXT_ALIAS" >/dev/null 2>&1 || true
KCTX="$CONTEXT_ALIAS"
info "Using kube context: $KCTX"

# Find the primary pod (the cb-postgres pod NOT in recovery).
mapfile -t PG_PODS < <(kubectl --context "$KCTX" get pod -n "$NAMESPACE" -l app=cb-postgres -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[[ ${#PG_PODS[@]} -gt 0 ]] || die "No pods with label app=cb-postgres found in namespace $NAMESPACE."

PG_POD=""
for pod in "${PG_PODS[@]}"; do
  in_recovery=$(kubectl --context "$KCTX" exec -n "$NAMESPACE" "$pod" -c cb-postgres -- \
    psql -U "$PG_SUPERUSER" -d "$PG_SUPERUSER_DB" -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "")
  if [[ "$in_recovery" == "f" ]]; then
    PG_POD="$pod"
    break
  fi
done
if [[ -z "$PG_POD" ]]; then
  if [[ ${#PG_PODS[@]} -eq 1 ]]; then
    PG_POD="${PG_PODS[0]}"
    warn "Could not confirm primary via pg_is_in_recovery(); only one pod found ($PG_POD), assuming it's the primary."
  else
    die "Could not identify the primary among: ${PG_PODS[*]}"
  fi
fi
info "Primary pod: $PG_POD"

# ---------------------------------------------------------------------------
# 1. Compatibility check
# ---------------------------------------------------------------------------
info "Checking wal_level..."
WAL_LEVEL=$(psql_primary "SHOW wal_level;")
info "wal_level = $WAL_LEVEL"
if [[ "$WAL_LEVEL" != "replica" && "$WAL_LEVEL" != "logical" ]]; then
  die "wal_level is '$WAL_LEVEL'. Streaming replication needs 'replica' or 'logical', which requires a restart to change - this can't be done with no downtime. Aborting."
fi
info "Primary is compatible - can add a streaming replica with no downtime."

# ---------------------------------------------------------------------------
# 2. Replicator role
# ---------------------------------------------------------------------------
info "Checking for existing 'replicator' role..."
ROLE_EXISTS=$(psql_primary "SELECT 1 FROM pg_roles WHERE rolname = 'replicator';")

REPL_PASSWORD_FILE="$OUT_DIR/replicator-password.txt"
if [[ "$ROLE_EXISTS" == "1" ]]; then
  warn "Role 'replicator' already exists."
  if confirm "Reset its password?"; then
    REPL_PASSWORD=$(openssl rand -base64 18)
    psql_primary "ALTER ROLE replicator WITH PASSWORD '${REPL_PASSWORD}';" >/dev/null
    echo -n "$REPL_PASSWORD" > "$REPL_PASSWORD_FILE"
    chmod 600 "$REPL_PASSWORD_FILE"
    info "Password reset and saved to $REPL_PASSWORD_FILE"
  else
    warn "Leaving existing role/password untouched. You'll need the existing password for pg_basebackup on the replica."
  fi
else
  confirm "Create replication role 'replicator' on the primary?" || die "Aborted before creating replicator role."
  REPL_PASSWORD=$(openssl rand -base64 18)
  psql_primary "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '${REPL_PASSWORD}';" >/dev/null
  echo -n "$REPL_PASSWORD" > "$REPL_PASSWORD_FILE"
  chmod 600 "$REPL_PASSWORD_FILE"
  info "Role created. Password saved to $REPL_PASSWORD_FILE (chmod 600) - you'll need it on the replica for pg_basebackup."
fi

# ---------------------------------------------------------------------------
# 3. Deploy the WireGuard server pod
# ---------------------------------------------------------------------------
info "Deploying the WireGuard tunnel server..."

WG_NAME="wg-postgres-${NAMESPACE}"
WG_SERVER_PORT=51820
WG_INTERNAL_SUBNET="10.13.13.0"

# NodePorts are cluster-wide, not per-namespace, so a fixed value here would
# collide with any other WireGuard tunnel Service already running on the same
# node pool. Pick a random one in the default NodePort range instead.
WG_NODE_PORT=$(( (RANDOM % 2768) + 30000 ))
info "Picked NodePort: $WG_NODE_PORT"

NODE_EXTERNAL_IP=$(kubectl --context "$KCTX" get nodes \
  -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="ExternalIP")].address}{"\n"}{end}' \
  | grep -v '^$' | head -1)
[[ -n "$NODE_EXTERNAL_IP" ]] || die "No node has an external IP - this cluster looks private. This script's NodePort approach won't work here; needs a different exposure method."
info "Using node external IP for the tunnel endpoint: $NODE_EXTERNAL_IP"

PG_POD_IP=$(kubectl --context "$KCTX" get pod -n "$NAMESPACE" "$PG_POD" -o jsonpath='{.status.podIP}')
info "Primary pod IP (the AllowedIPs route the replica needs): $PG_POD_IP"

WG_MANIFEST="$OUT_DIR/${WG_NAME}.yaml"
cat > "$WG_MANIFEST" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${WG_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${WG_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${WG_NAME}
  template:
    metadata:
      labels:
        app: ${WG_NAME}
    spec:
      containers:
        - name: wireguard
          image: lscr.io/linuxserver/wireguard:latest
          securityContext:
            capabilities:
              add:
                - NET_ADMIN
          env:
            - name: PUID
              value: "1000"
            - name: PGID
              value: "1000"
            - name: TZ
              value: "Etc/UTC"
            - name: SERVERURL
              value: "${NODE_EXTERNAL_IP}"
            - name: SERVERPORT
              value: "${WG_SERVER_PORT}"
            - name: PEERS
              value: "1"
            - name: PEERDNS
              value: "off"
            - name: INTERNAL_SUBNET
              value: "${WG_INTERNAL_SUBNET}"
            - name: ALLOWEDIPS
              value: "${PG_POD_IP}/32"
          ports:
            - containerPort: ${WG_SERVER_PORT}
              protocol: UDP
          volumeMounts:
            - name: wg-config
              mountPath: /config
      volumes:
        - name: wg-config
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: ${WG_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${WG_NAME}
spec:
  type: NodePort
  selector:
    app: ${WG_NAME}
  ports:
    - port: ${WG_SERVER_PORT}
      targetPort: ${WG_SERVER_PORT}
      nodePort: ${WG_NODE_PORT}
      protocol: UDP
EOF

info "Generated $WG_MANIFEST"
kubectl --context "$KCTX" apply -f "$WG_MANIFEST"
kubectl --context "$KCTX" -n "$NAMESPACE" rollout status "deployment/${WG_NAME}" --timeout=120s

WG_POD_IP=$(kubectl --context "$KCTX" get pod -n "$NAMESPACE" -l app="${WG_NAME}" -o jsonpath='{.items[0].status.podIP}')
info "WireGuard server pod IP (what the primary will see replication connections come from, after NAT): $WG_POD_IP"

PEER_CONF="$OUT_DIR/peer1.conf"
kubectl --context "$KCTX" -n "$NAMESPACE" exec "deploy/${WG_NAME}" -- cat /config/peer1/peer1.conf > "$PEER_CONF"
# Fix the endpoint port to the actual NodePort, not the container's internal port.
sed -i.bak "s/:${WG_SERVER_PORT}\$/:${WG_NODE_PORT}/" "$PEER_CONF" && rm -f "${PEER_CONF}.bak"
info "Client (replica-side) WireGuard config written to $PEER_CONF"

# ---------------------------------------------------------------------------
# 4. Allow the WireGuard pod's IP to replicate in pg_hba.conf
# ---------------------------------------------------------------------------
info "Patching pg_hba.conf to allow replication from ${WG_POD_IP}..."

HBA_LINE="host    replication     replicator      ${WG_POD_IP}/32           scram-sha-256"
CURRENT_HBA=$(kubectl --context "$KCTX" get configmap postgres-config -n "$NAMESPACE" -o jsonpath='{.data.pg_hba\.conf}')

if grep -qF "${WG_POD_IP}/32" <<<"$CURRENT_HBA"; then
  warn "pg_hba.conf already has an entry for ${WG_POD_IP}/32 - skipping patch."
else
  kubectl --context "$KCTX" get configmap postgres-config -n "$NAMESPACE" -o json | \
    jq --arg line $'\n'"${HBA_LINE}"$'\n' '.data["pg_hba.conf"] += $line' | \
    kubectl --context "$KCTX" apply -f -
  info "ConfigMap patched. Waiting for it to sync into the pod (~30-60s)..."
  sleep 45
  kubectl --context "$KCTX" exec -n "$NAMESPACE" "$PG_POD" -c cb-postgres -- tail -3 /etc/postgresql/pg_hba.conf
  psql_primary "SELECT pg_reload_conf();" >/dev/null
  info "Config reloaded."
fi

# ---------------------------------------------------------------------------
# 5. Primary WAL settings
#
# Applied via ALTER SYSTEM only - deliberately NOT followed by
# pg_reload_conf() here. Run it right after this and it reloads against the
# ConfigMap-mounted postgresql.conf as it stood before this change landed,
# which doesn't reflect these new values; the file the pod actually sees
# only catches up on its own schedule. Also, max_wal_senders and
# max_replication_slots are postmaster-context settings - reload can't
# apply them at all, only a full restart can. So there's no reload to
# usefully call here: these values sit in postgresql.auto.conf until the
# next restart picks them up.
# ---------------------------------------------------------------------------
info "Checking free space on the primary's data volume (used to size max_slot_wal_keep_size)..."
kubectl --context "$KCTX" exec -n "$NAMESPACE" "$PG_POD" -c cb-postgres -- df -h /var/lib/postgresql/data

warn "max_slot_wal_keep_size caps how much WAL the primary retains for a stalled/disconnected replica."
warn "Set it too high and a stuck replica can fill the primary's disk. Recommended: ~60% of the free space shown above."
read -r -p "max_slot_wal_keep_size (e.g. 25GB): " MAX_SLOT_WAL_KEEP_SIZE
[[ -n "$MAX_SLOT_WAL_KEEP_SIZE" ]] || die "max_slot_wal_keep_size is required."

echo
echo "About to run on the PRIMARY (production):"
cat <<SQL
  ALTER SYSTEM SET max_wal_senders = 10;
  ALTER SYSTEM SET max_replication_slots = 10;
  ALTER SYSTEM SET wal_keep_size = '1GB';
  ALTER SYSTEM SET max_slot_wal_keep_size = '${MAX_SLOT_WAL_KEEP_SIZE}';
  ALTER SYSTEM SET hot_standby = on;
  SELECT pg_reload_conf();
SQL
confirm "Apply these settings to the primary now?" || die "Aborted before applying WAL settings."

psql_primary_exec \
  "ALTER SYSTEM SET max_wal_senders = 10;" \
  "ALTER SYSTEM SET max_replication_slots = 10;" \
  "ALTER SYSTEM SET wal_keep_size = '1GB';" \
  "ALTER SYSTEM SET max_slot_wal_keep_size = '${MAX_SLOT_WAL_KEEP_SIZE}';" \
  "ALTER SYSTEM SET hot_standby = on;" \
  "SELECT pg_reload_conf();" >/dev/null
info "WAL settings written to postgresql.auto.conf."
warn "max_wal_senders and max_replication_slots need a full restart of the primary to take effect - this script does not restart it for you. Plan a restart before the replica tries to connect."

# ---------------------------------------------------------------------------
# 6. Discover the replica cluster's node public IPs
#
# The replica's EKS cluster + node group already exist at this point (they
# were provisioned before this script runs), even though the
# streaming-replica-proxy pod hasn't been deployed yet. So rather than
# opening the firewall wide and locking it down after the fact, whitelist
# every current node's public IP now - the proxy pod will land on one of
# them, and re-running this script refreshes the list if the node pool
# changes later.
# ---------------------------------------------------------------------------
info "Discovering the replica cluster's node public IPs..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_ROLE_SCRIPT="$SCRIPT_DIR/create-helm-role.sh"
[[ -x "$HELM_ROLE_SCRIPT" ]] || die "Expected $HELM_ROLE_SCRIPT to exist and be executable."
source "$SCRIPT_DIR/lib/aws-org-auth.sh"

AWS_REGION="$REPLICA_AWS_REGION"
AWS_PROFILE=""
ACCOUNT_ID_INPUT="$REPLICA_AWS_ACCOUNT_ID"
ORG_ACCESS_ROLE="OrganizationAccountAccessRole"
BASE_PROFILE="base"
resolve_aws_auth
REPLICA_AWS_ARGS=("${AWS_ARGS[@]}")

REPLICA_KCTX="eks-${REPLICA_EKS_CLUSTER}"
aws eks update-kubeconfig "${REPLICA_AWS_ARGS[@]}" --name "$REPLICA_EKS_CLUSTER" --alias "$REPLICA_KCTX" >/dev/null

mapfile -t REPLICA_NODE_IPS < <(kubectl --context "$REPLICA_KCTX" get nodes \
  -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="ExternalIP")].address}{"\n"}{end}' \
  | grep -v '^$')
[[ ${#REPLICA_NODE_IPS[@]} -gt 0 ]] || die "No nodes with an external IP found in cluster $REPLICA_EKS_CLUSTER - can't build the firewall allowlist. Is the node group up yet?"
info "Found ${#REPLICA_NODE_IPS[@]} replica node IP(s): ${REPLICA_NODE_IPS[*]}"

REPLICA_SOURCE_RANGES=$(printf '%s/32,' "${REPLICA_NODE_IPS[@]}")
REPLICA_SOURCE_RANGES=${REPLICA_SOURCE_RANGES%,}

# ---------------------------------------------------------------------------
# 7. Firewall rule - create/update directly with the full node IP list from
#    step 6. No temporary wide-open state needed.
# ---------------------------------------------------------------------------
FW_RULE="allow-wireguard-${NAMESPACE}"
NODE_NAME=$(kubectl --context "$KCTX" get nodes -o jsonpath='{.items[0].metadata.name}')
NODE_TAG=$(gcloud compute instances list --project "$GCP_PROJECT" --filter="name=${NODE_NAME}" --format="value(tags.items[0])")

if gcloud compute firewall-rules describe "$FW_RULE" --project "$GCP_PROJECT" >/dev/null 2>&1; then
  info "Firewall rule $FW_RULE already exists - updating its source ranges to the current replica node IPs."
  confirm "Update '$FW_RULE' source ranges to: ${REPLICA_SOURCE_RANGES}?" || die "Aborted before updating firewall rule."
  gcloud compute firewall-rules update "$FW_RULE" --project="$GCP_PROJECT" --source-ranges="$REPLICA_SOURCE_RANGES"
else
  confirm "Create firewall rule '$FW_RULE' allowing UDP:${WG_NODE_PORT} from: ${REPLICA_SOURCE_RANGES}?" || die "Aborted before creating firewall rule."
  gcloud compute firewall-rules create "$FW_RULE" \
    --project="$GCP_PROJECT" --network="$(gcloud compute instances describe "$NODE_NAME" --project "$GCP_PROJECT" --zone "$(gcloud compute instances list --project "$GCP_PROJECT" --filter="name=${NODE_NAME}" --format='value(zone.basename())')" --format='value(networkInterfaces[0].network.basename())')" \
    --direction=INGRESS --action=ALLOW --rules="udp:${WG_NODE_PORT}" \
    --source-ranges="$REPLICA_SOURCE_RANGES" \
    --target-tags="$NODE_TAG"
fi
info "Firewall rule $FW_RULE allows UDP:${WG_NODE_PORT} from: $REPLICA_SOURCE_RANGES"

# ---------------------------------------------------------------------------
# 8. Set up the IRSA role the replica-side (AWS) chart needs, then print the
#    values to deploy it with.
# ---------------------------------------------------------------------------
# info "Setting up the IAM role for the replica-side (AWS) Helm chart..."

# HELM_ROLE_ARN_FILE="$OUT_DIR/aws-helm-role-arn.txt"
# HELM_ROLE_ARGS=(--region "$REPLICA_AWS_REGION" --cluster "$REPLICA_EKS_CLUSTER" --namespace "$REPLICA_NAMESPACE" --account-id "$REPLICA_AWS_ACCOUNT_ID" --out-file "$HELM_ROLE_ARN_FILE")

# "$HELM_ROLE_SCRIPT" "${HELM_ROLE_ARGS[@]}"

info "GCP-side setup complete. Artifacts written to $OUT_DIR:"
echo "  - $REPL_PASSWORD_FILE   (replicator role password, if created/reset this run)"
echo "  - $PEER_CONF            (WireGuard client config - copy this to the replica side)"
echo "  - $WG_MANIFEST          (the manifest applied for the WireGuard server pod)"
echo
echo "Firewall rule $FW_RULE is already locked down to the replica cluster's node IPs - no follow-up lockdown step needed."
echo
echo "Now deploy the replica-side Helm chart (global.streamingReplica=true) using:"
echo "  - global.streamingReplica=true"
echo "  - cb-postgres.streamingReplica.primaryHost=${PG_POD_IP}"
echo "  - cb-postgres.streamingReplica.wgConfig=\"\$(cat $PEER_CONF)\"  (endpoint already set to ${NODE_EXTERNAL_IP}:${WG_NODE_PORT})"
echo "  - cb-postgres.streamingReplica.replicatorPassword=\"\$(cat $REPL_PASSWORD_FILE)\""
echo
info "All done - primary is configured, tunnel is up, and the firewall rule is ready for the replica to connect once deployed."
warn "If the replica cluster's node pool changes (nodes added/replaced) after this, re-run this script to refresh the firewall rule's source ranges."
