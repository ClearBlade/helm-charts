#!/bin/bash
#
# GCP-side setup for a temporary streaming replica.
#
# Sets up the "primary" (the customer's GCP cb-postgres instance) for
# streaming replication and stands up the WireGuard server pod that the
# remote replica will tunnel through. This is phase 1 of 2 - a follow-up
# script handles the AWS/replica side and feeds its egress IP back into the
# firewall rule this script creates.
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

# ---------------------------------------------------------------------------
# Firewall lockdown - shared logic used both by standalone `lockdown` mode
# and automatically at the end of the normal setup flow.
# ---------------------------------------------------------------------------
apply_firewall_lockdown() {
  local fw_rule="$1" project="$2" ip="$3"

  gcloud compute firewall-rules describe "$fw_rule" --project "$project" >/dev/null 2>&1 \
    || die "Firewall rule $fw_rule not found in project $project - run setup mode first."

  local current_ranges
  current_ranges=$(gcloud compute firewall-rules describe "$fw_rule" --project "$project" --format="value(sourceRanges)")
  info "Current source ranges: $current_ranges"
  confirm "Replace with just ${ip}/32 (this closes off anything else currently allowed, including 0.0.0.0/0 from setup)?" \
    || die "Aborted before locking down firewall rule."

  gcloud compute firewall-rules update "$fw_rule" --project="$project" --source-ranges="${ip}/32"
  info "Firewall rule $fw_rule locked down to ${ip}/32 only."
}

# Standalone mode: run this later if you need to re-lock-down after the fact
# (e.g. the replica's EIP changed). Usage: ./configure_streaming.sh lockdown
lockdown_firewall_standalone() {
  require_cmd gcloud

  info "Locking down the WireGuard firewall rule to the replica's egress IP"
  read -r -p "GCP project ID: " GCP_PROJECT
  read -r -p "Kubernetes namespace the postgres instance runs in: " NAMESPACE
  read -r -p "Replica's egress IP: " REPLICA_EGRESS_IP
  [[ -n "$REPLICA_EGRESS_IP" ]] || die "Replica egress IP is required."

  apply_firewall_lockdown "allow-wireguard-${NAMESPACE}" "$GCP_PROJECT" "$REPLICA_EGRESS_IP"
}

# Used automatically at the end of the normal setup flow, once the operator
# confirms the replica-side Helm chart is deployed. Discovers the replica's
# static Elastic IP (tagged by cb-postgres's streamingReplica.staticEgressIP
# feature) via the AWS CLI instead of asking the operator to look it up
# manually, then locks down the rule created earlier in this same run.
discover_aws_egress_ip_and_lockdown() {
  require_cmd aws

  info "Finding the replica's static egress IP..."
  read -r -p "AWS region the replica's EKS cluster is in: " AWS_REGION
  read -r -p "AWS CLI profile to use (leave blank for default): " AWS_PROFILE
  read -r -p "EIP name tag [streaming-replica-egress]: " EIP_TAG
  EIP_TAG=${EIP_TAG:-streaming-replica-egress}

  local aws_args=(--region "$AWS_REGION")
  [[ -n "$AWS_PROFILE" ]] && aws_args+=(--profile "$AWS_PROFILE")

  local egress_ip
  while true; do
    egress_ip=$(aws ec2 describe-addresses "${aws_args[@]}" \
      --filters "Name=tag:Name,Values=${EIP_TAG}" \
      --query "Addresses[0].PublicIp" --output text 2>/dev/null || echo "")
    if [[ -n "$egress_ip" && "$egress_ip" != "None" ]]; then
      break
    fi
    warn "No Elastic IP tagged '${EIP_TAG}' found yet (or it's not associated with an instance yet). The proxy pod's init container may still be starting."
    confirm "Retry?" || die "Aborted - re-run '$0 lockdown' later once the replica side is confirmed up."
  done

  info "Found replica egress IP: $egress_ip"
  apply_firewall_lockdown "$FW_RULE" "$GCP_PROJECT" "$egress_ip"
}

if [[ "${1:-}" == "lockdown" ]]; then
  lockdown_firewall_standalone
  exit 0
fi

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
# 3. Primary WAL settings
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
info "WAL settings applied and config reloaded."

# ---------------------------------------------------------------------------
# 4. Replicator role
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
# 5. Deploy the WireGuard server pod
# ---------------------------------------------------------------------------
info "Deploying the WireGuard tunnel server..."

WG_NAME="wg-postgres-${NAMESPACE}"
WG_SERVER_PORT=51820
WG_NODE_PORT=31820
WG_INTERNAL_SUBNET="10.13.13.0"

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
# 7. Firewall rule
#
# Circular dependency: the replica's egress IP doesn't exist until the
# AWS/replica chart is actually deployed, but the tunnel needs to work for
# that deployment to be verified. So this opens the rule to any source for
# now - deploy the replica side, confirm the tunnel handshakes, THEN run
# this script again with `lockdown` to restrict it to just the replica's
# actual egress IP.
# ---------------------------------------------------------------------------
FW_RULE="allow-wireguard-${NAMESPACE}"
NODE_NAME=$(kubectl --context "$KCTX" get nodes -o jsonpath='{.items[0].metadata.name}')
NODE_TAG=$(gcloud compute instances list --project "$GCP_PROJECT" --filter="name=${NODE_NAME}" --format="value(tags.items[0])")

