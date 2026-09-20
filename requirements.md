Yes. For your workload, I would build this as a **small production-style MySQL server**, rather than just putting MySQL in Docker and running `mysqldump` once a day.

The design below gives you:

* MySQL **8.4 LTS**
* ARM64 / Graviton compatible
* Docker Compose
* Persistent EBS storage
* Daily compressed full backups
* Binary-log archiving for **point-in-time recovery**
* S3 encryption
* S3 lifecycle/retention
* Automatic backup verification
* Restore script
* Health checks
* No AWS access keys stored on the EC2 server
* Easy migration of your existing RDS databases

MySQL 8.4 has binary logging enabled by default, and MySQL explicitly documents binary logs as the mechanism for incremental/PITR recovery. ([MySQL][1])

The official MySQL 8.4 Docker image also has an ARM64 build, so it is suitable for a Graviton `t4g.small`. ([Docker Hub][2])

---

# 1. Final architecture

I'd use:

```text
                         Internet
                            │
                            │
                    Your Application
                            │
                            │
                     Private Network
                            │
                            ▼
                  ┌───────────────────┐
                  │   EC2 t4g.small   │
                  │   2 vCPU / 2 GB   │
                  │                   │
                  │     Docker        │
                  │       │           │
                  │       ▼           │
                  │   MySQL 8.4       │
                  │       │           │
                  │       ▼           │
                  │     EBS gp3       │
                  │     30 GB         │
                  │                   │
                  │  backup scripts    │
                  └─────────┬─────────┘
                            │
                     AWS IAM Role
                            │
                            ▼
                    ┌──────────────┐
                    │      S3      │
                    │              │
                    │ Full backups │
                    │ Binary logs  │
                    │              │
                    │ Encryption   │
                    │ Lifecycle    │
                    └──────────────┘
```

The important part is that **S3 is outside the EC2 machine**.

If the EC2 instance/EBS volume completely disappears, your backups still exist.

S3 automatically encrypts new objects at rest using SSE-S3 by default, so we don't need to introduce KMS complexity unless you specifically need customer-managed keys. ([AWS Documentation][3])

---

# 2. Directory structure

We'll create:

```text
/opt/mysql-server/
│
├── docker-compose.yml
├── .env
│
├── mysql/
│   └── conf.d/
│       └── my.cnf
│
├── scripts/
│   ├── backup-full.sh
│   ├── archive-binlogs.sh
│   ├── restore.sh
│   ├── verify-backup.sh
│   └── health-check.sh
│
├── backups/
│
└── logs/
```

The actual MySQL data should live on:

```text
/mnt/mysql-data
```

which we'll mount from the EBS volume.

---

# 3. EC2 setup

I'd use:

```text
Instance:
t4g.small

AMI:
Ubuntu 24.04 LTS ARM64

Storage:
30 GB gp3

Region:
ap-south-1

Architecture:
ARM64
```

Don't expose MySQL publicly.

Your security group should ideally have:

```text
TCP 3306
Source:
application server's security group
```

rather than:

```text
0.0.0.0/0
```

---

# 4. Install Docker

On the EC2 server:

```bash
sudo apt update
sudo apt upgrade -y

sudo apt install -y \
    ca-certificates \
    curl \
    gnupg \
    unzip \
    jq \
    zstd \
    awscli
```

Install Docker:

```bash
curl -fsSL https://get.docker.com | sudo sh
```

Add your user:

```bash
sudo usermod -aG docker $USER
```

Then log out and log back in.

Verify:

```bash
docker --version
docker compose version
```

---

# 5. Format and mount EBS

Suppose your additional EBS volume is:

```text
/dev/nvme1n1
```

**Verify this carefully before running the formatting command.**

```bash
lsblk
```

Then:

```bash
sudo mkfs.ext4 /dev/nvme1n1
```

Create mount point:

```bash
sudo mkdir -p /mnt/mysql-data
```

Mount:

```bash
sudo mount /dev/nvme1n1 /mnt/mysql-data
```

Get UUID:

```bash
sudo blkid /dev/nvme1n1
```

Add it to `/etc/fstab`:

```text
UUID=YOUR_UUID /mnt/mysql-data ext4 defaults,nofail 0 2
```

Then:

```bash
sudo mount -a
```

Verify:

```bash
df -h
```

