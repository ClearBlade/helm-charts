#!/bin/bash
#
# GCP-side setup for a temporary streaming replica - PRIVATE-CLUSTER VARIANT.
#
# Same as configure_streaming.sh, except the primary's GKE nodes have no
# external IP (private cluster), so a NodePort Service can't be reached from
# the replica's AWS side. This variant instead exposes the WireGuard server
# through a GCP external passthrough Network Load Balancer (Service type
# LoadBalancer) on a reserved static IP.
#
# Because that IP is reserved up front, and the Service's
# loadBalancerSourceRanges is scoped to the replica's node IPs from the
# moment the Service is created, there's no wide-open window and no manual
# firewall rule to manage - GKE auto-manages the ingress firewall rule for a
# LoadBalancer Service based on loadBalancerSourceRanges. That's why the
# "discover replica node IPs" step now runs BEFORE the WireGuard Service is
# created, instead of after as in the NodePort version.
#
# Use configure_streaming.sh instead if the primary's GKE nodes have
# external IPs - it's simpler and doesn't need a reserved static IP.
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

# Derives the GCE region from a zone (e.g. "us-central1-a" -> "us-central1").
# Already-regional locations (e.g. "us-central1") pass through unchanged.
region_from_location() {
  local loc="$1"
  if [[ "$loc" =~ ^(.+)-[a-z]$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "$loc"
  fi
}

for c in gcloud kubectl jq openssl aws; do require_cmd "$c"; done

# ---------------------------------------------------------------------------
# 1. Gather inputs
# ---------------------------------------------------------------------------
info "GCP / cluster details"

read -r -p "GCP project ID: " GCP_PROJECT
read -r -p "GKE cluster name: " GKE_CLUSTER
read -r -p "GKE cluster location (region or zone, e.g. us-central1): " GKE_LOCATION
read -r -p "Kubernetes namespace the postgres instance runs in: " NAMESPACE
read -r -p "Postgres superuser name [cbuser]: " PG_SUPERUSER
PG_SUPERUSER=${PG_SUPERUSER:-cbuser}
read -r -p "Database to connect to for admin queries [admin]: " PG_SUPERUSER_DB
PG_SUPERUSER_DB=${PG_SUPERUSER_DB:-admin}

GCP_REGION="$(region_from_location "$GKE_LOCATION")"
info "Using GCP region for the reserved LB IP: $GCP_REGION"

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
# 2. Compatibility check
# ---------------------------------------------------------------------------
info "Checking wal_level..."
WAL_LEVEL=$(psql_primary "SHOW wal_level;")
info "wal_level = $WAL_LEVEL"
if [[ "$WAL_LEVEL" != "replica" && "$WAL_LEVEL" != "logical" ]]; then
  die "wal_level is '$WAL_LEVEL'. Streaming replication needs 'replica' or 'logical', which requires a restart to change - this can't be done with no downtime. Aborting."
fi
info "Primary is compatible - can add a streaming replica with no downtime."

# ---------------------------------------------------------------------------
# 3. Replicator role
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
# 4. Discover the replica cluster's node public IPs
#
# The replica's EKS cluster + node group already exist at this point (they
# were provisioned before this script runs), even though the
# streaming-replica-proxy pod hasn't been deployed yet. This runs BEFORE the
# WireGuard Service is created (unlike the NodePort variant, where it runs
# after) so the LoadBalancer Service can be scoped to these IPs from the
# moment it's created - no wide-open window, no separate firewall step.
# ---------------------------------------------------------------------------
info "Discovering the replica cluster's node public IPs..."

read -r -p "AWS region the replica's EKS cluster is in: " REPLICA_AWS_REGION
[[ -n "$REPLICA_AWS_REGION" ]] || die "AWS region is required."
read -r -p "Replica-side EKS cluster name: " REPLICA_EKS_CLUSTER
[[ -n "$REPLICA_EKS_CLUSTER" ]] || die "EKS cluster name is required."
read -r -p "Kubernetes namespace the replica-side chart deploys into [$NAMESPACE]: " REPLICA_NAMESPACE
REPLICA_NAMESPACE=${REPLICA_NAMESPACE:-$NAMESPACE}
read -r -p "AWS account ID the replica's EKS cluster lives in (chains off the 'base' profile): " REPLICA_AWS_ACCOUNT_ID
[[ -n "$REPLICA_AWS_ACCOUNT_ID" ]] || die "AWS account ID is required."

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
[[ ${#REPLICA_NODE_IPS[@]} -gt 0 ]] || die "No nodes with an external IP found in cluster $REPLICA_EKS_CLUSTER - can't scope the WireGuard Service's source ranges. Is the node group up yet?"
info "Found ${#REPLICA_NODE_IPS[@]} replica node IP(s): ${REPLICA_NODE_IPS[*]}"

LB_SOURCE_RANGES_YAML=""
for ip in "${REPLICA_NODE_IPS[@]}"; do
  LB_SOURCE_RANGES_YAML+="    - ${ip}/32"$'\n'
done

# ---------------------------------------------------------------------------
# 5. Reserve a static IP and deploy the WireGuard server behind a
#    LoadBalancer Service, scoped to the replica node IPs from step 4.
# ---------------------------------------------------------------------------
info "Reserving a static public IP for the WireGuard tunnel..."

WG_NAME="wg-postgres-${NAMESPACE}"
WG_SERVER_PORT=51820
WG_INTERNAL_SUBNET="10.13.13.0"
WG_IP_NAME="${WG_NAME}-ip"

if gcloud compute addresses describe "$WG_IP_NAME" --project="$GCP_PROJECT" --region="$GCP_REGION" >/dev/null 2>&1; then
  info "Static IP '$WG_IP_NAME' already reserved - reusing it."
else
  gcloud compute addresses create "$WG_IP_NAME" --project="$GCP_PROJECT" --region="$GCP_REGION"
fi
WG_LB_IP=$(gcloud compute addresses describe "$WG_IP_NAME" --project="$GCP_PROJECT" --region="$GCP_REGION" --format='value(address)')
info "WireGuard public IP: $WG_LB_IP"

PG_POD_IP=$(kubectl --context "$KCTX" get pod -n "$NAMESPACE" "$PG_POD" -o jsonpath='{.status.podIP}')
info "Primary pod IP (the AllowedIPs route the replica needs): $PG_POD_IP"

info "Deploying the WireGuard tunnel server..."
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
              value: "${WG_LB_IP}"
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
  type: LoadBalancer
  loadBalancerIP: ${WG_LB_IP}
  loadBalancerSourceRanges:
${LB_SOURCE_RANGES_YAML}
  selector:
    app: ${WG_NAME}
  ports:
    - port: ${WG_SERVER_PORT}
      targetPort: ${WG_SERVER_PORT}
      protocol: UDP
EOF

info "Generated $WG_MANIFEST"
kubectl --context "$KCTX" apply -f "$WG_MANIFEST"
kubectl --context "$KCTX" -n "$NAMESPACE" rollout status "deployment/${WG_NAME}" --timeout=120s

info "Waiting for the LoadBalancer Service to get its external IP..."
ASSIGNED_IP=""
for _ in $(seq 1 30); do
  ASSIGNED_IP=$(kubectl --context "$KCTX" -n "$NAMESPACE" get svc "$WG_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [[ -n "$ASSIGNED_IP" ]] && break
  sleep 5
done
[[ -n "$ASSIGNED_IP" ]] || die "Timed out waiting for an external IP on Service ${WG_NAME}."
if [[ "$ASSIGNED_IP" != "$WG_LB_IP" ]]; then
  warn "Assigned LB IP ($ASSIGNED_IP) differs from the reserved static IP ($WG_LB_IP) - check the Service's loadBalancerIP field."
else
  info "LoadBalancer is up on $ASSIGNED_IP:${WG_SERVER_PORT}/udp"
fi

WG_POD_IP=$(kubectl --context "$KCTX" get pod -n "$NAMESPACE" -l app="${WG_NAME}" -o jsonpath='{.items[0].status.podIP}')
info "WireGuard server pod IP (what the primary will see replication connections come from, after NAT): $WG_POD_IP"

# SERVERPORT and the Service's port/targetPort all match ${WG_SERVER_PORT}, so
# (unlike the NodePort variant) the endpoint baked into peer1.conf at
# container startup is already correct - no port rewrite needed.
PEER_CONF="$OUT_DIR/peer1.conf"
kubectl --context "$KCTX" -n "$NAMESPACE" exec "deploy/${WG_NAME}" -- cat /config/peer1/peer1.conf > "$PEER_CONF"
info "Client (replica-side) WireGuard config written to $PEER_CONF"

# ---------------------------------------------------------------------------
# 6. Allow the WireGuard pod's IP to replicate in pg_hba.conf
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
# 7. Primary WAL settings
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
# 8. Setup the IRSA role the replica-side (AWS) chart needs, then print the
#    values to deploy it with.
# ---------------------------------------------------------------------------
# info "Setting up the IAM role for the replica-side (AWS) Helm chart..."

# HELM_ROLE_ARN_FILE="$OUT_DIR/aws-helm-role-arn.txt"
# HELM_ROLE_ARGS=(--region "$REPLICA_AWS_REGION" --cluster "$REPLICA_EKS_CLUSTER" --namespace "$REPLICA_NAMESPACE" --account-id "$REPLICA_AWS_ACCOUNT_ID" --out-file "$HELM_ROLE_ARN_FILE")

# "$HELM_ROLE_SCRIPT" "${HELM_ROLE_ARGS[@]}"
# AWS_HELM_ROLE_ARN=$(cat "$HELM_ROLE_ARN_FILE")
# [[ -n "$AWS_HELM_ROLE_ARN" ]] || die "create-helm-role.sh did not produce a role ARN - see output above."

info "GCP-side setup complete. Artifacts written to $OUT_DIR:"
echo "  - $REPL_PASSWORD_FILE   (replicator role password, if created/reset this run)"
echo "  - $PEER_CONF            (WireGuard client config - copy this to the replica side)"
echo "  - $WG_MANIFEST          (the manifest applied for the WireGuard server pod + LB Service)"
# echo "  - $HELM_ROLE_ARN_FILE   (the IRSA role ARN created for the replica-side chart)"
echo
echo "WireGuard is reachable at ${WG_LB_IP}:${WG_SERVER_PORT}/udp, already restricted to the"
echo "replica cluster's node IPs via the Service's loadBalancerSourceRanges - GKE manages the"
echo "matching ingress firewall rule automatically, no separate firewall rule needed."
echo
echo "Now deploy the replica-side Helm chart (global.streamingReplica=true) using:"
echo "  - global.streamingReplica=true"
# echo "  - global.awsHelmRoleArn=${AWS_HELM_ROLE_ARN}"
echo "  - cb-postgres.streamingReplica.primaryHost=${PG_POD_IP}"
echo "  - cb-postgres.streamingReplica.wgConfig=\"\$(cat $PEER_CONF)\"  (endpoint already set to ${WG_LB_IP}:${WG_SERVER_PORT})"
echo "  - cb-postgres.streamingReplica.replicatorPassword=\"\$(cat $REPL_PASSWORD_FILE)\""
echo
info "All done - primary is configured, tunnel is up, and the Service is already scoped to the replica's node IPs."
warn "If the replica cluster's node pool changes (nodes added/replaced) after this, re-run this script - it'll refresh the reserved IP lookup and re-apply loadBalancerSourceRanges to the current node IPs."
