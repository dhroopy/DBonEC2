#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"
load_env
require_cmd docker openssl
require_container

[[ -f "$HOST_ROOT_CNF" ]] || die "missing ${HOST_ROOT_CNF}; run install.sh first"
[[ -n "${MYSQL_BACKUP_PASSWORD:-}" ]] || die "MYSQL_BACKUP_PASSWORD is not set"

ESC_PW="${MYSQL_BACKUP_PASSWORD//\'/\'\'}"
SQL="$(mktemp)"
chmod 600 "$SQL"
trap 'rm -f "$SQL"' EXIT

log "Creating or updating backup@localhost"
cat > "$SQL" <<EOF
CREATE USER IF NOT EXISTS 'backup'@'localhost' IDENTIFIED BY '${ESC_PW}';
ALTER USER 'backup'@'localhost' IDENTIFIED BY '${ESC_PW}';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES, PROCESS, RELOAD,
      REPLICATION CLIENT, SHOW_ROUTINE
ON *.* TO 'backup'@'localhost';
EOF
docker exec -i "$MYSQL_CONTAINER" mysql --defaults-extra-file="$ROOT_CNF" < "$SQL"

# BINLOG MONITOR is the 8.4 name; fall back if a slightly older 8.x image is used.
if ! docker exec -i "$MYSQL_CONTAINER" mysql --defaults-extra-file="$ROOT_CNF" \
  -e "GRANT BINLOG MONITOR ON *.* TO 'backup'@'localhost';" >/dev/null 2>&1; then
  docker exec -i "$MYSQL_CONTAINER" mysql --defaults-extra-file="$ROOT_CNF" \
    -e "GRANT REPLICATION SLAVE ON *.* TO 'backup'@'localhost';" >/dev/null
fi
docker exec -i "$MYSQL_CONTAINER" mysql --defaults-extra-file="$ROOT_CNF" \
  -e "FLUSH PRIVILEGES;"

umask 077
cat > "$HOST_BACKUP_CNF" <<EOF
[client]
user=backup
password=${MYSQL_BACKUP_PASSWORD}
EOF
chmod 600 "$HOST_BACKUP_CNF"

if docker exec "$MYSQL_CONTAINER" mysql --defaults-extra-file="$BACKUP_CNF" -e "SELECT 1" >/dev/null; then
  log "Backup user can connect"
else
  die "backup user was created but cannot connect with ${HOST_BACKUP_CNF}"
fi
