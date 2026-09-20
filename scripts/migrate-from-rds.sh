#!/usr/bin/env bash
set -Eeuo pipefail

# Dump non-system databases from RDS and restore them into the local mysql84
# container. Uses --set-gtid-purged=OFF so RDS GTID history is not imported.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"
load_env
require_cmd docker zstd
require_container

usage() {
  cat <<'EOF'
Usage:
  migrate-from-rds.sh --host HOST --user USER [--password PASS] [--port 3306]
                      [--databases db1,db2]

If --databases is omitted, all non-system schemas on RDS are dumped.
Do not use this to copy RDS mysql.* system tables onto EC2.
EOF
}

RDS_HOST="${RDS_HOST:-}"
RDS_USER="${RDS_USER:-}"
RDS_PASSWORD="${RDS_PASSWORD:-}"
RDS_PORT="${RDS_PORT:-3306}"
DATABASES_CSV="${RDS_DATABASES:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) RDS_HOST="${2:-}"; shift 2 ;;
    --user) RDS_USER="${2:-}"; shift 2 ;;
    --password) RDS_PASSWORD="${2:-}"; shift 2 ;;
    --port) RDS_PORT="${2:-}"; shift 2 ;;
    --databases) DATABASES_CSV="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$RDS_HOST" ]] || { usage; die "--host is required"; }
[[ -n "$RDS_USER" ]] || { usage; die "--user is required"; }
if [[ -z "$RDS_PASSWORD" ]]; then
  read -r -s -p "RDS password: " RDS_PASSWORD
  echo
fi

CNF="$(mktemp)"
chmod 600 "$CNF"
DUMP_ZST="${BACKUP_DIR}/rds-migration-$(date '+%Y-%m-%d_%H-%M-%S').sql.zst"
trap 'rm -f "$CNF"' EXIT
cat > "$CNF" <<EOF
[client]
host=${RDS_HOST}
port=${RDS_PORT}
user=${RDS_USER}
password=${RDS_PASSWORD}
EOF

mysql_rds() {
  docker run --rm \
    -v "$CNF:/run/rds.cnf:ro" \
    mysql:8.4 \
    mysql --defaults-extra-file=/run/rds.cnf "$@"
}

log "Discovering databases on ${RDS_HOST}"
if [[ -z "$DATABASES_CSV" ]]; then
  DATABASES_CSV="$(
    mysql_rds -N -e "SHOW DATABASES;" \
      | grep -vE '^(information_schema|performance_schema|mysql|sys)$' \
      | paste -sd, -
  )"
fi
DATABASES_CSV="${DATABASES_CSV// /}"
[[ -n "$DATABASES_CSV" ]] || die "no databases to migrate"
IFS=',' read -r -a DBS <<<"$DATABASES_CSV"
log "Will migrate: ${DBS[*]}"

log "Dumping RDS (gtid-purged=OFF) to ${DUMP_ZST}"
docker run --rm \
  -v "$CNF:/run/rds.cnf:ro" \
  mysql:8.4 \
  mysqldump --defaults-extra-file=/run/rds.cnf \
    --single-transaction \
    --routines \
    --events \
    --triggers \
    --hex-blob \
    --set-gtid-purged=OFF \
    --databases "${DBS[@]}" \
  | zstd -T0 -10 -o "$DUMP_ZST"

[[ -s "$DUMP_ZST" ]] || die "migration dump is empty"
log "Dump size: $(ls -lh "$DUMP_ZST" | awk '{print $5}')"

log "Restoring into ${MYSQL_CONTAINER}"
zstd -d -c "$DUMP_ZST" | docker exec -i "$MYSQL_CONTAINER" \
  mysql --defaults-extra-file="$ROOT_CNF"

log "Migration restore completed. Keep the dump at ${DUMP_ZST} until cutover is proven."
log "Next: point the application at this instance, then keep RDS running for several days."
