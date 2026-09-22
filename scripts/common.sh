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
  # AWS CLI v2 pages output into `less` unless this is empty.
  export AWS_PAGER=""
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

# List object keys under a prefix using `aws s3 ls` (not s3api list-objects-v2).
# Apt awscli v1 on Python 3.14 crashes list-objects-v2 with "badly formed help string".
s3_list_keys() {
  local prefix="$1"
  aws s3 ls "s3://${S3_BUCKET}/${prefix}" --recursive --region "$AWS_REGION" \
    | awk 'NF >= 4 {
        k = $4
        for (i = 5; i <= NF; i++) k = k " " $i
        print k
      }'
}

# Print the newest object key under prefix, optionally ending with suffix (e.g. .sql.zst).
s3_latest_key() {
  local prefix="$1"
  local suffix="${2:-}"
  local listing key
  listing="$(aws s3 ls "s3://${S3_BUCKET}/${prefix}" --recursive --region "$AWS_REGION")"
  key="$(
    printf '%s\n' "$listing" \
      | awk -v suffix="$suffix" '
          NF >= 4 {
            k = $4
            for (i = 5; i <= NF; i++) k = k " " $i
            if (suffix == "" || substr(k, length(k) - length(suffix) + 1) == suffix) {
              print $1 " " $2 "\t" k
            }
          }
        ' \
      | sort \
      | tail -n 1 \
      | cut -f2-
  )"
  [[ -n "$key" && "$key" != "None" ]] || return 1
  printf '%s\n' "$key"
}