---

# 6. Create application directory

```bash
sudo mkdir -p /opt/mysql-server
sudo mkdir -p /opt/mysql-server/mysql/conf.d
sudo mkdir -p /opt/mysql-server/scripts
sudo mkdir -p /opt/mysql-server/backups
sudo mkdir -p /opt/mysql-server/logs
```

---

# 7. Docker Compose

Create:

```text
/opt/mysql-server/docker-compose.yml
```

with:

```yaml
services:

  mysql:
    image: mysql:8.4
    container_name: mysql84
    restart: unless-stopped

    env_file:
      - .env

    command:
      - --server-id=1
      - --log-bin=mysql-bin
      - --binlog-format=ROW
      - --binlog-expire-logs-seconds=604800
      - --gtid-mode=ON
      - --enforce-gtid-consistency=ON
      - --default-authentication-plugin=caching_sha2_password
      - --skip-name-resolve
      - --max-connections=100
      - --innodb-buffer-pool-size=768M
      - --innodb-log-file-size=128M
      - --innodb-flush-log-at-trx-commit=1
      - --sync-binlog=1

    ports:
      - "3306:3306"

    volumes:
      - /mnt/mysql-data:/var/lib/mysql
      - ./mysql/conf.d:/etc/mysql/conf.d:ro

    healthcheck:
      test:
        [
          "CMD",
          "mysqladmin",
          "ping",
          "-h",
          "127.0.0.1",
          "-u",
          "root",
          "--password=$${MYSQL_ROOT_PASSWORD}"
        ]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

    stop_grace_period: 1m
```

---

# 8. Important: RAM tuning

Your instance only has:

```text
2 GB RAM
```

So we don't want MySQL consuming all of it.

I've therefore set:

```text
innodb-buffer-pool-size=768M
```

This leaves room for:

```text
Linux
Docker
MySQL overhead
connections
backup process
AWS agents
```

If you later move to `t4g.medium`, we can increase this to around:

```text
1.5–2 GB
```

---

# 9. Environment file

Create:

```text
/opt/mysql-server/.env
```

Example:

```env
MYSQL_ROOT_PASSWORD=CHANGE_THIS_TO_A_LONG_RANDOM_PASSWORD
MYSQL_DATABASE=app

MYSQL_USER=appuser
MYSQL_PASSWORD=CHANGE_THIS_TO_ANOTHER_LONG_RANDOM_PASSWORD

TZ=Asia/Kolkata
```

Generate passwords rather than manually inventing them:

```bash
openssl rand -base64 32
```

**Do not commit `.env` to Git.**

Set permissions:

```bash
sudo chmod 600 /opt/mysql-server/.env
```

---

# 10. MySQL configuration

Create:

```text
/opt/mysql-server/mysql/conf.d/my.cnf
```

```ini
[mysqld]

# Character set
character-set-server=utf8mb4
collation-server=utf8mb4_0900_ai_ci

# Binary logging / PITR
log_bin=/var/lib/mysql/mysql-bin
binlog_format=ROW
binlog_expire_logs_seconds=604800

# GTID
gtid_mode=ON
enforce_gtid_consistency=ON

# Durability
innodb_flush_log_at_trx_commit=1
sync_binlog=1

# Connection safety
max_connections=100

# Timezone
default-time-zone='+05:30'

# Slow query monitoring
slow_query_log=ON
slow_query_log_file=/var/lib/mysql/mysql-slow.log
long_query_time=2

# Error log
log_error=/var/lib/mysql/mysql-error.log
```

MySQL 8.4 supports binary logging by default, but we're explicitly configuring it so the setup is obvious and survives future configuration changes. ([MySQL][4])

---

# 11. Start MySQL

```bash
cd /opt/mysql-server

docker compose pull
docker compose up -d
```

Check:

```bash
docker ps
```

Then:

```bash
docker logs mysql84
```

Eventually you should see MySQL ready for connections.

Test:

```bash
docker exec -it mysql84 \
mysql -uroot -p
```

---

# 12. Verify binary logging

Inside MySQL:

```sql
SHOW VARIABLES LIKE 'log_bin';
```

You want:

```text
log_bin    ON
```

Then:

```sql
SHOW VARIABLES LIKE 'binlog_format';
```

Should be:

```text
ROW
```

