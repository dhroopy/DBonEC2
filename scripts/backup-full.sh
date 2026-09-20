#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"
load_env
require_cmd docker aws zstd jq sha256sum
require_container
require_bucket

DATE="$(date '+%Y-%m-%d_%H-%M-%S')"
YEAR="$(date '+%Y')"
MONTH="$(date '+%m')"
DAY="$(date '+%Y-%m-%d')"
BACKUP_NAME="mysql-full-${DATE}"
SQL_FILE="${BACKUP_DIR}/${BACKUP_NAME}.sql"
ZST_FILE="${SQL_FILE}.zst"
S3_KEY="${S3_PREFIX}/full/${YEAR}/${MONTH}/${BACKUP_NAME}.sql.zst"
MANIFEST_KEY="${S3_PREFIX}/manifests/${DAY}.json"
MANIFEST_FILE="${BACKUP_DIR}/${BACKUP_NAME}.json"

cleanup() {
  rm -f "$SQL_FILE" "$ZST_FILE" "$MANIFEST_FILE"
}
trap cleanup EXIT

log "========================================="
log "MySQL full backup started"
log "========================================="

log "Dumping all databases"
docker exec "$MYSQL_CONTAINER" \
  mysqldump --defaults-extra-file="$BACKUP_CNF" \
    --all-databases \
    --single-transaction \
    --routines \
    --events \
    --triggers \
    --hex-blob \
    --set-gtid-purged=ON \
    --source-data=2 \
    --flush-logs \
  > "$SQL_FILE"

[[ -s "$SQL_FILE" ]] || die "mysqldump produced an empty file"

BINLOG_FILE="$(
  grep -E '^-- CHANGE (REPLICATION SOURCE|MASTER) TO' "$SQL_FILE" \
    | head -n 1 \
    | sed -E "s/.*((SOURCE|MASTER)_LOG_FILE)='([^']+)'.*/\3/" || true
)"
BINLOG_POS="$(
  grep -E '^-- CHANGE (REPLICATION SOURCE|MASTER) TO' "$SQL_FILE" \
    | head -n 1 \
    | sed -E "s/.*((SOURCE|MASTER)_LOG_POS)=([0-9]+).*/\3/" || true
)"
GTID="$(
  grep -E 'SET @@GLOBAL.GTID_PURGED' "$SQL_FILE" \
    | head -n 1 \
    | sed -E "s/.*GTID_PURGED='?\{?([^';}]+)\}?'.*/\1/" || true
)"
if [[ -z "$GTID" ]]; then
  GTID="$(mysql_exec "$BACKUP_CNF" -N -e 'SELECT @@GLOBAL.gtid_executed;' || true)"
fi

MYSQL_VERSION="$(mysql_exec "$BACKUP_CNF" -N -e 'SELECT VERSION();')"

log "Compressing"
zstd -T0 -10 -f "$SQL_FILE" -o "$ZST_FILE"
rm -f "$SQL_FILE"

SHA="$(sha256_file "$ZST_FILE")"
SIZE="$(stat -c '%s' "$ZST_FILE" 2>/dev/null || stat -f '%z' "$ZST_FILE")"

jq -n \
  --arg backup_date "$(date --iso-8601=seconds)" \
  --arg mysql_version "$MYSQL_VERSION" \
  --arg binlog_file "${BINLOG_FILE:-}" \
  --arg binlog_position "${BINLOG_POS:-}" \
  --arg gtid "${GTID:-}" \
  --argjson backup_size "$SIZE" \
  --arg sha256 "$SHA" \
  --arg s3_key "$S3_KEY" \
  --arg s3_uri "s3://${S3_BUCKET}/${S3_KEY}" \
  '{
    backup_date: $backup_date,
    mysql_version: $mysql_version,
    binlog_file: $binlog_file,
    binlog_position: $binlog_position,
    gtid: $gtid,
    backup_size: $backup_size,
    sha256: $sha256,
    s3_key: $s3_key,
    s3_uri: $s3_uri
  }' > "$MANIFEST_FILE"

log "Uploading ${S3_KEY}"
aws s3 cp "$ZST_FILE" "s3://${S3_BUCKET}/${S3_KEY}" --region "$AWS_REGION" --storage-class STANDARD
aws s3api head-object --bucket "$S3_BUCKET" --key "$S3_KEY" --region "$AWS_REGION" >/dev/null \
  || die "S3 head-object failed for ${S3_KEY}"

log "Uploading manifest ${MANIFEST_KEY}"
aws s3 cp "$MANIFEST_FILE" "s3://${S3_BUCKET}/${MANIFEST_KEY}" --region "$AWS_REGION"
aws s3api head-object --bucket "$S3_BUCKET" --key "$MANIFEST_KEY" --region "$AWS_REGION" >/dev/null \
  || die "S3 head-object failed for ${MANIFEST_KEY}"

# Also store a 1:1 manifest next to the backup name for PITR.
UNIQUE_MANIFEST_KEY="${S3_PREFIX}/manifests/${BACKUP_NAME}.json"
aws s3 cp "$MANIFEST_FILE" "s3://${S3_BUCKET}/${UNIQUE_MANIFEST_KEY}" --region "$AWS_REGION"

log "Backup completed: s3://${S3_BUCKET}/${S3_KEY}"
log "sha256=${SHA} size=${SIZE} binlog=${BINLOG_FILE}:${BINLOG_POS}"
