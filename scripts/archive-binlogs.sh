#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"
load_env
require_cmd docker aws zstd
require_container
require_bucket

TMP_DIR="${BACKUP_DIR}/binlogs"
mkdir -p "$TMP_DIR"
YEAR="$(date '+%Y')"
MONTH="$(date '+%m')"
LIST_FILE="${TMP_DIR}/binlog-list.txt"

log "Rotating binary log"
mysql_exec "$BACKUP_CNF" -e "FLUSH BINARY LOGS;"

mysql_exec "$BACKUP_CNF" -N -e "SHOW BINARY LOGS;" > "$LIST_FILE"
[[ -s "$LIST_FILE" ]] || die "SHOW BINARY LOGS returned no rows"

mapfile -t LINES < "$LIST_FILE"
ACTIVE_LINE="${LINES[-1]}"
ACTIVE_BINLOG="$(awk '{print $1}' <<<"$ACTIVE_LINE")"
LAST_UPLOADED=""
if [[ -f "$BINLOG_STATE" ]]; then
  # shellcheck disable=SC1090
  source "$BINLOG_STATE"
  LAST_UPLOADED="${LAST_UPLOADED:-}"
fi

log "Active binary log: ${ACTIVE_BINLOG}"
log "Last uploaded: ${LAST_UPLOADED:-<none>}"

uploaded_any=0
for line in "${LINES[@]}"; do
  BINLOG="$(awk '{print $1}' <<<"$line")"
  [[ -n "$BINLOG" ]] || continue
  if [[ "$BINLOG" == "$ACTIVE_BINLOG" ]]; then
    log "Skipping active log ${BINLOG}"
    continue
  fi
  if [[ -n "$LAST_UPLOADED" && "$BINLOG" < "$LAST_UPLOADED" ]]; then
    continue
  fi
  if [[ -n "$LAST_UPLOADED" && "$BINLOG" == "$LAST_UPLOADED" ]]; then
    continue
  fi

  S3_KEY="${S3_PREFIX}/binlogs/${YEAR}/${MONTH}/${BINLOG}.zst"
  if aws s3api head-object --bucket "$S3_BUCKET" --key "$S3_KEY" --region "$AWS_REGION" >/dev/null 2>&1; then
    log "Already in S3: ${S3_KEY}"
    LAST_UPLOADED="$BINLOG"
    printf 'LAST_UPLOADED=%q\n' "$LAST_UPLOADED" > "$BINLOG_STATE"
    continue
  fi

  log "Archiving ${BINLOG}"
  docker cp "${MYSQL_CONTAINER}:/var/lib/mysql/${BINLOG}" "${TMP_DIR}/${BINLOG}"
  zstd -T0 -10 -f "${TMP_DIR}/${BINLOG}" -o "${TMP_DIR}/${BINLOG}.zst"
  aws s3 cp "${TMP_DIR}/${BINLOG}.zst" "s3://${S3_BUCKET}/${S3_KEY}" --region "$AWS_REGION"
  aws s3api head-object --bucket "$S3_BUCKET" --key "$S3_KEY" --region "$AWS_REGION" >/dev/null \
    || die "S3 head-object failed for ${S3_KEY}"

  rm -f "${TMP_DIR}/${BINLOG}" "${TMP_DIR}/${BINLOG}.zst"
  LAST_UPLOADED="$BINLOG"
  printf 'LAST_UPLOADED=%q\n' "$LAST_UPLOADED" > "$BINLOG_STATE"
  uploaded_any=1
  log "Uploaded ${S3_KEY}"
done

rm -f "$LIST_FILE"
if [[ "$uploaded_any" -eq 0 ]]; then
  log "No new completed binary logs to archive"
else
  log "Binary log archive completed (cursor=${LAST_UPLOADED})"
fi
