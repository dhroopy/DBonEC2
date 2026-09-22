#!/usr/bin/env bash
set -Eeuo pipefail

# Download the latest full backup, verify compression + checksum, then restore
# into a throwaway MySQL container (128M buffer pool) and run sanity queries.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"
load_env
require_cmd docker aws zstd jq sha256sum openssl
require_bucket

VERIFY_NAME="mysql-verify-tmp"
TEMP="$(mktemp -d /tmp/mysql-verify.XXXXXX)"
VERIFY_PASS="$(openssl rand -hex 16)"

cleanup() {
  docker rm -f "$VERIFY_NAME" >/dev/null 2>&1 || true
  rm -rf "$TEMP"
}
trap cleanup EXIT

log "Finding latest full backup"
if ! LATEST_KEY="$(s3_latest_key "${S3_PREFIX}/full/" ".sql.zst")"; then
  die "no full backups found under s3://${S3_BUCKET}/${S3_PREFIX}/full/"
fi

log "Latest backup: s3://${S3_BUCKET}/${LATEST_KEY}"
aws s3 cp "s3://${S3_BUCKET}/${LATEST_KEY}" "$TEMP/backup.sql.zst" --region "$AWS_REGION"

log "Testing zstd integrity"
zstd -t "$TEMP/backup.sql.zst"

BASE="$(basename "$LATEST_KEY" .sql.zst)"
MANIFEST_KEY="${S3_PREFIX}/manifests/${BASE}.json"
if aws s3 cp "s3://${S3_BUCKET}/${MANIFEST_KEY}" "$TEMP/manifest.json" --region "$AWS_REGION"; then
  EXPECTED="$(jq -r '.sha256' "$TEMP/manifest.json")"
  ACTUAL="$(sha256_file "$TEMP/backup.sql.zst")"
  if [[ -n "$EXPECTED" && "$EXPECTED" != "null" && "$EXPECTED" != "$ACTUAL" ]]; then
    die "sha256 mismatch: manifest=${EXPECTED} file=${ACTUAL}"
  fi
  log "Checksum matches manifest (${ACTUAL})"
else
  log "WARNING: no per-backup manifest at ${MANIFEST_KEY}; skipped checksum compare"
fi

log "Starting throwaway MySQL (innodb-buffer-pool-size=128M)"
docker run -d \
  --name "$VERIFY_NAME" \
  -e MYSQL_ROOT_PASSWORD="$VERIFY_PASS" \
  mysql:8.4 \
  --innodb-buffer-pool-size=128M \
  --skip-name-resolve \
  --max-connections=20 >/dev/null

for _ in $(seq 1 60); do
  if docker exec "$VERIFY_NAME" mysqladmin ping -h 127.0.0.1 -uroot -p"$VERIFY_PASS" --silent >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
docker exec "$VERIFY_NAME" mysqladmin ping -h 127.0.0.1 -uroot -p"$VERIFY_PASS" --silent >/dev/null \
  || die "verify container did not become ready"

log "Decompressing and restoring into ${VERIFY_NAME}"
zstd -d "$TEMP/backup.sql.zst" -o "$TEMP/backup.sql"
docker exec -i "$VERIFY_NAME" mysql -uroot -p"$VERIFY_PASS" < "$TEMP/backup.sql"

log "Validation queries"
docker exec "$VERIFY_NAME" mysql -uroot -p"$VERIFY_PASS" -e "SHOW DATABASES;"
docker exec "$VERIFY_NAME" mysql -uroot -p"$VERIFY_PASS" -N -e "
SELECT table_schema, COUNT(*) AS tables
FROM information_schema.tables
WHERE table_schema NOT IN ('information_schema','performance_schema','sys')
GROUP BY table_schema;
"

log "Backup verification succeeded for s3://${S3_BUCKET}/${LATEST_KEY}"
