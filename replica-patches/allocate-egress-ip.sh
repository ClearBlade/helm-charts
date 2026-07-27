#!/bin/bash
#
# Pre-provisions the static Elastic IP used by cb-postgres's streaming
# replica proxy, so it's a real piece of infrastructure the operator owns -
# NOT something the chart allocates/deallocates on install/uninstall. The
# chart only ever ASSOCIATES this IP with whatever node the proxy pod lands
# on (see create-helm-role.sh, which grants exactly that - no
# AllocateAddress/CreateTags).
#
# Idempotent: if an EIP already exists with the given tag, it's reused and
# printed as-is - nothing is allocated twice.
#
# Usage:
#   ./allocate-egress-ip.sh --region us-east-2 --namespace community
#
# Authenticates the same way as create-helm-role.sh: chains a per-account CLI
# profile off "base" via the account's org access role, unless --profile is
# passed.
#
# Options:
#   --region            AWS region to allocate the EIP in (required)
#   --namespace          Kubernetes namespace this EIP is for - used to name
#                        the tag if --tag-name isn't given (required)
#   --tag-name           Name tag for the EIP (default: streaming-replica-egress-<namespace>)
#   --account-id         AWS account ID to operate in - creates/reuses an AWS CLI
#                        profile of this name, chained off "base". Prompted for
#                        if omitted.
#   --org-access-role    Role name to assume in the target account (default:
#                        OrganizationAccountAccessRole)
#   --base-profile       Name of the AWS CLI profile to chain off of (default: base)
#   --profile            Use this AWS CLI profile directly instead of the
#                        account-id/base chaining above
#   --out-file           Also write just the resulting allocation ID (no other
#                        text) to this path - for chaining into other scripts
#   -y, --yes            Skip confirmation prompts (for scripting across many accounts)
#
# Prints the resulting allocation ID and public IP - set the allocation ID as
# cb-postgres.streamingReplica.staticEgressIP.allocationId in the chart's
# values for that account/namespace.

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
NAMESPACE=""
TAG_NAME=""
AWS_PROFILE=""
ACCOUNT_ID_INPUT=""
ORG_ACCESS_ROLE="OrganizationAccountAccessRole"
BASE_PROFILE="base"
ASSUME_YES=false
OUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) AWS_REGION="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --tag-name) TAG_NAME="$2"; shift 2 ;;
    --account-id) ACCOUNT_ID_INPUT="$2"; shift 2 ;;
    --org-access-role) ORG_ACCESS_ROLE="$2"; shift 2 ;;
    --base-profile) BASE_PROFILE="$2"; shift 2 ;;
    --profile) AWS_PROFILE="$2"; shift 2 ;;
    --out-file) OUT_FILE="$2"; shift 2 ;;
    -y|--yes) ASSUME_YES=true; shift ;;
    -h|--help) usage ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done

[[ -n "$AWS_REGION" ]] || die "--region is required."
[[ -n "$NAMESPACE" ]] || die "--namespace is required."
TAG_NAME=${TAG_NAME:-streaming-replica-egress-${NAMESPACE}}

require_cmd aws

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/aws-org-auth.sh"

# ---------------------------------------------------------------------------
# 2. AWS auth - chain a per-account profile off "base", unless --profile
#    was passed to bypass this entirely.
# ---------------------------------------------------------------------------
resolve_aws_auth

# ---------------------------------------------------------------------------
# 3. Reuse an existing EIP tagged for this namespace, or allocate one.
# ---------------------------------------------------------------------------
info "Checking for an existing Elastic IP tagged '${TAG_NAME}'..."
EXISTING=$(aws ec2 describe-addresses "${AWS_ARGS[@]}" \
  --filters "Name=tag:Name,Values=${TAG_NAME}" \
  --query "Addresses[0].[AllocationId,PublicIp]" --output text 2>/dev/null || echo "")

if [[ -n "$EXISTING" && "$EXISTING" != "None"* ]]; then
  ALLOCATION_ID=$(awk '{print $1}' <<<"$EXISTING")
  PUBLIC_IP=$(awk '{print $2}' <<<"$EXISTING")
  info "Found existing EIP: $ALLOCATION_ID ($PUBLIC_IP) - reusing it, not allocating a new one."
else
  info "No existing EIP tagged '${TAG_NAME}' - allocating a new one."
  confirm "Allocate a new Elastic IP tagged '${TAG_NAME}' in account ${ACCOUNT_ID}?" || die "Aborted before allocating EIP."

  read -r ALLOCATION_ID PUBLIC_IP <<<"$(aws ec2 allocate-address "${AWS_ARGS[@]}" \
    --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${TAG_NAME}}]" \
    --query "[AllocationId,PublicIp]" --output text)"
  info "Allocated: $ALLOCATION_ID ($PUBLIC_IP)"
fi

if [[ -n "$OUT_FILE" ]]; then
  echo -n "$ALLOCATION_ID" > "$OUT_FILE"
fi

info "Done."
echo
echo "  Allocation ID: $ALLOCATION_ID"
echo "  Public IP:     $PUBLIC_IP"
echo
echo "Set this in your values for account ${ACCOUNT_ID} / namespace ${NAMESPACE}:"
echo "  cb-postgres.streamingReplica.staticEgressIP.allocationId: ${ALLOCATION_ID}"
warn "This EIP is now yours to manage - it will NOT be released by 'helm uninstall'. Release it yourself with 'aws ec2 release-address --allocation-id ${ALLOCATION_ID}' once you no longer need it (after disassociating, if still attached)."
