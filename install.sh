#!/usr/bin/env bash
set -Eeuo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="/opt/mysql-server"
DATA_DIR="/mnt/mysql-data"

NON_INTERACTIVE=0
DEVICE=""
DO_FORMAT=0
ALLOW_ROOT_DISK=0
S3_BUCKET_FLAG=""

usage() {
  cat <<'EOF'
Install MySQL 8.4 (Docker) onto this Ubuntu host.

Usage:
  sudo ./install.sh [options]

Options:
  --non-interactive     No prompts; fail instead of asking
  --device DEV          EBS device to mount at /mnt/mysql-data (e.g. /dev/nvme1n1)
  --format              Allow mkfs.ext4 on --device if it has no filesystem
  --allow-root-disk     Put MySQL data on the root volume (not recommended)
  --s3-bucket NAME      Write S3_BUCKET into .env
  -h, --help            Show this help

Run as root. Safe to re-run. Will not format a disk that already has a
filesystem, and will not format the root disk.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --device) DEVICE="${2:-}"; shift 2 ;;
    --format) DO_FORMAT=1; shift ;;
    --allow-root-disk) ALLOW_ROOT_DISK=1; shift ;;
    --s3-bucket) S3_BUCKET_FLAG="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

prompt() {
  local message="$1"
  local default="${2:-}"
  local reply=""
  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    echo "$default"
    return
  fi
  if [[ -n "$default" ]]; then
    read -r -p "${message} [${default}]: " reply || true
    echo "${reply:-$default}"
  else
    read -r -p "${message}: " reply || true
    echo "$reply"
  fi
}

[[ "$(id -u)" -eq 0 ]] || die "run as root (sudo ./install.sh)"
[[ "$(uname -s)" == "Linux" ]] || die "install.sh is intended for Ubuntu on EC2"

export DEBIAN_FRONTEND=noninteractive

log "Installing packages"
apt-get update -y
apt-get install -y ca-certificates curl gnupg unzip jq zstd rsync openssl

install_awscli() {
  local zip tmp
  case "$(uname -m)" in
    x86_64) zip="awscli-exe-linux-x86_64.zip" ;;
    aarch64|arm64) zip="awscli-exe-linux-aarch64.zip" ;;
    *) die "unsupported architecture for AWS CLI: $(uname -m)" ;;
  esac

  # Apt awscli is v1 and uses system Python. Python 3.14 argparse rejects
  # unescaped % in help text, which crashes some s3api commands with
  # "badly formed help string".
  if dpkg -s awscli >/dev/null 2>&1; then
    log "Removing apt awscli (v1 / system Python)"
    apt-get remove -y awscli
  fi

  tmp="$(mktemp -d)"
  log "Installing AWS CLI v2 (${zip})"
  curl -fsSL "https://awscli.amazonaws.com/${zip}" -o "${tmp}/awscliv2.zip"
  unzip -q "${tmp}/awscliv2.zip" -d "$tmp"
  "${tmp}/aws/install" --update
  rm -rf "$tmp"

  if [[ -x /usr/local/bin/aws && ! -e /usr/bin/aws ]]; then
    ln -s /usr/local/bin/aws /usr/bin/aws
  fi
  command -v aws >/dev/null 2>&1 || die "AWS CLI install did not put aws on PATH"
  log "$(aws --version 2>&1)"
}

install_awscli

install_docker_apt_repo() {
  local arch codename
  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
  [[ -n "$codename" ]] || die "could not detect Ubuntu codename"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
}