And:

```sql
SHOW BINARY LOGS;
```

You should see something like:

```text
mysql-bin.000001
```

---

# 13. Create S3 bucket

I'd create a dedicated bucket, something like:

```text
your-company-mysql-backups-ap-south-1
```

Prefer a unique name.

```bash
aws s3api create-bucket \
    --bucket YOUR_BUCKET_NAME \
    --region ap-south-1 \
    --create-bucket-configuration LocationConstraint=ap-south-1
```

Enable versioning:

```bash
aws s3api put-bucket-versioning \
    --bucket YOUR_BUCKET_NAME \
    --versioning-configuration Status=Enabled
```

Although S3 already encrypts new objects by default using SSE-S3, I would explicitly configure it as part of the infrastructure setup. ([AWS Documentation][3])

```bash
aws s3api put-bucket-encryption \
    --bucket YOUR_BUCKET_NAME \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

---

# 14. Give EC2 access using IAM — NOT access keys

This is important.

**Do not put:**

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

in your backup scripts.

Instead:

```text
EC2
 │
 │ IAM Instance Profile
 ▼
S3
```

Create an IAM policy that only allows access to this backup bucket.

Example:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBackupBucket",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::YOUR_BUCKET_NAME"
    },
    {
      "Sid": "BackupObjects",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::YOUR_BUCKET_NAME/*"
    }
  ]
}
```

Attach the policy to an EC2 IAM role and associate that role with your instance.

Then:

```bash
aws sts get-caller-identity
```

should work **without storing credentials anywhere**.

---

# 15. Full backup script

Create:

```text
/opt/mysql-server/scripts/backup-full.sh
```

```bash
#!/bin/bash

set -Eeuo pipefail

BASE_DIR="/opt/mysql-server"
BACKUP_DIR="$BASE_DIR/backups"

S3_BUCKET="YOUR_BUCKET_NAME"
S3_PREFIX="mysql/full"

DATE=$(date '+%Y-%m-%d_%H-%M-%S')

MYSQL_CONTAINER="mysql84"

mkdir -p "$BACKUP_DIR"

BACKUP_FILE="$BACKUP_DIR/mysql-full-$DATE.sql.zst"

echo "========================================="
echo "MySQL Full Backup"
echo "Started: $(date)"
echo "========================================="

echo "Creating backup..."

docker exec "$MYSQL_CONTAINER" \
    mysqldump \
    -uroot \
    -p"${MYSQL_ROOT_PASSWORD}" \
    --all-databases \
    --single-transaction \
    --routines \
    --events \
    --triggers \
    --hex-blob \
    --set-gtid-purged=ON \
    --source-data=2 \
    --flush-logs \
    | zstd -T0 -10 > "$BACKUP_FILE"

echo "Backup created:"
ls -lh "$BACKUP_FILE"

echo "Uploading to S3..."

aws s3 cp \
    "$BACKUP_FILE" \
    "s3://${S3_BUCKET}/${S3_PREFIX}/$(basename "$BACKUP_FILE")" \
    --storage-class STANDARD

echo "Upload completed."

echo "Removing local backup..."

rm -f "$BACKUP_FILE"

echo "Backup completed successfully:"
echo "$(date)"
```

MySQL documents `mysqldump --flush-logs --source-data` as a suitable pattern for establishing the binary-log position associated with a full backup. ([MySQL][5])

---

# 16. Fix password handling

I don't actually recommend putting the root password directly into a command line.

A better approach is to create:

```text
/root/.my.cnf
```

with:

```ini
[client]
user=root
password=YOUR_ROOT_PASSWORD
host=127.0.0.1
```

Then:

```bash
chmod 600 /root/.my.cnf
```

But because MySQL is inside Docker, we'll instead create a dedicated backup user.

That's cleaner.

---

# 17. Create backup user

Connect to MySQL:

```bash
docker exec -it mysql84 mysql -uroot -p
```

Then:

```sql
CREATE USER 'backup'@'localhost'
IDENTIFIED BY 'VERY_LONG_RANDOM_PASSWORD';
```

Grant:

```sql
GRANT SELECT,
      SHOW VIEW,
      TRIGGER,
      EVENT,
      LOCK TABLES,
      PROCESS,
      RELOAD,
      REPLICATION CLIENT,
      REPLICATION SLAVE
ON *.*
TO 'backup'@'localhost';
```

