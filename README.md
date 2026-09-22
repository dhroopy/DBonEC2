# MySQL 8.4 on EC2

Production-style MySQL 8.4 for a small workload on a Graviton `t4g.small`: Docker Compose, data on EBS, daily compressed backups, binary-log archiving for point-in-time recovery, and an RDS migration path.

You create the EC2 instance. A laptop script creates S3 + IAM. `sudo ./install.sh` on the instance starts MySQL.

## What you create

| Item | Value |
| --- | --- |
| Instance | `t4g.small` (2 vCPU / 2 GB), ARM64 |
| AMI | Ubuntu 24.04 LTS ARM64 |
| Region | `ap-south-1` |
| Root disk | default |
| Data disk | extra **30 GB gp3** EBS |
| Network | same VPC as the app; **do not** put 3306 on `0.0.0.0/0` |

Attach the extra volume before running `install.sh`. Place the instance where the app can reach it privately.

## Layout

```text
/opt/mysql-server/          # this package, after install
  docker-compose.yml
  .env                      # generated, mode 600, not in git
  mysql/conf.d/my.cnf
  scripts/                  # backup, restore, migrate, health
  secrets/                  # root.cnf + backup.cnf, mode 600
  backups/ logs/ state/
/mnt/mysql-data             # MySQL datadir on EBS
```

S3 layout:

```text
s3://YOUR_BUCKET/
  mysql/full/YYYY/MM/*.sql.zst
  mysql/binlogs/YYYY/MM/mysql-bin.*.zst
  mysql/manifests/*.json
```

## Phase 1 — AWS backup infrastructure (laptop)

Needs AWS CLI + `jq` and admin credentials. Does **not** create the EC2 instance.

```bash
./infra/bootstrap-s3-iam.sh \
  --bucket YOUR_BUCKET_NAME \
  --region ap-south-1 \
  --instance-id i-xxxxxxxx \
  --mysql-sg sg-mysql \
  --app-sg sg-app
```

`--instance-id` / `--mysql-sg` / `--app-sg` are optional. The script is idempotent.

It creates:

- Private S3 bucket (Block Public Access, versioning, SSE-S3)
- 14-day lifecycle on `mysql/full/` and `mysql/binlogs/`
- IAM role + instance profile with get/put on `mysql/*` only (no access keys)

Then:

1. Attach instance profile `mysql-backup-instance-profile` if you did not pass `--instance-id`.
2. Inbound TCP **3306** on the MySQL SG from the **application SG only**.
3. Outbound HTTPS from the instance to S3.

## Phase 2 — Install on the instance

Copy or clone this repo onto the instance, then:

```bash
sudo ./install.sh --s3-bucket YOUR_BUCKET_NAME
```

The installer:

- Installs Docker (with the Compose v2 plugin), awscli, jq, zstd
- Mounts the extra EBS volume at `/mnt/mysql-data` (prompts before `mkfs`; refuses the root disk)
- Generates `.env` and `secrets/*.cnf`
- Starts `mysql:8.4`, waits until healthy, confirms binary logging
- Creates `backup@localhost`
- Enables systemd timers (02:00 IST full backup, binlogs every 15 minutes, Sunday 04:00 verify)

Re-runnable. Existing `.env` is not overwritten.

Non-interactive example (device already formatted):

```bash
sudo ./install.sh --non-interactive --device /dev/nvme1n1 --s3-bucket YOUR_BUCKET_NAME
```

To format a blank volume:

```bash
sudo ./install.sh --non-interactive --device /dev/nvme1n1 --format --s3-bucket YOUR_BUCKET_NAME
```

On the instance:

```bash
aws sts get-caller-identity
aws s3 ls s3://YOUR_BUCKET_NAME/
docker exec -it mysql84 mysql --defaults-extra-file=/run/mysql-secrets/root.cnf
/opt/mysql-server/scripts/health-check.sh
```

Application login is `appuser` / `MYSQL_PASSWORD` from `/opt/mysql-server/.env`.

## Phase 3 — Prove backups before cutover

```bash
sudo /opt/mysql-server/scripts/backup-full.sh
sudo /opt/mysql-server/scripts/archive-binlogs.sh
sudo /opt/mysql-server/scripts/verify-backup.sh
```

`verify-backup.sh` restores the latest S3 dump into a throwaway container (128M buffer pool) and runs `SHOW DATABASES` plus table counts. On a 2 GB instance this can be tight while production MySQL is running; run it when load is low.

Timers:

```bash
systemctl list-timers 'mysql-*'
journalctl -u mysql-backup-full.service -n 50
```

Logs also append under `/opt/mysql-server/logs/`.

Restore onto **this** container is destructive and requires typing `RESTORE`:

```bash
sudo /opt/mysql-server/scripts/restore.sh s3://YOUR_BUCKET/mysql/full/2026/09/mysql-full-....sql.zst

sudo /opt/mysql-server/scripts/restore-pitr.sh \
  --backup s3://YOUR_BUCKET/mysql/full/2026/09/mysql-full-....sql.zst \
  --stop-datetime "2026-09-18 11:19:59"
```

Prefer a temporary EC2 for restore drills. See [docs/cutover.md](docs/cutover.md).

## Phase 4 — RDS migration

```bash
/opt/mysql-server/scripts/preflight-rds.sh --host YOUR_RDS_ENDPOINT --user YOUR_USER
/opt/mysql-server/scripts/migrate-from-rds.sh --host YOUR_RDS_ENDPOINT --user YOUR_USER
```

Then point the app at the EC2 private IP and **keep RDS** until backups and the app look right. Full checklist: [docs/cutover.md](docs/cutover.md).

## Security

- No AWS access keys in `.env`, scripts, Compose, or git
- Backup and restore SQL uses `defaults-extra-file`, not passwords on `ps`
- S3 bucket is private, versioned, encrypted (SSE-S3)
- Binlog archiver uploads completed logs only, is idempotent, and never deletes local binlogs (MySQL expiry owns that)
- IAM cannot `s3:DeleteObject`; lifecycle expires objects after 14 days

## RAM

`innodb_buffer_pool_size=768M` on 2 GB RAM. Raise it if you move to `t4g.medium`.

## Not in this package

CloudWatch disk alarms, a second EBS volume for binlogs, weekly/monthly S3 tiers, and KMS CMKs. Add those after the database is serving traffic.
