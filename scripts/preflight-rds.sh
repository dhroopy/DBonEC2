#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Check RDS MySQL compatibility before migrating to EC2 MySQL 8.4.

Usage:
  preflight-rds.sh --host HOST --user USER [--password PASS] [--port 3306]

Password can also come from RDS_PASSWORD. If omitted, you will be prompted.
EOF
}

RDS_HOST="${RDS_HOST:-}"
RDS_USER="${RDS_USER:-}"
RDS_PASSWORD="${RDS_PASSWORD:-}"
RDS_PORT="${RDS_PORT:-3306}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) RDS_HOST="${2:-}"; shift 2 ;;
    --user) RDS_USER="${2:-}"; shift 2 ;;
    --password) RDS_PASSWORD="${2:-}"; shift 2 ;;
    --port) RDS_PORT="${2:-}"; shift 2 ;;
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

require_cmd docker

CNF="$(mktemp)"
chmod 600 "$CNF"
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

log "Connecting to ${RDS_USER}@${RDS_HOST}:${RDS_PORT}"
mysql_rds -e "SELECT 1" >/dev/null

log "Server version"
mysql_rds -e "SELECT VERSION() AS version;"

log "Character set / collation / auth"
mysql_rds -e "
SHOW VARIABLES WHERE Variable_name IN (
  'character_set_server',
  'collation_server',
  'character_set_client',
  'sql_mode',
  'default_authentication_plugin',
  'authentication_policy',
  'log_bin',
  'gtid_mode',
  'lower_case_table_names'
);
"

log "Databases"
mysql_rds -e "SHOW DATABASES;"

log "Routines / triggers / events"
mysql_rds -N -e "
SELECT 'routines' AS kind, COUNT(*) FROM information_schema.routines
  WHERE routine_schema NOT IN ('mysql','sys','information_schema','performance_schema')
UNION ALL
SELECT 'triggers', COUNT(*) FROM information_schema.triggers
  WHERE trigger_schema NOT IN ('mysql','sys','information_schema','performance_schema')
UNION ALL
SELECT 'events', COUNT(*) FROM information_schema.events
  WHERE event_schema NOT IN ('mysql','sys','information_schema','performance_schema');
"

log "Table counts by database"
mysql_rds -e "
SELECT table_schema, COUNT(*) AS tables, ROUND(SUM(data_length+index_length)/1024/1024, 2) AS mb
FROM information_schema.tables
WHERE table_schema NOT IN ('mysql','sys','information_schema','performance_schema')
GROUP BY table_schema;
"

log "Preflight complete. Review version (8.0 is typically importable into 8.4) before migrate-from-rds.sh."
