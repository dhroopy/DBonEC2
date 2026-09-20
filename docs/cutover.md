# RDS → EC2 MySQL cutover

Keep the RDS instance running until the EC2 server, backups, and application are proven. Do not delete RDS in the same window as the cutover.

## Before cutover

- [ ] EC2 MySQL is healthy (`/opt/mysql-server/scripts/health-check.sh`)
- [ ] `aws sts get-caller-identity` works on the instance (IAM role, no access keys)
- [ ] Security group: inbound TCP 3306 from the **application SG only**
- [ ] `/opt/mysql-server/scripts/preflight-rds.sh --host ... --user ...` reviewed (version, charset, routines)
- [ ] A successful `/opt/mysql-server/scripts/backup-full.sh` exists in S3
- [ ] `/opt/mysql-server/scripts/verify-backup.sh` passed against that backup
- [ ] Application connection string / secrets are ready to point at the EC2 private IP (or DNS)

## Migration

From the MySQL EC2 instance (it must be able to reach RDS):

```bash
/opt/mysql-server/scripts/migrate-from-rds.sh \
  --host YOUR_RDS_ENDPOINT \
  --user YOUR_USER \
  --databases db1,db2
```

If `--databases` is omitted, every non-system schema on RDS is dumped.

The dump uses `--set-gtid-purged=OFF` so RDS GTID history is not imported into this 8.4 server. After cutover, EC2 backups use `--set-gtid-purged=ON`.

The compressed dump is kept under `/opt/mysql-server/backups/` until you delete it.

## Application switch

1. Stop or quiesce writers on the application (brief freeze if you need a clean cut).
2. Re-run `migrate-from-rds.sh` if you need a final delta after the freeze, **or** accept that in-flight writes after the dump are only on RDS.
3. Point the application at the EC2 private IP, port 3306, using `appuser` (see `/opt/mysql-server/.env`). Recreate any extra RDS users/grants on EC2 if the app does not use `appuser`.
4. Smoke-test reads and writes.
5. Watch `/opt/mysql-server/scripts/health-check.sh` and the next binlog archive / next daily backup.

## After cutover (several days)

- [ ] Application looks correct in production
- [ ] Daily full backups continue to land in S3
- [ ] Binlog archives continue every 15 minutes
- [ ] At least one weekly (or manual) `verify-backup.sh` has succeeded **after** cutover
- [ ] You can still connect to RDS as a rollback (do not delete yet)

Only then take a final RDS snapshot and delete or stop RDS.

## Rollback

Point the application back at the RDS endpoint. EC2 can stay running. Do not restore S3 backups onto RDS as the default rollback; RDS still has the pre-cutover data until you delete it.

## Do not

- Restore S3 backups over this production container as a routine operation. Use a throwaway instance, then cut over.
- Open `3306` to `0.0.0.0/0`.
- Put `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in `.env` or scripts.
