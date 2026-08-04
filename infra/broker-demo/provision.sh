#!/usr/bin/env bash
#
# NovaPay — scoped-token broker demo: REAL AWS provisioner.
#
# Unlike ../main.tf (deliberately poisoned, "do not apply"), THIS provisions a
# small, safe, least-privilege footprint so the monitor→enforce scenario can be
# tested against real AWS + CloudTrail:
#
#   • one PRIVATE, encrypted S3 bucket
#   • one in-scope object   flagged/txn-88431.json  (the flagged txn the fraud
#                                                     agent must read — card+PII)
#   • one OUT-OF-scope decoy flagged/txn-99999.json (proves the scope boundary:
#                                                     the scoped credential must
#                                                     be DENIED on this one)
#   • one IAM role the Unveilr broker assumes (sts:AssumeRole), permitting
#     s3:GetObject on flagged/* — the broker's inline SESSION policy narrows that
#     to the single in-scope object, so the decoy read fails with AccessDenied.
#   • (optional --with-cloudtrail) a trail with S3 data events on the bucket so
#     GetObject success + denial appear in LookupEvents for correlation.
#
# The role permits the SUPERSET; the broker's per-request session policy is what
# makes each issued credential bounded. That intersection is the whole point.
#
# Usage:
#   ./provision.sh up   [--region us-east-1] [--with-cloudtrail]
#   ./provision.sh down [--region us-east-1]        # teardown everything
#
# Requires: awscli v2 (authenticated), jq. Costs: S3 is pennies; CloudTrail data
# events are billed per event — only enabled with --with-cloudtrail.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
WITH_CT="false"
CMD="${1:-up}"; shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --with-cloudtrail) WITH_CT="true"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="novapay-broker-demo-${ACCOUNT}"
LOGS_BUCKET="novapay-broker-demo-trail-${ACCOUNT}"
ROLE="novapay-broker-target"
TRAIL="novapay-broker-demo-trail"
IN_SCOPE_KEY="flagged/txn-88431.json"
DECOY_KEY="flagged/txn-99999.json"
OBJECT_ARN="arn:aws:s3:::${BUCKET}/${IN_SCOPE_KEY}"
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

say() { printf '\033[1;36m▸ %s\033[0m\n' "$*"; }

make_bucket() { # $1 = bucket name
  if aws s3api head-bucket --bucket "$1" 2>/dev/null; then return 0; fi
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$1" --region us-east-1 >/dev/null
  else
    aws s3api create-bucket --bucket "$1" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "$1" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption --bucket "$1" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
}