Then:

```sql
FLUSH PRIVILEGES;
```

However, because the backup command is executed inside the container, I would ultimately put the backup credentials into a Docker secret or protected configuration rather than `.env`.

For the first implementation, a protected `.env` is acceptable.

---

# 18. Binary-log backup

This is the part that gives us PITR.

MySQL's binary logs contain the changes occurring after a full backup, which is exactly what we need for incremental recovery. ([MySQL][1])

Create:

```text
/opt/mysql-server/scripts/archive-binlogs.sh
```

```bash
#!/bin/bash

set -Eeuo pipefail

BASE_DIR="/opt/mysql-server"
TMP_DIR="$BASE_DIR/backups/binlogs"

S3_BUCKET="YOUR_BUCKET_NAME"
S3_PREFIX="mysql/binlogs"

MYSQL_CONTAINER="mysql84"

mkdir -p "$TMP_DIR"

echo "Rotating MySQL binary log..."

docker exec "$MYSQL_CONTAINER" \
    mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
    -e "FLUSH BINARY LOGS;"

echo "Finding binary logs..."

docker exec "$MYSQL_CONTAINER" \
    mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
    -N -e "SHOW BINARY LOGS;" \
    > "$TMP_DIR/binlog-list.txt"

while read -r BINLOG SIZE; do

    echo "Processing $BINLOG"

    docker cp \
        "$MYSQL_CONTAINER:/var/lib/mysql/$BINLOG" \
        "$TMP_DIR/$BINLOG"

    if [ -f "$TMP_DIR/$BINLOG" ]; then

        zstd -T0 -10 \
            "$TMP_DIR/$BINLOG" \
            -o "$TMP_DIR/$BINLOG.zst"

        aws s3 cp \
            "$TMP_DIR/$BINLOG.zst" \
            "s3://${S3_BUCKET}/${S3_PREFIX}/$BINLOG.zst"

        rm -f "$TMP_DIR/$BINLOG"
        rm -f "$TMP_DIR/$BINLOG.zst"

    fi

done < "$TMP_DIR/binlog-list.txt"

rm -f "$TMP_DIR/binlog-list.txt"

echo "Binary log archive completed."
```

---

# 19. One improvement I'd make

Rather than uploading every binlog every hour, I would initially run:

```text
Full backup:
02:00 daily

Binlog archive:
every 15 minutes
```

Your database is tiny, so this is extremely lightweight.

That means your theoretical recovery point can be approximately:

```text
~15 minutes
```

depending on how the archive job is implemented and whether the latest logs have reached S3.

If the business requires tighter RPO, we can make this every 5 minutes or continuously stream binlogs.

---

# 20. Cron schedule

Create:

```bash
sudo crontab -e
```

Add:

```cron
# Full MySQL backup at 2:00 AM IST
0 2 * * * /opt/mysql-server/scripts/backup-full.sh >> /opt/mysql-server/logs/backup.log 2>&1

# Archive binary logs every 15 minutes
*/15 * * * * /opt/mysql-server/scripts/archive-binlogs.sh >> /opt/mysql-server/logs/binlog.log 2>&1
```

---

# 21. Backup retention

I would **not** delete S3 backups using the shell script.

Let S3 Lifecycle manage retention.

Example policy:

```text
Daily backups:
14 days

Weekly:
8 weeks

Monthly:
12 months
```

You can have the backup job create:

```text
mysql/full/
```

and S3 lifecycle rules manage the objects.

This avoids accidentally deleting the wrong backup from the EC2 machine.

---

# 22. Restore process

This is extremely important.

The entire purpose of the backup system is:

```text
Can I actually restore?
```

Suppose:

```text
Full backup:

2026-09-18 02:00
```

and you need to recover to:

```text
2026-09-18 11:37
```

The process is:

```text
S3 full backup
       │
       ▼
Restore MySQL
       │
       ▼
Apply binary logs
       │
       ▼
11:37
```

MySQL officially supports using `mysqlbinlog` to replay binary logs after restoring a full backup. ([MySQL][6])

---

# 23. Restore script

Create:

```text
/opt/mysql-server/scripts/restore.sh
```

I'd make this a **manual command**, not something automated.