install_compose_plugin() {
  log "Installing Docker Compose plugin"
  if ! apt-cache show docker-compose-plugin >/dev/null 2>&1; then
    install_docker_apt_repo
  fi
  if apt-cache show docker-compose-plugin >/dev/null 2>&1; then
    apt-get install -y docker-compose-plugin
    return 0
  fi
  if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
    apt-get install -y docker-compose-v2
    return 0
  fi
  local arch plugin_dir dest url
  arch="$(uname -m)"
  case "$arch" in
    x86_64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) die "unsupported architecture for Docker Compose: ${arch}" ;;
  esac
  plugin_dir="/usr/libexec/docker/cli-plugins"
  dest="${plugin_dir}/docker-compose"
  url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}"
  mkdir -p "$plugin_dir"
  log "Downloading ${url}"
  curl -fsSL "$url" -o "$dest"
  chmod +x "$dest"
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker Engine"
    curl -fsSL https://get.docker.com | sh
  else
    log "Docker already installed"
  fi

  systemctl enable --now docker >/dev/null 2>&1 || true

  if ! docker compose version >/dev/null 2>&1; then
    install_compose_plugin
  fi

  systemctl enable --now docker >/dev/null 2>&1 || true

  local compose_out=""
  if ! compose_out="$(docker compose version 2>&1)"; then
    die "docker compose plugin is missing (${compose_out})"
  fi
  log "${compose_out}"
}

ensure_docker

if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
  usermod -aG docker "$SUDO_USER" || true
  log "Added ${SUDO_USER} to docker group (log out/in to apply)"
fi

install_dirs() {
  mkdir -p \
    "${DEST_DIR}/mysql/conf.d" \
    "${DEST_DIR}/scripts" \
    "${DEST_DIR}/backups" \
    "${DEST_DIR}/logs" \
    "${DEST_DIR}/secrets" \
    "${DEST_DIR}/state" \
    "${DEST_DIR}/systemd" \
    "${DEST_DIR}/infra" \
    "$DATA_DIR"
  chmod 700 "${DEST_DIR}/secrets"
}

root_disk_name() {
  local source pk
  source="$(findmnt -no SOURCE /)"
  pk="$(lsblk -no PKNAME "$source" 2>/dev/null || true)"
  if [[ -z "$pk" ]]; then
    basename "$source"
  else
    echo "$pk"
  fi
}

is_root_related() {
  local dev="$1"
  local base pk
  base="$(basename "$dev")"
  local root
  root="$(root_disk_name)"
  [[ "$base" == "$root" ]] && return 0
  pk="$(lsblk -no PKNAME "$dev" 2>/dev/null || true)"
  [[ "$pk" == "$root" ]] && return 0
  [[ "$(findmnt -no SOURCE /)" == "$dev" ]] && return 0
  return 1
}

list_candidate_devices() {
  local line
  while IFS= read -r line; do
    eval "$line"
    [[ "${TYPE:-}" == "disk" || "${TYPE:-}" == "part" ]] || continue
    [[ -z "${MOUNTPOINT:-}" ]] || continue
    is_root_related "/dev/${NAME}" && continue
    printf '/dev/%s %s fstype=%s\n' "$NAME" "$TYPE" "${FSTYPE:-none}"
  done < <(lsblk -P -o NAME,TYPE,FSTYPE,MOUNTPOINT)
}

