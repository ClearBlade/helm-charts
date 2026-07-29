#!/bin/bash
#
# Sourced (not run) by replica-patches/*.sh scripts that need to authenticate
# against a specific AWS account by chaining a per-account CLI profile off a
# "base" profile, via that account's org cross-account access role.
#
# Callers must define info()/warn()/die() and set AWS_REGION, AWS_PROFILE,
# ACCOUNT_ID_INPUT, ORG_ACCESS_ROLE, and BASE_PROFILE (empty string for the
# ones that are optional) before calling resolve_aws_auth. On return,
# AWS_ARGS (array) and ACCOUNT_ID are set for the caller to use.

resolve_aws_auth() {
  if [[ -z "$AWS_PROFILE" ]]; then
    if [[ -z "$ACCOUNT_ID_INPUT" ]]; then
      read -r -p "AWS account ID to operate in (chains off the '${BASE_PROFILE}' profile): " ACCOUNT_ID_INPUT
    fi
    [[ "$ACCOUNT_ID_INPUT" =~ ^[0-9]{12}$ ]] || die "Account ID must be 12 digits, got: '$ACCOUNT_ID_INPUT'"

    # ~/.aws/config has no locking, and every invocation of this script (or
    # create-helm-role.sh) rewrites it via `aws configure set` a few lines
    # down. If two runs overlap, a list-profiles read here can land mid-write
    # and come back short even though the file is fine a moment later - so
    # retry a few times before concluding the profile is actually missing.
    base_profile_found=0
    for attempt in 1 2 3 4 5; do
      if aws configure list-profiles 2>/dev/null | grep -qx "$BASE_PROFILE"; then
        base_profile_found=1
        break
      fi
      if [[ "$attempt" -eq 1 ]]; then
        warn "'$BASE_PROFILE' profile not seen on first check - retrying in case ~/.aws/config is mid-write from a concurrent run..."
      fi
      sleep 1
    done
    [[ "$base_profile_found" -eq 1 ]] \
      || die "No '$BASE_PROFILE' AWS CLI profile found. Configure it first (aws configure --profile $BASE_PROFILE) with credentials that can assume $ORG_ACCESS_ROLE into member accounts."

    info "Configuring profile '$ACCOUNT_ID_INPUT' to assume $ORG_ACCESS_ROLE via '$BASE_PROFILE'..."
    aws configure set source_profile "$BASE_PROFILE" --profile "$ACCOUNT_ID_INPUT"
    aws configure set role_arn "arn:aws:iam::${ACCOUNT_ID_INPUT}:role/${ORG_ACCESS_ROLE}" --profile "$ACCOUNT_ID_INPUT"
    aws configure set region "$AWS_REGION" --profile "$ACCOUNT_ID_INPUT"

    AWS_PROFILE="$ACCOUNT_ID_INPUT"
  fi

  AWS_ARGS=(--region "$AWS_REGION" --profile "$AWS_PROFILE")

  info "Looking up account details..."
  ACCOUNT_ID=$(aws sts get-caller-identity "${AWS_ARGS[@]}" --query Account --output text) \
    || die "Could not authenticate as profile '$AWS_PROFILE' - check that '$BASE_PROFILE' can assume $ORG_ACCESS_ROLE in account ${ACCOUNT_ID_INPUT:-<unknown>}."
  info "Account: $ACCOUNT_ID"
  if [[ -n "$ACCOUNT_ID_INPUT" && "$ACCOUNT_ID" != "$ACCOUNT_ID_INPUT" ]]; then
    die "Authenticated as account $ACCOUNT_ID but expected $ACCOUNT_ID_INPUT - check the profile chaining."
  fi
}