```bash
#!/bin/bash

set -Eeuo pipefail

S3_BUCKET="YOUR_BUCKET_NAME"

BACKUP_FILE="$1"

if [ -z "$BACKUP_FILE" ]; then
    echo "Usage:"
    echo "./restore.sh s3://bucket/path/backup.sql.zst"
    exit 1
fi

TEMP="/tmp/mysql-restore"

rm -rf "$TEMP"
mkdir -p "$TEMP"

echo "Downloading backup..."

aws s3 cp \
    "$BACKUP_FILE" \
    "$TEMP/backup.sql.zst"

echo "Decompressing..."

zstd -d \
    "$TEMP/backup.sql.zst" \
    -o "$TEMP/backup.sql"

echo "Stopping application access is REQUIRED."

read -p "Type RESTORE to continue: " CONFIRM

if [ "$CONFIRM" != "RESTORE" ]; then
    echo "Cancelled."
    exit 1
fi

echo "Restoring..."

docker exec -i mysql84 \
    mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
    < "$TEMP/backup.sql"

echo "Restore completed."

rm -rf "$TEMP"
```

---

# 24. PITR restore

For example:

```text
Full backup
02:00

User accidentally deletes data
11:20

You want:
11:19:59
```

You restore:

```text
02:00 full backup
```

Then download:

```text
binlog.000123
binlog.000124
...
```

and replay them:

```bash
mysqlbinlog \
    --start-position=POSITION \
    --stop-datetime="2026-09-18 11:19:59" \
    binlog.000123 \
    binlog.000124 \
    | mysql
```

MySQL specifically supports `--stop-datetime` and `--start-position` for PITR. ([MySQL][7])

For production recovery, I would generally use **binlog positions/GTIDs where possible**, rather than relying exclusively on timestamps; MySQL's Enterprise documentation specifically cautions that timestamp-based ranges have a greater risk of missing events. ([MySQL][8])

---

# 25. Very important: don't restore over production

The safest workflow is:

```text
S3 backup
    │
    ▼
Temporary EC2
    │
    ▼
Restore
    │
    ▼
Validate
    │
    ▼
Promote to production
```

Not:

```text
Production
    │
    ▼
DROP DATABASE
    │
    ▼
Hope restore works
```

For your tiny 200 MB database, creating a temporary recovery instance is very practical.

---

# 26. Automated backup verification

I'd add another job.

Every day:

```text
Backup created
     ↓
Upload S3
     ↓
Download backup
     ↓
Decompress
     ↓
Check SQL structure
     ↓
Optionally restore to temporary MySQL
     ↓
Run validation queries
```

At minimum, we should check:

```bash
aws s3 ls s3://YOUR_BUCKET_NAME/mysql/full/
```

and:

```bash
zstd -t backup.sql.zst
```

`zstd -t` verifies that the compressed file isn't corrupted.

But **the gold standard is an actual restore test**.

---

# 27. I'd schedule a weekly restore test

Something like:

```text
Sunday 04:00

S3
 │
 ▼
Temporary MySQL container
 │
 ▼
Restore latest backup
 │
 ▼
Run checks
 │
 ├── SHOW DATABASES
 ├── table counts
 ├── critical queries
 └── checksum/sample validation
 │
 ▼
Destroy container
```

This gives you confidence that the backups are genuinely usable.

---

# 28. Database health monitoring

Create a simple health script:

```text
/opt/mysql-server/scripts/health-check.sh
```

```bash
#!/bin/bash

set -e

if ! docker exec mysql84 \
    mysqladmin ping \
    -uroot \
    -p"${MYSQL_ROOT_PASSWORD}" \
    --silent; then

    echo "CRITICAL: MySQL is DOWN"

    exit 1
fi

echo "MySQL OK"

docker exec mysql84 \
    mysql -uroot \
    -p"${MYSQL_ROOT_PASSWORD}" \
    -e "SHOW GLOBAL STATUS LIKE 'Threads_connected';"

docker exec mysql84 \
    mysql -uroot \
    -p"${MYSQL_ROOT_PASSWORD}" \
    -e "SHOW BINARY LOGS;" | tail
```

---

# 29. CloudWatch

I'd install the CloudWatch Agent eventually.

Monitor:

```text
CPUUtilization
Disk usage
Disk I/O
Memory
Swap
Network
```

