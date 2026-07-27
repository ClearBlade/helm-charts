#!/bin/bash
#
# Creates/updates the IAM role that backs global.awsHelmRoleArn - the single
# IRSA role the chart uses for both:
#   - clearblade-asm-read       (Secrets Manager access)
#   - clearblade-streaming-egress (static egress IP for streaming replicas,
#                                   unless --no-egress-ip is passed)
#
# Meant to be re-run per AWS account / EKS cluster / namespace combo. Safe to
# re-run against an existing role - it updates the trust and permissions
# policies in place rather than failing on "already exists".
#
# Usage:
#   ./create-helm-role.sh --region us-east-2 --cluster community --namespace community
#
# Options:
#   --region        AWS region the EKS cluster is in (required)
#   --cluster       EKS cluster name (required)
#   --namespace     Kubernetes namespace the chart is deployed into (required)
#   --role-name     IAM role name (default: clearblade-helm-<namespace>)
#   --profile       AWS CLI profile to use (default: whatever is already active)
#   --no-egress-ip  Omit the EC2 permissions - use this if the namespace never
#                   sets cb-postgres.streamingReplica.staticEgressIP.enabled
#   --out-file      Also write just the resulting role ARN (no other text) to
#                   this path - for chaining into other scripts
#   -y, --yes       Skip confirmation prompts (for scripting across many accounts)
#
# Prints the resulting role ARN - set that as global.awsHelmRoleArn in the
# chart's values for that account/namespace.

set -euo pipefail

info()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m!!\033[0m %s\n' "$1"; }
die()   { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

confirm() {
  local prompt="$1"
  $ASSUME_YES && return 0
  local reply
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not on PATH."
}

usage() {
  grep '^#' "$0" | sed -e 's/^#//' -e '1d'
  exit 1
}

# ---------------------------------------------------------------------------
# 1. Parse args
# ---------------------------------------------------------------------------
AWS_REGION=""
EKS_CLUSTER=""
NAMESPACE=""
ROLE_NAME=""
AWS_PROFILE=""
INCLUDE_EGRESS_IP=true
ASSUME_YES=false
OUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) AWS_REGION="$2"; shift 2 ;;
    --cluster) EKS_CLUSTER="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --role-name) ROLE_NAME="$2"; shift 2 ;;
    --profile) AWS_PROFILE="$2"; shift 2 ;;
    --no-egress-ip) INCLUDE_EGRESS_IP=false; shift ;;
    --out-file) OUT_FILE="$2"; shift 2 ;;
    -y|--yes) ASSUME_YES=true; shift ;;
    -h|--help) usage ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done

[[ -n "$AWS_REGION" ]] || die "--region is required."
[[ -n "$EKS_CLUSTER" ]] || die "--cluster is required."
[[ -n "$NAMESPACE" ]] || die "--namespace is required."
ROLE_NAME=${ROLE_NAME:-clearblade-helm-${NAMESPACE}}

for c in aws jq openssl; do require_cmd "$c"; done

AWS_ARGS=(--region "$AWS_REGION")
[[ -n "$AWS_PROFILE" ]] && AWS_ARGS+=(--profile "$AWS_PROFILE")

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ---------------------------------------------------------------------------
# 2. Account + cluster OIDC issuer
# ---------------------------------------------------------------------------
info "Looking up account and cluster details..."
ACCOUNT_ID=$(aws sts get-caller-identity "${AWS_ARGS[@]}" --query Account --output text)
info "Account: $ACCOUNT_ID"

ISSUER_URL=$(aws eks describe-cluster "${AWS_ARGS[@]}" --name "$EKS_CLUSTER" --query "cluster.identity.oidc.issuer" --output text)
[[ -n "$ISSUER_URL" && "$ISSUER_URL" != "None" ]] || die "Could not find OIDC issuer for cluster $EKS_CLUSTER in $AWS_REGION."
ISSUER_HOSTPATH=${ISSUER_URL#https://}
info "Cluster OIDC issuer: $ISSUER_HOSTPATH"

# ---------------------------------------------------------------------------
# 3. Ensure the cluster's OIDC provider is registered with IAM
#    (one-time per cluster - AWS needs to trust this issuer before any role's
#    trust policy referencing it means anything)
# ---------------------------------------------------------------------------
info "Checking for an existing IAM OIDC provider for this cluster..."
OIDC_PROVIDER_ARN=$(aws iam list-open-id-connect-providers "${AWS_ARGS[@]}" \
  --query "OpenIDConnectProviderList[].Arn" --output text \
  | tr '\t' '\n' | grep -F "$ISSUER_HOSTPATH" || true)

if [[ -n "$OIDC_PROVIDER_ARN" ]]; then
  info "OIDC provider already registered: $OIDC_PROVIDER_ARN"
else
  warn "No IAM OIDC provider found for $ISSUER_HOSTPATH - one is required before IRSA trust policies work."
  confirm "Create IAM OIDC provider for this cluster?" || die "Aborted before creating OIDC provider."

  THUMBPRINT=$(openssl s_client -servername "oidc.eks.${AWS_REGION}.amazonaws.com" \
      -connect "oidc.eks.${AWS_REGION}.amazonaws.com:443" -showcerts </dev/null 2>/dev/null \
    | openssl x509 -fingerprint -sha1 -noout | sed -e 's/^.*=//' -e 's/://g')
  [[ -n "$THUMBPRINT" ]] || die "Failed to fetch TLS thumbprint for the EKS OIDC endpoint."

  OIDC_PROVIDER_ARN=$(aws iam create-open-id-connect-provider "${AWS_ARGS[@]}" \
    --url "$ISSUER_URL" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "$THUMBPRINT" \
    --query "OpenIDConnectProviderArn" --output text)
  info "Created OIDC provider: $OIDC_PROVIDER_ARN"
fi

# ---------------------------------------------------------------------------
# 4. Trust policy - scoped to exactly the two service accounts this chart
#    creates in this namespace, nothing else in the account can assume it.
# ---------------------------------------------------------------------------
TRUST_POLICY_FILE="$WORK_DIR/trust-policy.json"
cat > "$TRUST_POLICY_FILE" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "${OIDC_PROVIDER_ARN}" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${ISSUER_HOSTPATH}:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "${ISSUER_HOSTPATH}:sub": [
            "system:serviceaccount:${NAMESPACE}:clearblade-asm-read",
            "system:serviceaccount:${NAMESPACE}:clearblade-streaming-egress"
          ]
        }
      }
    }
  ]
}
JSON