ensure_data_volume() {
  if findmnt "$DATA_DIR" >/dev/null 2>&1; then
    log "${DATA_DIR} is already a mount point"
    return
  fi

  if [[ -z "$DEVICE" ]]; then
    log "Block devices:"
    lsblk
    local candidates
    candidates="$(list_candidate_devices || true)"
    if [[ -n "$candidates" ]]; then
      log "Unmounted non-root candidates:"
      echo "$candidates"
      local first
      first="$(echo "$candidates" | awk 'NR==1{print $1}')"
      DEVICE="$(prompt "EBS device to mount at ${DATA_DIR}" "$first")"
    else
      if [[ "$NON_INTERACTIVE" -eq 1 && "$ALLOW_ROOT_DISK" -eq 1 ]]; then
        log "No extra EBS volume; using root disk directory ${DATA_DIR}"
        mkdir -p "$DATA_DIR"
        return
      fi
      if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        die "no extra EBS volume found; pass --device or --allow-root-disk"
      fi
      local confirm
      confirm="$(prompt "No extra EBS found. Type ROOTDISK to store MySQL data on the root volume" "")"
      [[ "$confirm" == "ROOTDISK" ]] || die "aborted: no data volume"
      mkdir -p "$DATA_DIR"
      return
    fi
  fi

  [[ -n "$DEVICE" ]] || die "no device selected"
  [[ -b "$DEVICE" ]] || die "not a block device: ${DEVICE}"
  is_root_related "$DEVICE" && die "refusing to use the root disk (${DEVICE})"

  local fstype
  fstype="$(lsblk -no FSTYPE "$DEVICE" | head -n 1 | tr -d '[:space:]')"

  if [[ -z "$fstype" ]]; then
    if [[ "$DO_FORMAT" -ne 1 ]]; then
      if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        die "${DEVICE} has no filesystem; re-run with --format if you intend to erase it"
      fi
      local confirm
      confirm="$(prompt "Type FORMAT to mkfs.ext4 ${DEVICE} (THIS ERASES THE DISK)" "")"
      [[ "$confirm" == "FORMAT" ]] || die "aborted: will not format ${DEVICE}"
    fi
    log "Creating ext4 on ${DEVICE}"
    mkfs.ext4 -F "$DEVICE"
  else
    log "${DEVICE} already has filesystem ${fstype}; will mount, not format"
  fi

  mkdir -p "$DATA_DIR"
  mount "$DEVICE" "$DATA_DIR"
  local uuid
  uuid="$(blkid -s UUID -o value "$DEVICE")"
  [[ -n "$uuid" ]] || die "could not read UUID for ${DEVICE}"
  if ! grep -q "UUID=${uuid}" /etc/fstab; then
    echo "UUID=${uuid} ${DATA_DIR} ext4 defaults,nofail 0 2" >> /etc/fstab
    log "Added ${DATA_DIR} to /etc/fstab"
  fi
  mount -a
  findmnt "$DATA_DIR" >/dev/null || die "failed to mount ${DATA_DIR}"
  log "Mounted ${DEVICE} at ${DATA_DIR}"
}

sync_package() {
  if [[ "$SRC_DIR" == "$DEST_DIR" ]]; then
    log "Already running from ${DEST_DIR}; not copying"
    return
  fi
  log "Copying package to ${DEST_DIR}"
  rsync -a \
    --exclude '.git/' \
    --exclude '.env' \
    --exclude 'secrets/root.cnf' \
    --exclude 'secrets/backup.cnf' \
    --exclude 'backups/' \
    --exclude 'logs/' \
    --exclude 'state/' \
    "${SRC_DIR}/" "${DEST_DIR}/"
}

gen_pw() {
  openssl rand -base64 32 | tr -d '\n'
}

write_env() {
  local env_file="${DEST_DIR}/.env"
  if [[ -f "$env_file" ]]; then
    log ".env already exists; leaving passwords unchanged"
    if [[ -n "$S3_BUCKET_FLAG" ]]; then
      if grep -q '^S3_BUCKET=' "$env_file"; then
        sed -i "s|^S3_BUCKET=.*|S3_BUCKET=${S3_BUCKET_FLAG}|" "$env_file"
      else
        echo "S3_BUCKET=${S3_BUCKET_FLAG}" >> "$env_file"
      fi
      log "Set S3_BUCKET=${S3_BUCKET_FLAG}"
    fi
  else
    local root_pw user_pw backup_pw s3_bucket
    root_pw="$(gen_pw)"
    user_pw="$(gen_pw)"
    backup_pw="$(gen_pw)"
    s3_bucket="${S3_BUCKET_FLAG:-YOUR_BUCKET_NAME}"
    if [[ "$NON_INTERACTIVE" -ne 1 && -z "$S3_BUCKET_FLAG" ]]; then
      s3_bucket="$(prompt "S3 backup bucket name" "$s3_bucket")"
    fi
    cat > "$env_file" <<EOF
MYSQL_ROOT_PASSWORD=${root_pw}
MYSQL_DATABASE=app
MYSQL_USER=appuser
MYSQL_PASSWORD=${user_pw}
MYSQL_BACKUP_PASSWORD=${backup_pw}
TZ=Asia/Kolkata
S3_BUCKET=${s3_bucket}
S3_PREFIX=mysql
MYSQL_CONTAINER=mysql84
AWS_REGION=ap-south-1
EOF
    log "Wrote ${env_file} with generated passwords"
  fi
  chmod 600 "$env_file"
}

