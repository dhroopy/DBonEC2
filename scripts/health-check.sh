#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"
load_env
require_cmd docker
require_container

if ! docker exec "$MYSQL_CONTAINER" \
  mysqladmin --defaults-extra-file="$BACKUP_CNF" ping --silent; then
  log "CRITICAL: MySQL is DOWN"
  exit 1
fi

log "MySQL OK"
mysql_exec "$BACKUP_CNF" -e "SHOW GLOBAL STATUS LIKE 'Threads_connected';"
mysql_exec "$BACKUP_CNF" -e "SHOW BINARY LOGS;" | tail -n 5
