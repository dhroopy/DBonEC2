#!/usr/bin/env bash
set -Eeuo pipefail

# Restores a compressed mysqldump onto the running production container.
# Prefer a throwaway EC2 instance. Do not restore over production unless you
# intend to replace every database on this server.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"
load_env
require_cmd docker aws zstd
require_container
require_bucket

BACKUP_URI="${1:-}"
if [[ -z "$BACKUP_URI" ]]; then
  echo "Usage: $0 s3://bucket/path/mysql-full-....sql.zst" >&2
  exit 1
fi

TEMP="$(mktemp -d /tmp/mysql-restore.XXXXXX)"
trap 'rm -rf "$TEMP"' EXIT

log "WARNING: this replaces databases on ${MYSQL_CONTAINER}."
log "The safest workflow is: restore on a temporary EC2, validate, then cut over."
log "Downloading ${BACKUP_URI}"

aws s3 cp "$BACKUP_URI" "$TEMP/backup.sql.zst" --region "$AWS_REGION"
zstd -d "$TEMP/backup.sql.zst" -o "$TEMP/backup.sql"

if [[ -t 0 ]]; then
  read -r -p "Type RESTORE to continue: " CONFIRM
  if [[ "$CONFIRM" != "RESTORE" ]]; then
    log "Cancelled"
    exit 1
  fi
else
  die "refusing to restore without a TTY; run this interactively"
fi

log "Restoring into ${MYSQL_CONTAINER}"
docker exec -i "$MYSQL_CONTAINER" \
  mysql --defaults-extra-file="$ROOT_CNF" < "$TEMP/backup.sql"

log "Restore completed"
