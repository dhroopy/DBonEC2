# Deploy guide

Two machines, two scripts. Do not mix them up.

| Where you are | What you run | What it does |
| --- | --- | --- |
| **Your Mac / laptop** | `./infra/bootstrap-s3-iam.sh` | Creates S3 + IAM. Does **not** create EC2. Does **not** install MySQL. |
| **The EC2 instance** | `sudo ./install.sh` | Installs Docker, mounts the data disk, starts MySQL 8.4, enables backup timers. |

`install.sh` exits immediately on macOS. You always SSH into Ubuntu and run it there.

```text
Your Mac                         AWS                         EC2 (Ubuntu)
───────                          ───                         ────────────
Create EC2 + disk + SGs  ───►    instance + EBS + SGs
clone this repo
bootstrap-s3-iam.sh      ───►    S3 bucket + IAM role
                                 + instance profile
SSH into the instance  ─────────────────────────────────►  clone this repo
                                                           sudo ./install.sh
                                                     ──►   Docker + MySQL + timers
```

---

## 1. What you create yourself (before any script)

Create these in the AWS console (or with your own Terraform/CLI). The scripts will not make them.

Recommended region: `ap-south-1`.

### Networking (usually already exists)

| Resource | Why |
| --- | --- |
| VPC + subnet | Same network as the application so the app can reach MySQL privately |
| Application security group | The SG already attached to your app servers. Bootstrap can open 3306 from this SG. |

### EC2 instance

| Setting | Value |
| --- | --- |
| Type | `t4g.small` (2 vCPU / 2 GB, ARM64 / Graviton) |
| AMI | Ubuntu 24.04 LTS **ARM64** |
| Key pair | So you can SSH from your Mac |
| Root disk | Default is fine |
| Extra disk | **30 GB gp3 EBS**, attached **before** `install.sh` (shows up as `/dev/nvme1n1` on Nitro) |
| IAM instance profile at launch | Leave empty if you have not run bootstrap yet; or pick `mysql-backup-instance-profile` if you already have |

Put the instance in a **private** subnet if you can. If it is public, still do not open MySQL to the internet.

### Security groups on the MySQL instance

Create a dedicated SG (for example `sg-mysql`) with:

| Direction | Port | Source / dest | Who creates it |
| --- | --- | --- | --- |
| Inbound | 22 (SSH) | Your IP, or a bastion | **You** |
| Inbound | 3306 | Application SG only — never `0.0.0.0/0` | You, or bootstrap if you pass `--mysql-sg` and `--app-sg` |
| Outbound | 443 (HTTPS) | `0.0.0.0/0` or the VPC prefix list for S3 | **You** — needed for apt, Docker Hub, and S3 |
| Outbound | 80 | Optional, for apt HTTP redirects | **You** |

### Do **not** create these by hand

S3 bucket, IAM role, instance profile, IAM policy, Docker, MySQL, passwords, systemd timers. The scripts below create those.

### Optional (only if you are migrating)

An existing RDS instance that this EC2 can reach. Keep it running until cutover is proven. See [cutover.md](cutover.md).

---

## 2. What each script creates

### Laptop: `infra/bootstrap-s3-iam.sh`

Needs AWS CLI + `jq` and **admin** credentials (IAM + S3 + optional EC2). Idempotent.

| Created | Default name | Details |
| --- | --- | --- |
| S3 bucket | whatever you pass as `--bucket` | Private, Block Public Access, versioning, SSE-S3 |
| Lifecycle rules | on that bucket | Expire `mysql/full/` and `mysql/binlogs/` after 14 days |
| IAM role | `mysql-backup-ec2-role` | Trusts `ec2.amazonaws.com` |
| Inline IAM policy | `mysql-backup-s3` | `s3:GetObject` + `s3:PutObject` on `mysql/*` only. **No `s3:DeleteObject`.** No access keys. |
| Instance profile | `mysql-backup-instance-profile` | Wraps the role so EC2 can assume it |

Optional flags (do these in the console if you skip them):

- `--instance-id i-xxxxxxxx` — attach the instance profile (skipped if the instance already has a different profile)
- `--mysql-sg sg-... --app-sg sg-...` — allow TCP 3306 from the app SG into the MySQL SG

### EC2: `sudo ./install.sh`

Run as root on Ubuntu. Safe to re-run. Does **not** overwrite an existing `.env`.

| Created | Where / what |
| --- | --- |
| Packages | Docker Engine, Compose v2 plugin, awscli, jq, zstd |
| Data mount | Extra EBS formatted (only if you confirm) and mounted at `/mnt/mysql-data`, added to `/etc/fstab` |
| App directory | `/opt/mysql-server/` (copy of this repo) |
| Secrets | `/opt/mysql-server/.env` (mode 600) and `secrets/root.cnf` + `secrets/backup.cnf` |
| MySQL | `mysql:8.4` container `mysql84`, binary logging on, database `app`, user `appuser` |
| Backup user | `backup@localhost` inside MySQL |
| Timers | Full backup 02:00 IST, binlogs every 15 minutes, verify Sunday 04:00 |

---

## 3. Path A — drive it from your Mac (recommended)