Most importantly:

```text
EBS disk usage
```

because MySQL can suddenly fill the disk due to:

* binary logs
* temporary tables
* large queries
* database growth
* forgotten logs

---

# 30. Disk protection

I'd configure an alert:

```text
Disk > 70%
```

Warning:

```text
Disk > 80%
```

Critical:

```text
Disk > 90%
```

Don't wait until:

```text
Disk = 100%
```

A full MySQL filesystem can turn into a very unpleasant outage.

---

# 31. One change I recommend to the architecture

I would actually use **two EBS volumes** if the workload grows:

```text
EC2
│
├── Root EBS
│    └── OS / Docker
│
└── Data EBS
     └── MySQL
```

For now:

```text
30 GB gp3 MySQL EBS
```

is perfectly reasonable.

Later:

```text
Root: 20 GB
Data: 50–100 GB
```

is cleaner.

MySQL's own recovery documentation notes the importance of keeping binary logs on storage separate from the data directory when protecting against loss of the underlying data disk. ([MySQL][6])

Since we're sending them to S3, we're already adding an external copy, but separate local storage is still a useful additional protection.

---

# 32. S3 structure

I'd ultimately use:

```text
s3://your-mysql-backups/

├── full/
│   ├── 2026/
│   │   └── 09/
│   │       ├── mysql-full-2026-09-18_02-00-00.sql.zst
│   │       ├── mysql-full-2026-09-19_02-00-00.sql.zst
│   │       └── ...
│
├── binlogs/
│   └── 2026/
│       └── 09/
│           ├── mysql-bin.000001.zst
│           ├── mysql-bin.000002.zst
│           └── ...
│
└── manifests/
    ├── 2026-09-18.json
    └── ...
```

The manifest is useful because it can record:

```json
{
  "backup_date": "2026-09-18T02:00:00+05:30",
  "mysql_version": "8.4.x",
  "binlog_file": "mysql-bin.000123",
  "binlog_position": 456789,
  "gtid": "....",
  "backup_size": 12345678,
  "sha256": "..."
}
```

Then recovery becomes much easier.

---

# 33. Security

I'd use:

```text
EC2 IAM Role
       │
       ▼
S3 bucket
       │
       ├── private
       ├── encrypted
       ├── versioned
       └── lifecycle managed
```

And:

```text
MySQL
  │
  └── 3306
       │
       └── ONLY application security group
```

No:

```text
3306 → 0.0.0.0/0
```

No AWS access keys in:

```text
.env
scripts
Docker Compose
GitHub
```

---

# 34. One improvement I'd make specifically for your migration

Since you're migrating from RDS, **don't immediately shut down the RDS instance**.

Do:

```text
             CURRENT
               RDS
                │
                │
                ▼
          Migration dump
                │
                ▼
        EC2 MySQL 8.4
                │
                ▼
        Application testing
                │
                ▼
          Production cutover
                │
                ▼
          RDS retained
          temporarily
```

Keep RDS around for several days after the cutover.

Then:

```text
EC2 stable
+
backups tested
+
application verified
+
restore tested
        ↓
Delete RDS
```

---

# 35. Migration command

For a small 200 MB database, this is very straightforward.

From RDS:

```bash
mysqldump \
    -h YOUR_RDS_ENDPOINT \
    -u YOUR_USER \
    -p \
    --single-transaction \
    --routines \
    --events \
    --triggers \
    --set-gtid-purged=OFF \
    YOUR_DATABASE \
    | zstd -10 > rds-migration.sql.zst
```

Then transfer it to EC2 and restore:

```bash
zstd -d rds-migration.sql.zst -c | \
docker exec -i mysql84 \
mysql -uroot -p
```

For your database size, this should be very manageable.

---

# 36. One thing we should check before migration

Because you're moving from RDS MySQL to MySQL 8.4, I'd run:

```sql
SELECT VERSION();
```

on RDS.

If you're currently on:

```text
MySQL 8.0
```

we need to check compatibility before importing.

In particular:

* authentication
* deprecated syntax
* SQL modes
* reserved words
* stored procedures
* triggers
* events
* character sets
* collations
* generated columns
* JSON
* spatial features
* users/grants

The migration shouldn't be treated as merely copying the `.ibd` files.

---

# 37. What I'd change from the initial proposal

