#!/usr/bin/env bash
set -Eeuo pipefail

# Point-in-time restore onto the running MySQL container.
# Prefer a throwaway instance. Uses the full backup's binlog coordinates,
# then replays subsequent archived binary logs with mysqlbinlog.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"
load_env
require_cmd docker aws zstd jq
require_container
require_bucket

BACKUP_URI=""
STOP_DATETIME=""
MANIFEST_URI=""

usage() {
  cat <<'EOF'
Usage:
  restore-pitr.sh --backup s3://bucket/mysql/full/.../file.sql.zst \
                  --stop-datetime "YYYY-MM-DD HH:MM:SS" \
                  [--manifest s3://bucket/mysql/manifests/....json]

Timezone for --stop-datetime is the server timezone (Asia/Kolkata / +05:30).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup) BACKUP_URI="${2:-}"; shift 2 ;;
    --stop-datetime) STOP_DATETIME="${2:-}"; shift 2 ;;
    --manifest) MANIFEST_URI="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$BACKUP_URI" ]] || { usage; die "--backup is required"; }
[[ -n "$STOP_DATETIME" ]] || { usage; die "--stop-datetime is required"; }

TEMP="$(mktemp -d /tmp/mysql-pitr.XXXXXX)"
trap 'rm -rf "$TEMP"; docker exec "$MYSQL_CONTAINER" rm -rf /tmp/mysql-pitr 2>/dev/null || true' EXIT

if [[ -z "$MANIFEST_URI" ]]; then
  base="$(basename "$BACKUP_URI" .sql.zst)"
  MANIFEST_URI="s3://${S3_BUCKET}/${S3_PREFIX}/manifests/${base}.json"
fi

log "WARNING: PITR restore replaces databases on ${MYSQL_CONTAINER}."
if [[ -t 0 ]]; then
  read -r -p "Type RESTORE to continue: " CONFIRM
  if [[ "$CONFIRM" != "RESTORE" ]]; then
    log "Cancelled"
    exit 1
  fi
else
  die "refusing to restore without a TTY; run this interactively"
fi

log "Fetching manifest ${MANIFEST_URI}"
if ! aws s3 cp "$MANIFEST_URI" "$TEMP/manifest.json" --region "$AWS_REGION"; then
  day_manifest="s3://${S3_BUCKET}/${S3_PREFIX}/manifests/$(date -d "$STOP_DATETIME" '+%Y-%m-%d' 2>/dev/null || echo).json"
  log "Named manifest missing; trying ${day_manifest}"
  aws s3 cp "$day_manifest" "$TEMP/manifest.json" --region "$AWS_REGION"
fi

BINLOG_FILE="$(jq -r '.binlog_file' "$TEMP/manifest.json")"
BINLOG_POS="$(jq -r '.binlog_position' "$TEMP/manifest.json")"
[[ -n "$BINLOG_FILE" && "$BINLOG_FILE" != "null" ]] || die "manifest is missing binlog_file"
[[ -n "$BINLOG_POS" && "$BINLOG_POS" != "null" ]] || die "manifest is missing binlog_position"

log "Restoring full backup ${BACKUP_URI}"
aws s3 cp "$BACKUP_URI" "$TEMP/backup.sql.zst" --region "$AWS_REGION"
zstd -d "$TEMP/backup.sql.zst" -o "$TEMP/backup.sql"
docker exec -i "$MYSQL_CONTAINER" \
  mysql --defaults-extra-file="$ROOT_CNF" < "$TEMP/backup.sql"

log "Listing archived binlogs at or after ${BINLOG_FILE}"
mkdir -p "$TEMP/binlogs"
mapfile -t KEYS < <(
  aws s3api list-objects-v2 \
    --bucket "$S3_BUCKET" \
    --prefix "${S3_PREFIX}/binlogs/" \
    --region "$AWS_REGION" \
    --query 'Contents[].Key' \
    --output text | tr '\t' '\n' | sed '/^$/d;/^None$/d' | sort
)

BINLOG_FILES=()
for key in "${KEYS[@]}"; do
  [[ -n "$key" && "$key" != "None" ]] || continue
  name="$(basename "$key" .zst)"
  if [[ "$name" < "$BINLOG_FILE" ]]; then
    continue
  fi
  log "Downloading ${key}"
  aws s3 cp "s3://${S3_BUCKET}/${key}" "$TEMP/binlogs/${name}.zst" --region "$AWS_REGION"
  zstd -d -f "$TEMP/binlogs/${name}.zst" -o "$TEMP/binlogs/${name}"
  BINLOG_FILES+=("$name")
done

if [[ ${#BINLOG_FILES[@]} -eq 0 ]]; then
  die "no archived binlogs found at or after ${BINLOG_FILE}"
fi

docker exec "$MYSQL_CONTAINER" mkdir -p /tmp/mysql-pitr
CONTAINER_FILES=()
for name in "${BINLOG_FILES[@]}"; do
  docker cp "$TEMP/binlogs/${name}" "${MYSQL_CONTAINER}:/tmp/mysql-pitr/${name}"
  CONTAINER_FILES+=("/tmp/mysql-pitr/${name}")
done

log "Replaying binlogs from ${BINLOG_FILE} pos ${BINLOG_POS} until ${STOP_DATETIME}"
docker exec "$MYSQL_CONTAINER" \
  mysqlbinlog \
    --start-position="$BINLOG_POS" \
    --stop-datetime="$STOP_DATETIME" \
    "${CONTAINER_FILES[@]}" \
  | docker exec -i "$MYSQL_CONTAINER" mysql --defaults-extra-file="$ROOT_CNF"

log "PITR restore completed"