You use the Mac for AWS admin work and SSH. MySQL is installed **on the instance**.

### A0. One-time tools on the Mac

```bash
brew install awscli jq
aws configure   # admin user/role; region ap-south-1
```

Confirm:

```bash
aws sts get-caller-identity
```

### A1. Create the EC2 resources

In the AWS console, create the instance, extra 30 GB volume, key pair, and security groups from [section 1](#1-what-you-create-yourself-before-any-script). Note:

- instance id (`i-…`)
- MySQL SG id (`sg-…`)
- app SG id (`sg-…`)
- a **globally unique** S3 bucket name (for example `yourorg-mysql-backups-ap-south-1`)

Attach the extra volume now. Do not wait until after install.

### A2. On the Mac — clone and bootstrap S3 + IAM

```bash
git clone <this-repo-url>
cd DBonEC2

./infra/bootstrap-s3-iam.sh \
  --bucket YOUR_BUCKET_NAME \
  --region ap-south-1 \
  --instance-id i-xxxxxxxx \
  --mysql-sg sg-mysql \
  --app-sg sg-app
```

`--instance-id`, `--mysql-sg`, and `--app-sg` are optional. If you omit `--instance-id`, attach instance profile `mysql-backup-instance-profile` in the console (Actions → Security → Modify IAM role). New instances can also be launched with that profile already selected.

IAM attachments can take a minute to show up on the instance.

### A3. On the Mac — SSH into the instance

```bash
ssh -i /path/to/your-key.pem ubuntu@EC2_PRIVATE_OR_PUBLIC_IP
```

Use a bastion or SSM Session Manager if the instance has no public IP.

### A4. On the EC2 — get the repo and install MySQL

```bash
sudo apt-get update -y && sudo apt-get install -y git
git clone <this-repo-url>
cd DBonEC2

sudo ./install.sh --s3-bucket YOUR_BUCKET_NAME
```

The installer lists disks and asks which extra EBS to mount. Typical device: `/dev/nvme1n1`. If the volume is blank it asks you to type `FORMAT` before `mkfs.ext4`.

Unattended, after you have confirmed the device with `lsblk`:

```bash
# already formatted
sudo ./install.sh --non-interactive --device /dev/nvme1n1 --s3-bucket YOUR_BUCKET_NAME

# blank volume (erases the disk)
sudo ./install.sh --non-interactive --device /dev/nvme1n1 --format --s3-bucket YOUR_BUCKET_NAME
```

### A5. On the EC2 — prove it works

```bash
aws sts get-caller-identity          # IAM role, not access keys
aws s3 ls s3://YOUR_BUCKET_NAME/
docker exec -it mysql84 mysql --defaults-extra-file=/run/mysql-secrets/root.cnf
sudo /opt/mysql-server/scripts/health-check.sh
sudo /opt/mysql-server/scripts/backup-full.sh
sudo /opt/mysql-server/scripts/archive-binlogs.sh
sudo /opt/mysql-server/scripts/verify-backup.sh
```

Application login: user `appuser`, password `MYSQL_PASSWORD` in `/opt/mysql-server/.env`. Point the app at the instance **private IP**, port 3306.

---

## 4. Path B — you are already on the EC2 terminal

Use this if you opened a console session (SSH, SSM, or EC2 Instance Connect) and want to work only there.

**Still create the instance, extra EBS, and security groups yourself first** (section 1). `install.sh` does not launch EC2.

### B1. Bootstrap S3 + IAM — still from a machine with admin AWS credentials

A fresh Ubuntu instance cannot create IAM roles or buckets. Run bootstrap on your Mac (Path A2), **or** from any admin shell:

```bash
./infra/bootstrap-s3-iam.sh \
  --bucket YOUR_BUCKET_NAME \
  --region ap-south-1 \
  --instance-id i-xxxxxxxx \
  --mysql-sg sg-mysql \
  --app-sg sg-app
```

Do not put long-lived AWS access keys on the MySQL instance so you can run bootstrap there. Attach `mysql-backup-instance-profile` instead; that role is only allowed to read/write backup objects, not to create IAM.

### B2. On the EC2 — clone and install

```bash
sudo apt-get update -y && sudo apt-get install -y git
git clone <this-repo-url>
cd DBonEC2
sudo ./install.sh --s3-bucket YOUR_BUCKET_NAME
```

Then run the same checks as [A5](#a5-on-the-ec2--prove-it-works).

If you copy files with `scp` instead of `git clone`:

```bash
# from your Mac
scp -i /path/to/your-key.pem -r ./DBonEC2 ubuntu@EC2_IP:~/
# then on EC2
cd ~/DBonEC2
sudo ./install.sh --s3-bucket YOUR_BUCKET_NAME
```

---

## 5. After install

| Check | Command |
| --- | --- |
| IAM role present | `aws sts get-caller-identity` |
| Timers | `systemctl list-timers 'mysql-*'` |
| Logs | `journalctl -u mysql-backup-full.service -n 50` and `/opt/mysql-server/logs/` |

Do not expose 3306 to `0.0.0.0/0`. Do not put `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in `.env`.

RDS migration checklist: [cutover.md](cutover.md).
