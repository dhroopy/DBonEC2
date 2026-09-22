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

--databases is a comma-separated list of schema names. Shell globs work:
  --databases '9930pa*,consign*'

`*` matches any length, `?` matches one character. SQL-style `%` is accepted
as an alias for `*`. If --databases is omitted, all non-system schemas on
RDS are dumped. System schemas (mysql, sys, information_schema,
performance_schema) are never included.
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

SYSTEM_DBS_RE='^(information_schema|performance_schema|mysql|sys)$'

list_rds_databases() {
  mysql_rds -N -e "SHOW DATABASES;" \
    | grep -vE "$SYSTEM_DBS_RE" \
    | sed '/^$/d'
}

# Expand comma-separated names/globs against schemas on RDS. Unquoted glob on
# the right of [[ == ]] is intentional so * and ? match.
resolve_databases() {
  local patterns_csv="$1"
  local -a all=() selected=()
  local -A seen=()
  local pat glob db matched

  mapfile -t all < <(list_rds_databases)
  [[ ${#all[@]} -gt 0 ]] || die "no non-system databases on RDS"

  if [[ -z "$patterns_csv" ]]; then
    printf '%s\n' "${all[@]}"
    return
  fi

  patterns_csv="${patterns_csv// /}"
  local -a pats=()
  IFS=',' read -r -a pats <<<"$patterns_csv"

  for pat in "${pats[@]}"; do
    [[ -n "$pat" ]] || continue
    glob="${pat//%/*}"
    matched=0
    for db in "${all[@]}"; do
      # shellcheck disable=SC2254
      if [[ "$db" == $glob ]]; then
        if [[ -z "${seen[$db]:-}" ]]; then
          selected+=("$db")
          seen[$db]=1
        fi
        matched=1
      fi
    done
    [[ "$matched" -eq 1 ]] || die "no RDS databases matched: ${pat}"
  done

  [[ ${#selected[@]} -gt 0 ]] || die "no databases to migrate"
  printf '%s\n' "${selected[@]}"
}

log "Discovering databases on ${RDS_HOST}"
mapfile -t DBS < <(resolve_databases "$DATABASES_CSV")
[[ ${#DBS[@]} -gt 0 ]] || die "no databases to migrate"
log "Will migrate (${#DBS[@]}): ${DBS[*]}"

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
