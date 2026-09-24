# Scripts

After `install.sh`, the copies that run in production live under `/opt/mysql-server/`. Instance scripts read `/opt/mysql-server/.env` (`S3_BUCKET`, `S3_PREFIX`, `AWS_REGION`, `MYSQL_CONTAINER`, passwords). That file is mode `600` and owned by root, so run them with `sudo`.

The MySQL container must be running (`mysql84` unless `.env` says otherwise). Scripts that talk to S3 use the EC2 instance role. Confirm that with `aws sts get-caller-identity` before the first backup. Do not put access keys on the instance.

| Script | Where | What it changes |
| --- | --- | --- |
| [`infra/bootstrap-s3-iam.sh`](#bootstrap-s3-iamsh) | Laptop | S3 bucket, IAM role, optional SG rule |
| [`install.sh`](#installsh) | EC2 | Host packages, data disk, MySQL, timers |
| [`scripts/health-check.sh`](#health-checksh) | EC2 | Nothing (read-only) |
| [`scripts/backup-full.sh`](#backup-fullsh) | EC2 | New dump + manifest in S3; rotates the binary log |
| [`scripts/archive-binlogs.sh`](#archive-binlogssh) | EC2 | Uploads completed binlogs; never deletes local ones |
| [`scripts/verify-backup.sh`](#verify-backupsh) | EC2 | Throwaway container only; production data is untouched |
| [`scripts/restore.sh`](#restoresh) | EC2 | **Replaces every database** on the running server |
| [`scripts/restore-pitr.sh`](#restore-pitrsh) | EC2 | **Replaces every database**, then replays binlogs |
| [`scripts/init-backup-user.sh`](#init-backup-usersh) | EC2 | `backup@localhost` password and grants |
| [`scripts/preflight-rds.sh`](#preflight-rdssh) | EC2 | Nothing (reads RDS) |
| [`scripts/migrate-from-rds.sh`](#migrate-from-rdssh) | EC2 | Loads selected RDS schemas into this server |

`scripts/common.sh` is a library the other scripts source. `scripts/container-healthcheck.sh` is the Docker healthcheck inside the container. Do not run either by hand.

Timers installed by `install.sh` (timezone `Asia/Kolkata`):

| Timer | Schedule | Script | Log |
| --- | --- | --- | --- |
| `mysql-backup-full.timer` | daily 02:00 | `backup-full.sh` | `/opt/mysql-server/logs/backup-full.log` |
| `mysql-binlog-archive.timer` | every 15 minutes (`:00`, `:15`, `:30`, `:45`) | `archive-binlogs.sh` | `/opt/mysql-server/logs/binlog-archive.log` |
| `mysql-verify-backup.timer` | Sunday 04:00 | `verify-backup.sh` | `/opt/mysql-server/logs/verify-backup.log` |

```bash
systemctl list-timers 'mysql-*'
sudo systemctl start mysql-backup-full.service    # run one job now
journalctl -u mysql-backup-full.service -n 50
```

`systemctl start` on the `.service` runs the same script and appends to the log file. Running the script directly prints to the terminal.

---

## bootstrap-s3-iam.sh

Run on your Mac (or any admin shell), not on the MySQL instance. Needs AWS CLI, `jq`, and the laptop IAM user from [iam.md](iam.md). Does not create the EC2 instance. Safe to re-run.

```bash
AWS_PROFILE=mysql-infra-bootstrap ./infra/bootstrap-s3-iam.sh \
  --bucket YOUR_BUCKET_NAME \
  --region ap-south-1 \
  --instance-id i-xxxxxxxx \
  --mysql-sg sg-mysql \
  --app-sg sg-app
```

| Flag | Required | Default | Effect |
| --- | --- | --- | --- |
| `--bucket NAME` | yes | | Private bucket: Block Public Access, versioning, SSE-S3. 3–63 chars, lowercase letters, numbers, hyphens. |
| `--region REGION` | | `ap-south-1` | Bucket region and EC2 API region |
| `--role-name NAME` | | `mysql-backup-ec2-role` | Reused if it already exists |
| `--profile-name NAME` | | `mysql-backup-instance-profile` | Instance profile wrapped around that role |
| `--instance-id ID` | | | Attach the profile. Skipped if the instance already has a different profile. |
| `--mysql-sg` + `--app-sg` | | | Allow TCP 3306 from the app security group into the MySQL security group. Pass both or neither. |

Creates a 14-day lifecycle on `mysql/full/` and `mysql/binlogs/`. The role can get and put `mysql/*` only. It cannot delete objects.

`--help` prints the same flags.

---

## install.sh

Run as root on the Ubuntu EC2 instance. Exits on macOS. Copies this repo to `/opt/mysql-server`, mounts the extra EBS volume at `/mnt/mysql-data`, starts `mysql:8.4`, creates `backup@localhost`, and enables the three timers.

```bash
sudo ./install.sh --s3-bucket YOUR_BUCKET_NAME
```

It lists disks and asks which device to mount. A blank volume asks you to type `FORMAT` before `mkfs.ext4`. It refuses the root disk.

Unattended, after `lsblk`:

```bash
# volume already has a filesystem
sudo ./install.sh --non-interactive --device /dev/nvme1n1 --s3-bucket YOUR_BUCKET_NAME

# blank volume (erases that disk)
sudo ./install.sh --non-interactive --device /dev/nvme1n1 --format --s3-bucket YOUR_BUCKET_NAME
```

| Flag | Effect |
| --- | --- |
| `--s3-bucket NAME` | Writes `S3_BUCKET` in `.env`. On a re-run, updates the bucket and leaves passwords alone. |
| `--device DEV` | Block device to mount (typical Nitro name: `/dev/nvme1n1`) |
| `--format` | `mkfs.ext4` when `--device` has no filesystem. No prompt. |
| `--non-interactive` | Fail instead of prompting |
| `--allow-root-disk` | With `--non-interactive` and no extra volume, store data on the root disk. Only for a throwaway box. |

Re-runs do not overwrite an existing `.env`. Full deploy order: [deploy.md](deploy.md).

---

## health-check.sh

Read-only. Use this when you want a quick yes/no, and after install or cutover.

```bash
sudo /opt/mysql-server/scripts/health-check.sh
```

No arguments. Pings MySQL with the backup account. On success it prints `Threads_connected` and the last few binary logs, then exits 0. If MySQL is down it prints `CRITICAL: MySQL is DOWN` and exits 1.

This is separate from Docker's healthcheck (`container-healthcheck.sh`), which only answers the container's own `ping`.

---

## backup-full.sh

Dumps every database and uploads one compressed backup plus two manifests. The daily timer runs this at 02:00 IST. Run it once by hand before you trust the timer, and again after any restore.

```bash
sudo /opt/mysql-server/scripts/backup-full.sh
```

No arguments. It needs `docker`, `aws`, `zstd`, `jq`, and `sha256sum`, a running container, and `S3_BUCKET` in `.env`.

What it does:

1. `mysqldump --all-databases` with `--single-transaction`, routines, events, triggers, and `--source-data=2` (binlog file and position for point-in-time restore).
2. Compresses with `zstd` and uploads to `s3://BUCKET/mysql/full/YYYY/MM/mysql-full-YYYY-MM-DD_HH-MM-SS.sql.zst`.
3. Writes a manifest (checksum, size, GTID, binlog coordinates) to both:
   - `s3://BUCKET/mysql/manifests/mysql-full-YYYY-MM-DD_HH-MM-SS.json` (the one `restore-pitr.sh` uses)
   - `s3://BUCKET/mysql/manifests/YYYY-MM-DD.json` (that day's latest; a second backup the same day overwrites it)

The local `.sql` and `.zst` files are deleted when the script exits. A successful run ends with `Backup completed: s3://...` plus `sha256`, `size`, and `binlog=file:pos`.

`--flush-logs` starts a new binary log, so the next `archive-binlogs.sh` can upload the one this dump closed.

List what landed:

```bash
aws s3 ls s3://YOUR_BUCKET/mysql/full/ --recursive
aws s3 ls s3://YOUR_BUCKET/mysql/manifests/
```

---

## archive-binlogs.sh

Uploads binary logs that MySQL has finished writing. The timer runs this every 15 minutes. Point-in-time restore only sees logs that this script has uploaded, so run it once after `backup-full.sh` when you are proving the pipeline.

```bash
sudo /opt/mysql-server/scripts/archive-binlogs.sh
```

No arguments. It:

1. Runs `FLUSH BINARY LOGS` so the current file is closed and a new one starts.
2. Skips the new active file. An open log is never uploaded.
3. Uploads each completed log that is not already in S3 to `s3://BUCKET/mysql/binlogs/YYYY/MM/mysql-bin.NNNNNN.zst`. `YYYY/MM` is the date the archive runs, not the date the log was created.
4. Records the last uploaded name in `/opt/mysql-server/state/binlog-archive.state`.

It does not delete local binary logs. MySQL expiry does that. Re-runs are safe: objects already in S3 are skipped.

`No new completed binary logs to archive` is a normal result when nothing closed since the last run. `Binary log archive completed` means at least one object was uploaded.

---

## verify-backup.sh

Downloads the **latest** full backup from S3, checks it, and restores it into a temporary container named `mysql-verify-tmp`. It does not write to the production datadir.

```bash
sudo /opt/mysql-server/scripts/verify-backup.sh
```

No arguments. It:

1. Finds the newest `mysql/full/**/*.sql.zst`.
2. Runs `zstd -t` and compares sha256 to `mysql/manifests/<backup-name>.json`.
3. Starts `mysql:8.4` with a 128 MB buffer pool, imports the dump, then runs `SHOW DATABASES` and a table count per schema.
4. Removes the temporary container and files on exit, including on failure.

The weekly timer runs this Sunday at 04:00 IST. On a 2 GB instance the extra container is tight while production MySQL is up. Run it when load is low. Success ends with `Backup verification succeeded for s3://...`.

There is no flag to pick an older dump. To test a specific object, use `restore.sh` on a temporary EC2.

---

## restore.sh

Replaces **every database** on the running `mysql84` container with one full dump. Stop application writers first. Prefer a temporary EC2, then cut the app over. See [cutover.md](cutover.md).

```bash
sudo /opt/mysql-server/scripts/restore.sh \
  s3://YOUR_BUCKET/mysql/full/2026/09/mysql-full-YYYY-MM-DD_HH-MM-SS.sql.zst
```

One positional argument: the `s3://` URI of a `.sql.zst` from `backup-full.sh`. It must be run from an interactive terminal. A non-TTY shell exits before changing data. Type `RESTORE` at the prompt. Anything else cancels.

In the same MySQL session as the import, the script runs `RESET BINARY LOGS AND GTIDS` so `GTID_PURGED` from a backup of this server can load. That deletes this instance's binary logs and GTID history. Take a new full backup before you rely on point-in-time recovery again.

---

## restore-pitr.sh

Same replacement as `restore.sh`, then replays archived binlogs from the dump's binlog position up to a timestamp. Stop writers first. Prefer a temporary EC2.

```bash
sudo /opt/mysql-server/scripts/restore-pitr.sh \
  --backup s3://YOUR_BUCKET/mysql/full/2026/09/mysql-full-YYYY-MM-DD_HH-MM-SS.sql.zst \
  --stop-datetime "2026-09-18 11:19:59"
```

| Flag | Required | Effect |
| --- | --- | --- |
| `--backup URI` | yes | Full dump `.sql.zst` |
| `--stop-datetime "YYYY-MM-DD HH:MM:SS"` | yes | Replay stops at this time. Server timezone is `Asia/Kolkata` (`+05:30`). |
| `--manifest URI` | | Manifest JSON. Default: `s3://BUCKET/mysql/manifests/<backup-name>.json` |

Interactive TTY and the `RESTORE` prompt work the same way as `restore.sh`.

The manifest must contain `binlog_file` and `binlog_position` (written by `backup-full.sh`). The script downloads every archived binlog whose name is equal to or after that file, then runs `mysqlbinlog --start-position` and `--stop-datetime`. If those objects are missing, the restore of the full dump has already happened and the script then exits with an error. Archive binlogs before you need this.

`--help` prints the flags. After a successful PITR, take a new full backup. This server's previous binlogs and GTID history are gone.

---

## init-backup-user.sh

`install.sh` runs this once. Run it again only when `MYSQL_BACKUP_PASSWORD` in `/opt/mysql-server/.env` has changed, or when `backup@localhost` cannot connect.

```bash
sudo /opt/mysql-server/scripts/init-backup-user.sh
```

No arguments. It creates or updates `backup@localhost` with the password from `.env`, grants the privileges dumps and `FLUSH BINARY LOGS` need, and rewrites `/opt/mysql-server/secrets/backup.cnf` (mode `600`). It checks that the backup account can `SELECT 1`. It does not change the root or `appuser` passwords.

---

## preflight-rds.sh

Read-only check against RDS before [migrate-from-rds.sh](#migrate-from-rdssh). Run it on the EC2 instance. The instance must be able to reach the RDS endpoint. It does not dump or write anything.

```bash
sudo /opt/mysql-server/scripts/preflight-rds.sh \
  --host YOUR_RDS_ENDPOINT \
  --user YOUR_USER
```

You are prompted for the password. It is not stored. To avoid the prompt, set `RDS_PASSWORD` in the environment for that command only. `--password` also works and will show up in shell history, so prefer the prompt.

| Flag | Required | Default |
| --- | --- | --- |
| `--host HOST` | yes | `RDS_HOST` if set |
| `--user USER` | yes | `RDS_USER` if set |
| `--password PASS` | | prompt, or `RDS_PASSWORD` |
| `--port PORT` | | `3306` |

It prints server version, character set, collation, `sql_mode`, authentication plugin, whether binary logging and GTID are on, `lower_case_table_names`, database names, counts of routines / triggers / events, and table counts with size in MB. MySQL 8.0 dumps are the expected source for this 8.4 server. Read the output before migrating. `--help` prints the flags.

---

## migrate-from-rds.sh

Dumps schemas from RDS and loads them into the running `mysql84` container. Run [preflight-rds.sh](#preflight-rdssh) first. Keep RDS until the app and backups look right. Checklist: [cutover.md](cutover.md).

```bash
sudo /opt/mysql-server/scripts/migrate-from-rds.sh \
  --host YOUR_RDS_ENDPOINT \
  --user YOUR_USER \
  --databases '9930pa*,consign*'
```

Password handling matches `preflight-rds.sh` (prompt, `RDS_PASSWORD`, or `--password`).

| Flag | Required | Effect |
| --- | --- | --- |
| `--host HOST` | yes | RDS endpoint |
| `--user USER` | yes | RDS user that can dump the schemas |
| `--password PASS` | | Prefer the prompt so the password stays out of shell history |
| `--port PORT` | | Default `3306` |
| `--databases LIST` | | Comma-separated names. If omitted, every non-system schema on RDS is dumped. |

`--databases` accepts shell globs: `*` any length, `?` one character. `%` is treated as `*`. Quote the value so the shell does not expand it. System schemas (`mysql`, `sys`, `information_schema`, `performance_schema`) are never included. A pattern that matches nothing fails before the dump starts.

The script prints the schemas it will load (`Will migrate (N): ...`). The dump uses `--single-transaction`, routines, events, triggers, and `--set-gtid-purged=OFF`, so RDS GTID history is not imported. `mysqldump` emits `DROP TABLE IF EXISTS` for each dumped table, so tables that exist in both places are replaced. Tables that exist only on this server are left in place. There is no `RESTORE` prompt.

The compressed dump is kept at `/opt/mysql-server/backups/rds-migration-YYYY-MM-DD_HH-MM-SS.sql.zst`. Leave it there until cutover is proven, then delete it yourself. The script does not upload that file to S3.

After it finishes, point the application at this instance. EC2's own backups (`backup-full.sh`) use `--set-gtid-purged=ON` and are separate from this dump.