# ---------------------------------------------------------------------------
# 5. Permissions policy - Secrets Manager always, EC2 egress-IP unless opted
#    out. EC2's AllocateAddress/DescribeAddresses/AssociateAddress/
#    DescribeInstances don't support resource-level scoping, hence Resource "*"
#    on that statement - the Secrets Manager statement stays scoped to this
#    namespace's secrets.
# ---------------------------------------------------------------------------
SECRETS_ARN="arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT_ID}:secret:${NAMESPACE}_*"

PERMISSIONS_POLICY_FILE="$WORK_DIR/permissions-policy.json"
if $INCLUDE_EGRESS_IP; then
  cat > "$PERMISSIONS_POLICY_FILE" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SecretsManagerAccess",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:CreateSecret",
        "secretsmanager:PutSecretValue"
      ],
      "Resource": "${SECRETS_ARN}"
    },
    {
      "Sid": "StreamingReplicaEgressIP",
      "Effect": "Allow",
      "Action": [
        "ec2:AllocateAddress",
        "ec2:DescribeAddresses",
        "ec2:AssociateAddress",
        "ec2:DescribeInstances"
      ],
      "Resource": "*"
    }
  ]
}
JSON
else
  cat > "$PERMISSIONS_POLICY_FILE" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SecretsManagerAccess",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:CreateSecret",
        "secretsmanager:PutSecretValue"
      ],
      "Resource": "${SECRETS_ARN}"
    }
  ]
}
JSON
fi

# ---------------------------------------------------------------------------
# 6. Create or update the role
# ---------------------------------------------------------------------------
if aws iam get-role "${AWS_ARGS[@]}" --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  info "Role $ROLE_NAME already exists - updating its trust policy."
  confirm "Overwrite trust policy on existing role $ROLE_NAME?" || die "Aborted before updating trust policy."
  aws iam update-assume-role-policy "${AWS_ARGS[@]}" \
    --role-name "$ROLE_NAME" \
    --policy-document "file://$TRUST_POLICY_FILE"
else
  info "Creating role $ROLE_NAME..."
  confirm "Create IAM role $ROLE_NAME in account $ACCOUNT_ID?" || die "Aborted before creating role."
  aws iam create-role "${AWS_ARGS[@]}" \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$TRUST_POLICY_FILE" \
    --description "IRSA role for ClearBlade Helm chart (namespace: ${NAMESPACE}) - Secrets Manager$($INCLUDE_EGRESS_IP && echo ' + streaming replica egress IP')" \
    >/dev/null
fi

info "Attaching inline permissions policy (clearblade-helm-permissions)..."
aws iam put-role-policy "${AWS_ARGS[@]}" \
  --role-name "$ROLE_NAME" \
  --policy-name "clearblade-helm-permissions" \
  --policy-document "file://$PERMISSIONS_POLICY_FILE"

ROLE_ARN=$(aws iam get-role "${AWS_ARGS[@]}" --role-name "$ROLE_NAME" --query "Role.Arn" --output text)

if [[ -n "$OUT_FILE" ]]; then
  echo -n "$ROLE_ARN" > "$OUT_FILE"
fi

info "Done."
echo
echo "  Role ARN: $ROLE_ARN"
echo
echo "Set this in your values for account ${ACCOUNT_ID} / namespace ${NAMESPACE}:"
echo "  global.awsHelmRoleArn: ${ROLE_ARN}"
if ! $INCLUDE_EGRESS_IP; then
  warn "Created without EC2 egress-IP permissions. Also set cb-postgres.streamingReplica.staticEgressIP.enabled=false for this namespace, or the init container will fail with AccessDenied."
fi