After looking at the backup requirements more carefully, I would use this architecture:

```text
                         ┌─────────────────────┐
                         │      EC2 t4g.small   │
                         │                     │
                         │  Ubuntu ARM64       │
                         │                     │
                         │  Docker             │
                         │     │               │
                         │     ▼               │
                         │  MySQL 8.4          │
                         │     │               │
                         │     ├── DB1         │
                         │     ├── DB2         │
                         │     └── DB3         │
                         │                     │
                         │  EBS gp3            │
                         │                     │
                         │  Backup scheduler   │
                         └──────────┬──────────┘
                                    │
                           IAM Instance Role
                                    │
                                    ▼
                          ┌──────────────────┐
                          │        S3        │
                          │                  │
                          │ Full backups     │
                          │ Binary logs      │
                          │ Manifests        │
                          │ Versioning       │
                          │ Lifecycle        │
                          └──────────────────┘
```

This gives you:

**RPO:** approximately 15 minutes initially
**RTO:** potentially tens of minutes for a new EC2 + restore
**Full backup:** daily
**PITR:** yes
**Off-server backup:** yes
**Encrypted backup:** yes
**ARM64:** yes
**MySQL 8.4:** yes
**Multiple databases:** yes
**No AWS access keys:** yes

And importantly, MySQL's documented PITR model is exactly **full backup + subsequent binary logs**, which is what we're implementing. ([MySQL][9])

### One caveat before you copy this into production

The scripts above are the **architecture and deployment foundation**, but I would make two changes before calling it "production-ready":

1. **Use a proper backup credential/secret mechanism rather than embedding the root password in shell commands.**
2. **Make the binlog archiver position-aware**, so it never uploads the same binlog repeatedly and never deletes/loses a binlog before S3 has a confirmed copy.

That second point is particularly important for a true PITR system.

If you want, I can take this one step further and give you a **single ready-to-deploy `/opt/mysql-server` package** containing the `docker-compose.yml`, `.env.example`, MySQL config, robust S3 backup/PITR scripts, cron/systemd timers, restore tool, backup verification, IAM policy, and an **interactive `install.sh`** where you basically run:

```bash
sudo ./install.sh
```

and it sets the entire server up.

[1]: https://dev.mysql.com/doc/refman/8.4/en/backup-methods.html?utm_source=chatgpt.com "MySQL :: MySQL 8.4 Reference Manual :: 9.2 Database Backup Methods"
[2]: https://hub.docker.com/_/mysql/tags?name=8.4&utm_source=chatgpt.com "mysql Tags | Docker Hub"
[3]: https://docs.aws.amazon.com/AmazonS3/latest/userguide/default-bucket-encryption.html?utm_source=chatgpt.com "Configuring default encryption - Amazon Simple Storage Service"
[4]: https://dev.mysql.com/doc/refman/8.4/en/replication-options-binary-log.html?utm_source=chatgpt.com "MySQL :: MySQL 8.4 Reference Manual :: 19.1.6.4 Binary Logging Options and Variables"
[5]: https://dev.mysql.com/doc/refman/8.4/en/backup-policy.html?utm_source=chatgpt.com "MySQL :: MySQL 8.4 Reference Manual :: 9.3.1 Establishing a Backup Policy"
[6]: https://dev.mysql.com/doc/refman/8.4/en/recovery-from-backups.html?utm_source=chatgpt.com "MySQL :: MySQL 8.4 Reference Manual :: 9.3.2 Using Backups for Recovery"
[7]: https://dev.mysql.com/doc/refman/8.4/en/mysqlbinlog.html?utm_source=chatgpt.com "MySQL :: MySQL 8.4 Reference Manual :: 6.6.9 mysqlbinlog — Utility for Processing Binary Log Files"
[8]: https://dev.mysql.com/doc/mysql-enterprise-backup/8.4/en/advanced.point.html?utm_source=chatgpt.com "MySQL :: MySQL Enterprise Backup 8.4 User's Guide :: 5.3 Point-in-Time Recovery"
[9]: https://dev.mysql.com/doc/refman/8.4/en/point-in-time-recovery.html?ff=nopfpls&utm_source=chatgpt.com "MySQL :: MySQL 8.4 Reference Manual :: 9.5 Point-in-Time (Incremental) Recovery"