if gcloud compute firewall-rules describe "$FW_RULE" --project "$GCP_PROJECT" >/dev/null 2>&1; then
  info "Firewall rule $FW_RULE already exists - leaving it as-is."
else
  warn "Opening this rule to 0.0.0.0/0 (any source) for now, since the replica's egress IP doesn't exist until it's deployed."
  confirm "Create firewall rule '$FW_RULE' allowing UDP:${WG_NODE_PORT} from ANYWHERE (temporary)?" || die "Aborted before creating firewall rule."
  gcloud compute firewall-rules create "$FW_RULE" \
    --project="$GCP_PROJECT" --network="$(gcloud compute instances describe "$NODE_NAME" --project "$GCP_PROJECT" --zone "$(gcloud compute instances list --project "$GCP_PROJECT" --filter="name=${NODE_NAME}" --format='value(zone.basename())')" --format='value(networkInterfaces[0].network.basename())')" \
    --direction=INGRESS --action=ALLOW --rules="udp:${WG_NODE_PORT}" \
    --source-ranges="0.0.0.0/0" \
    --target-tags="$NODE_TAG"
  info "Firewall rule created, temporarily open to 0.0.0.0/0."
fi
warn "This rule is wide open for now - it gets locked down automatically later in this script."

# ---------------------------------------------------------------------------
# 8. Set up the IRSA role and the static egress IP the replica-side (AWS)
#    chart needs, then deploy the replica side.
# ---------------------------------------------------------------------------
info "Setting up the IAM role and static egress IP for the replica-side (AWS) Helm chart..."

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
EGRESS_IP_SCRIPT="$SCRIPT_DIR/allocate-egress-ip.sh"
[[ -x "$HELM_ROLE_SCRIPT" ]] || die "Expected $HELM_ROLE_SCRIPT to exist and be executable."
[[ -x "$EGRESS_IP_SCRIPT" ]] || die "Expected $EGRESS_IP_SCRIPT to exist and be executable."

HELM_ROLE_ARN_FILE="$OUT_DIR/aws-helm-role-arn.txt"
HELM_ROLE_ARGS=(--region "$REPLICA_AWS_REGION" --cluster "$REPLICA_EKS_CLUSTER" --namespace "$REPLICA_NAMESPACE" --account-id "$REPLICA_AWS_ACCOUNT_ID" --out-file "$HELM_ROLE_ARN_FILE")

"$HELM_ROLE_SCRIPT" "${HELM_ROLE_ARGS[@]}"
AWS_HELM_ROLE_ARN=$(cat "$HELM_ROLE_ARN_FILE")
[[ -n "$AWS_HELM_ROLE_ARN" ]] || die "create-helm-role.sh did not produce a role ARN - see output above."

EGRESS_IP_ALLOCATION_FILE="$OUT_DIR/aws-egress-ip-allocation-id.txt"
EGRESS_IP_ARGS=(--region "$REPLICA_AWS_REGION" --namespace "$REPLICA_NAMESPACE" --account-id "$REPLICA_AWS_ACCOUNT_ID" --out-file "$EGRESS_IP_ALLOCATION_FILE")

"$EGRESS_IP_SCRIPT" "${EGRESS_IP_ARGS[@]}"
AWS_EGRESS_IP_ALLOCATION_ID=$(cat "$EGRESS_IP_ALLOCATION_FILE")
[[ -n "$AWS_EGRESS_IP_ALLOCATION_ID" ]] || die "allocate-egress-ip.sh did not produce an allocation ID - see output above."

info "GCP-side setup complete. Artifacts written to $OUT_DIR:"
echo "  - $REPL_PASSWORD_FILE          (replicator role password, if created/reset this run)"
echo "  - $PEER_CONF                   (WireGuard client config - copy this to the replica side)"
echo "  - $WG_MANIFEST                 (the manifest applied for the WireGuard server pod)"
echo "  - $HELM_ROLE_ARN_FILE          (the IRSA role ARN created for the replica-side chart)"
echo "  - $EGRESS_IP_ALLOCATION_FILE   (the pre-provisioned EIP allocation ID for the replica-side chart)"
echo
echo "Now deploy the replica-side Helm chart (global.streamingReplica=true) using:"
echo "  - global.streamingReplica=true"
echo "  - global.awsHelmRoleArn=${AWS_HELM_ROLE_ARN}"
echo "  - cb-postgres.streamingReplica.primaryHost=${PG_POD_IP}"
echo "  - cb-postgres.streamingReplica.wgConfig=\"\$(cat $PEER_CONF)\"  (endpoint already set to ${NODE_EXTERNAL_IP}:${WG_NODE_PORT})"
echo "  - cb-postgres.streamingReplica.replicatorPassword=\"\$(cat $REPL_PASSWORD_FILE)\""
echo "  - cb-postgres.streamingReplica.staticEgressIP.allocationId=${AWS_EGRESS_IP_ALLOCATION_ID}"
echo
read -r -p "Press Enter once the replica-side Helm chart is deployed and running (Ctrl+C to stop here and finish later with '$0 lockdown')... "

# ---------------------------------------------------------------------------
# 9. Lock down the firewall rule now that the replica exists
# ---------------------------------------------------------------------------
discover_aws_egress_ip_and_lockdown

info "All done - primary is configured, tunnel is up, and the firewall rule is locked down to the replica's egress IP."
