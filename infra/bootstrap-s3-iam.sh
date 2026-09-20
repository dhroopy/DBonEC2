#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Create the MySQL backup S3 bucket, IAM role, and instance profile.

Usage:
  ./infra/bootstrap-s3-iam.sh --bucket NAME [options]

Options:
  --bucket NAME              S3 bucket name (required)
  --region REGION            AWS region (default: ap-south-1)
  --role-name NAME           IAM role name (default: mysql-backup-ec2-role)
  --profile-name NAME        Instance profile name (default: mysql-backup-instance-profile)
  --instance-id ID           Optionally attach the instance profile to this EC2 instance
  --mysql-sg sg-...          MySQL instance security group (for 3306 ingress)
  --app-sg sg-...            Application security group allowed to reach 3306
  -h, --help                 Show this help

This script does not create the EC2 instance. Run it from a laptop/admin
shell that already has AWS credentials. No access keys are placed on EC2.
EOF
}

BUCKET=""
REGION="ap-south-1"
ROLE_NAME="mysql-backup-ec2-role"
PROFILE_NAME="mysql-backup-instance-profile"
INSTANCE_ID=""
MYSQL_SG=""
APP_SG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket) BUCKET="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --role-name) ROLE_NAME="${2:-}"; shift 2 ;;
    --profile-name) PROFILE_NAME="${2:-}"; shift 2 ;;
    --instance-id) INSTANCE_ID="${2:-}"; shift 2 ;;
    --mysql-sg) MYSQL_SG="${2:-}"; shift 2 ;;
    --app-sg) APP_SG="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$BUCKET" ]]; then
  echo "ERROR: --bucket is required" >&2
  usage
  exit 1
fi

for cmd in aws jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: $cmd is required on this machine" >&2
    exit 1
  fi
done

echo "==> Using region $REGION"
aws sts get-caller-identity --region "$REGION" >/dev/null
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

POLICY_DOC="$TMPDIR/iam-policy.json"
sed "s/YOUR_BUCKET_NAME/${BUCKET}/g" "$SCRIPT_DIR/iam-policy.json" > "$POLICY_DOC"

echo "==> S3 bucket s3://$BUCKET"
if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  echo "    Bucket already exists and is accessible"
else
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket \
      --bucket "$BUCKET" \
      --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=${REGION}"
  fi
  echo "    Created bucket"
fi

echo "==> Block public access"
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --region "$REGION" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "==> Versioning"
aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --region "$REGION" \
  --versioning-configuration Status=Enabled

echo "==> Default encryption (SSE-S3)"
aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --region "$REGION" \
  --server-side-encryption-configuration "file://${SCRIPT_DIR}/s3-encryption.json"

echo "==> Lifecycle (14-day expire for full backups and binlogs)"
aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET" \
  --region "$REGION" \
  --lifecycle-configuration "file://${SCRIPT_DIR}/s3-lifecycle.json"

echo "==> IAM role $ROLE_NAME"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "    Role already exists"
else
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://${SCRIPT_DIR}/ec2-trust-policy.json" \
    --description "EC2 role for MySQL backups to S3"
  echo "    Created role"
fi

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name mysql-backup-s3 \
  --policy-document "file://${POLICY_DOC}"
echo "    Inline S3 policy applied"

echo "==> Instance profile $PROFILE_NAME"
if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  echo "    Instance profile already exists"
else
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME"
  echo "    Created instance profile"
fi

EXISTING_ROLES="$(aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --query 'InstanceProfile.Roles[].RoleName' \
  --output text)"
if [[ "$EXISTING_ROLES" != *"$ROLE_NAME"* ]]; then
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$PROFILE_NAME" \
    --role-name "$ROLE_NAME"
  echo "    Associated role with instance profile"
  echo "    Waiting 10s for instance profile to propagate..."
  sleep 10
else
  echo "    Role already associated with instance profile"
fi

if [[ -n "$INSTANCE_ID" ]]; then
  echo "==> Attach instance profile to $INSTANCE_ID"
  CURRENT_PROFILE="$(aws ec2 describe-iam-instance-profile-associations \
    --filters "Name=instance-id,Values=${INSTANCE_ID}" \
    --region "$REGION" \
    --query 'IamInstanceProfileAssociations[?State==`associated`].IamInstanceProfile.Arn' \
    --output text || true)"
  if [[ -n "${CURRENT_PROFILE:-}" && "$CURRENT_PROFILE" != "None" ]]; then
    echo "    Instance already has a profile:"
    echo "      $CURRENT_PROFILE"
    echo "    Not replacing it. Attach ${PROFILE_NAME} in the console if this is wrong."
  else
    aws ec2 associate-iam-instance-profile \
      --region "$REGION" \
      --instance-id "$INSTANCE_ID" \
      --iam-instance-profile "Name=${PROFILE_NAME}"
    echo "    Attached ${PROFILE_NAME}"
  fi
fi

if [[ -n "$MYSQL_SG" && -n "$APP_SG" ]]; then
  echo "==> Allow TCP 3306 from $APP_SG to $MYSQL_SG"
  if aws ec2 authorize-security-group-ingress \
    --region "$REGION" \
    --group-id "$MYSQL_SG" \
    --protocol tcp \
    --port 3306 \
    --source-group "$APP_SG" 2>"$TMPDIR/sg.err"; then
    echo "    Ingress rule added"
  else
    if grep -qi 'already exists\|InvalidPermission.Duplicate' "$TMPDIR/sg.err"; then
      echo "    Ingress rule already exists"
    else
      cat "$TMPDIR/sg.err" >&2
      exit 1
    fi
  fi
fi

cat <<EOF

Bootstrap complete.

Account:          $ACCOUNT_ID
Bucket:           s3://$BUCKET
Region:           $REGION
IAM role:         $ROLE_NAME
Instance profile: $PROFILE_NAME

Do these three things if they are not already done:

  1. Attach instance profile "${PROFILE_NAME}" to the MySQL EC2 instance
     (skipped or already present if you passed --instance-id).

  2. Security group on the MySQL instance:
       inbound TCP 3306 from the application security group only
       (not 0.0.0.0/0).
       ${MYSQL_SG:+MySQL SG: $MYSQL_SG}
       ${APP_SG:+App SG:    $APP_SG}

  3. Outbound HTTPS (443) from the instance so it can reach S3.

On the instance after attach, confirm there are NO access keys:

  aws sts get-caller-identity
  aws s3 ls s3://${BUCKET}/

Then set S3_BUCKET=${BUCKET} in /opt/mysql-server/.env and run install.sh.
EOF
