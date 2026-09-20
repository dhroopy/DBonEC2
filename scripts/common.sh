#!/usr/bin/env bash
# Shared helpers for MySQL backup, restore, and health scripts.
# shellcheck disable=SC2034

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "ERROR: scripts require bash" >&2
  exit 1
fi

# When sourced from scripts/*.sh, this file lives in scripts/
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${COMMON_DIR}/.." && pwd)"

ENV_FILE="${BASE_DIR}/.env"
SECRETS_DIR="${BASE_DIR}/secrets"
ROOT_CNF="/run/mysql-secrets/root.cnf"
BACKUP_CNF="/run/mysql-secrets/backup.cnf"
HOST_ROOT_CNF="${SECRETS_DIR}/root.cnf"
HOST_BACKUP_CNF="${SECRETS_DIR}/backup.cnf"
STATE_DIR="${BASE_DIR}/state"
LOG_DIR="${BASE_DIR}/logs"
BACKUP_DIR="${BASE_DIR}/backups"
BINLOG_STATE="${STATE_DIR}/binlog-archive.state"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$BACKUP_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] $*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
  done
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die "missing ${ENV_FILE}"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  MYSQL_CONTAINER="${MYSQL_CONTAINER:-mysql84}"
  S3_PREFIX="${S3_PREFIX:-mysql}"
  AWS_REGION="${AWS_REGION:-ap-south-1}"
  TZ="${TZ:-Asia/Kolkata}"
  export TZ
}

mysql_exec() {
  local defaults="${1:-$BACKUP_CNF}"
  shift
  docker exec "$MYSQL_CONTAINER" mysql --defaults-extra-file="$defaults" "$@"
}

mysql_exec_root() {
  docker exec "$MYSQL_CONTAINER" mysql --defaults-extra-file="$ROOT_CNF" "$@"
}

container_running() {
  docker inspect -f '{{.State.Running}}' "$MYSQL_CONTAINER" 2>/dev/null | grep -qx true
}

require_container() {
  container_running || die "container ${MYSQL_CONTAINER} is not running"
}

s3_uri() {
  local key="$1"
  echo "s3://${S3_BUCKET}/${key}"
}

require_bucket() {
  [[ -n "${S3_BUCKET:-}" && "$S3_BUCKET" != "YOUR_BUCKET_NAME" ]] || die "S3_BUCKET is not set in .env"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

s3_head_ok() {
  local uri="$1"
  aws s3api head-object \
    --bucket "$S3_BUCKET" \
    --key "${uri#s3://${S3_BUCKET}/}" \
    --region "$AWS_REGION" >/dev/null 2>&1
}