up() {
  say "Account ${ACCOUNT} · region ${REGION}"

  say "S3 bucket ${BUCKET} (private, encrypted)"
  make_bucket "$BUCKET"

  say "Seed the flagged transaction (in-scope) + a decoy (out-of-scope)"
  cat > "$TMP/txn.json" <<'JSON'
{ "id": "txn-88431", "status": "flagged", "amount": 9400, "currency": "USD",
  "card": "4111111111111111", "cardholder": "Dana Ruiz", "ssn": "512-84-2301",
  "reason": "velocity + geo mismatch", "queue": "manual-review" }
JSON
  cat > "$TMP/decoy.json" <<'JSON'
{ "id": "txn-99999", "status": "flagged", "note": "OUT OF SCOPE — reading this with the scoped credential MUST be denied" }
JSON
  aws s3api put-object --bucket "$BUCKET" --key "$IN_SCOPE_KEY" --body "$TMP/txn.json" \
    --content-type application/json >/dev/null
  aws s3api put-object --bucket "$BUCKET" --key "$DECOY_KEY" --body "$TMP/decoy.json" \
    --content-type application/json >/dev/null

  say "IAM role ${ROLE} the broker assumes (trust: account ${ACCOUNT})"
  cat > "$TMP/trust.json" <<JSON
{ "Version": "2012-10-17", "Statement": [
  { "Effect": "Allow", "Principal": { "AWS": "arn:aws:iam::${ACCOUNT}:root" },
    "Action": "sts:AssumeRole" } ] }
JSON
  # permission policy = SUPERSET (flagged/*); the session policy narrows per call.
  cat > "$TMP/perm.json" <<JSON
{ "Version": "2012-10-17", "Statement": [
  { "Sid": "ReadFlagged", "Effect": "Allow", "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${BUCKET}/flagged/*" } ] }
JSON
  if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$ROLE" \
      --policy-document "file://$TMP/trust.json"
  else
    aws iam create-role --role-name "$ROLE" \
      --assume-role-policy-document "file://$TMP/trust.json" \
      --description "NovaPay scoped-token broker demo target (Unveilr)" >/dev/null
  fi
  aws iam put-role-policy --role-name "$ROLE" --policy-name read-flagged \
    --policy-document "file://$TMP/perm.json"

  if [ "$WITH_CT" = "true" ]; then
    say "CloudTrail ${TRAIL} with S3 data events on ${BUCKET} (billed per event)"
    make_bucket "$LOGS_BUCKET"
    cat > "$TMP/ctpol.json" <<JSON
{ "Version": "2012-10-17", "Statement": [
  { "Sid": "AWSCloudTrailAclCheck", "Effect": "Allow",
    "Principal": {"Service": "cloudtrail.amazonaws.com"},
    "Action": "s3:GetBucketAcl", "Resource": "arn:aws:s3:::${LOGS_BUCKET}" },
  { "Sid": "AWSCloudTrailWrite", "Effect": "Allow",
    "Principal": {"Service": "cloudtrail.amazonaws.com"},
    "Action": "s3:PutObject",
    "Resource": "arn:aws:s3:::${LOGS_BUCKET}/AWSLogs/${ACCOUNT}/*",
    "Condition": {"StringEquals": {"s3:x-amz-acl": "bucket-owner-full-control"}} } ] }
JSON
    aws s3api put-bucket-policy --bucket "$LOGS_BUCKET" --policy "file://$TMP/ctpol.json"
    if ! aws cloudtrail get-trail --name "$TRAIL" >/dev/null 2>&1; then
      aws cloudtrail create-trail --name "$TRAIL" --s3-bucket-name "$LOGS_BUCKET" >/dev/null
    fi
    aws cloudtrail put-event-selectors --trail-name "$TRAIL" --event-selectors \
      "[{\"ReadWriteType\":\"All\",\"IncludeManagementEvents\":true,\"DataResources\":[{\"Type\":\"AWS::S3::Object\",\"Values\":[\"arn:aws:s3:::${BUCKET}/\"]}]}]" >/dev/null
    aws cloudtrail start-logging --name "$TRAIL"
    echo "  (data events take ~5–15 min to appear in LookupEvents)"
  fi

  cat <<OUT

$(printf '\033[1;32m✓ provisioned\033[0m')

  Paste these into the Unveilr API environment + the harness:

    export BROKER_ENABLED=true
    export BROKER_ROLE_ARN="${ROLE_ARN}"
    export AWS_REGION="${REGION}"
    export CLOUDTRAIL_ENABLED=$([ "$WITH_CT" = "true" ] && echo true || echo false)

    export BROKER_BUCKET="${BUCKET}"
    export BROKER_OBJECT_KEY="${IN_SCOPE_KEY}"
    export BROKER_DECOY_KEY="${DECOY_KEY}"
    export BROKER_OBJECT_ARN="${OBJECT_ARN}"

  Then follow ../../SCENARIO_BROKER_AWS.md from step 2.
OUT
}

down() {
  say "Tearing down"
  aws s3 rm "s3://${BUCKET}" --recursive >/dev/null 2>&1 || true
  aws s3api delete-bucket --bucket "$BUCKET" 2>/dev/null || true
  aws iam delete-role-policy --role-name "$ROLE" --policy-name read-flagged 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE" 2>/dev/null || true
  aws cloudtrail stop-logging --name "$TRAIL" 2>/dev/null || true
  aws cloudtrail delete-trail --name "$TRAIL" 2>/dev/null || true
  aws s3 rm "s3://${LOGS_BUCKET}" --recursive >/dev/null 2>&1 || true
  aws s3api delete-bucket --bucket "$LOGS_BUCKET" 2>/dev/null || true
  printf '\033[1;32m✓ torn down\033[0m\n'
}

case "$CMD" in
  up) up ;;
  down) down ;;
  *) echo "usage: $0 up|down [--region R] [--with-cloudtrail]" >&2; exit 2 ;;
esac