write_secrets() {
  # shellcheck disable=SC1091
  set -a
  source "${DEST_DIR}/.env"
  set +a
  umask 077
  cat > "${DEST_DIR}/secrets/root.cnf" <<EOF
[client]
user=root
password=${MYSQL_ROOT_PASSWORD}
EOF
  cat > "${DEST_DIR}/secrets/backup.cnf" <<EOF
[client]
user=backup
password=${MYSQL_BACKUP_PASSWORD}
EOF
  chmod 600 "${DEST_DIR}/secrets/root.cnf" "${DEST_DIR}/secrets/backup.cnf"
  log "Wrote secrets/root.cnf and secrets/backup.cnf"
}

start_mysql() {
  chmod +x "${DEST_DIR}/scripts/"*.sh "${DEST_DIR}/scripts/container-healthcheck.sh" \
    "${DEST_DIR}/install.sh" "${DEST_DIR}/infra/bootstrap-s3-iam.sh"
  cd "$DEST_DIR"
  log "Pulling mysql:8.4 and starting compose"
  docker compose pull
  docker compose up -d
  local i status="starting"
  for i in $(seq 1 90); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' mysql84 2>/dev/null || echo missing)"
    if [[ "$status" == "healthy" ]]; then
      log "MySQL is healthy"
      return
    fi
    sleep 2
  done
  docker logs mysql84 >&2 || true
  die "MySQL did not become healthy (last status=${status})"
}

verify_binlog() {
  # shellcheck disable=SC1091
  source "${DEST_DIR}/.env"
  local log_bin
  log_bin="$(docker exec mysql84 mysql --defaults-extra-file=/run/mysql-secrets/root.cnf -N -e 'SELECT @@log_bin;')"
  [[ "$log_bin" == "1" ]] || die "log_bin is not ON (got ${log_bin})"
  log "log_bin=ON"
  docker exec mysql84 mysql --defaults-extra-file=/run/mysql-secrets/root.cnf -e "SHOW BINARY LOGS;"
}

install_systemd() {
  log "Installing systemd timers"
  install -m 644 "${DEST_DIR}/systemd/"*.service "${DEST_DIR}/systemd/"*.timer /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now mysql-backup-full.timer
  systemctl enable --now mysql-binlog-archive.timer
  systemctl enable --now mysql-verify-backup.timer
  systemctl list-timers 'mysql-*' --no-pager || true
}

install_dirs
ensure_data_volume
sync_package
install_dirs
write_env
write_secrets
start_mysql
verify_binlog
"${DEST_DIR}/scripts/init-backup-user.sh"
install_systemd

if command -v aws >/dev/null 2>&1; then
  if aws sts get-caller-identity >/dev/null 2>&1; then
    log "Instance can call AWS APIs (IAM role looks attached)"
  else
    log "WARNING: aws sts get-caller-identity failed. Attach the instance profile before backups will work."
  fi
fi

log "Install complete."
cat <<EOF

MySQL 8.4 is running.
  Data:     ${DATA_DIR}
  App dir:  ${DEST_DIR}
  Connect:  docker exec -it mysql84 mysql --defaults-extra-file=/run/mysql-secrets/root.cnf

Next:
  1. Confirm IAM:  aws sts get-caller-identity
  2. First backup: ${DEST_DIR}/scripts/backup-full.sh
  3. Verify it:    ${DEST_DIR}/scripts/verify-backup.sh
  4. Then migrate: see docs/cutover.md

Do not expose TCP 3306 to 0.0.0.0/0. Allow only the application security group.
EOF
