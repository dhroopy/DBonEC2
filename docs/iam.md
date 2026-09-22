# IAM identities

There are **two** identities. Do not mix their permissions or copy laptop access keys onto EC2.

| Identity | What it is | Purpose |
| --- | --- | --- |
| **Laptop bootstrap user** ([section 2](#2-laptop-bootstrap-user-access-keys-on-your-mac)) | IAM **user** + access keys on your Mac | Run `./infra/bootstrap-s3-iam.sh` (create bucket + EC2 role) |
| **EC2 instance role** ([section 1](#1-ec2-instance-role)) | IAM **role** attached to the instance | Daily backups / restore. **No access keys.** |

The instance role can be created in the console, or by the bootstrap script using the laptop user.

---

## 1. EC2 instance role

### Console steps

1. IAM → **Roles** → **Create role**
2. Trusted entity: **AWS service** → **EC2**
3. Permissions: **do not attach any AWS managed policy** (skip `AmazonS3FullAccess`, `AdministratorAccess`, and similar)
4. Role name: `mysql-backup-ec2-role`
5. Create the role
6. Open the role → **Add permissions** → **Create inline policy** → JSON
7. Paste the policy below, replace `YOUR_BUCKET_NAME`, then save as `mysql-backup-s3`

Creating an EC2 role also creates instance profile `mysql-backup-ec2-role` with the same name. If you prefer the name this repo uses, create an instance profile called `mysql-backup-instance-profile` and add the role to it. Either name is fine as long as you select that profile on the instance.

### Permission policy

Assign **no AWS managed policies**. This custom policy is enough for backups, binlog archives, restore, and verify.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBackupBucket",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": "arn:aws:s3:::YOUR_BUCKET_NAME"
    },
    {
      "Sid": "BackupObjects",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:AbortMultipartUpload"
      ],
      "Resource": "arn:aws:s3:::YOUR_BUCKET_NAME/mysql/*"
    }
  ]
}
```

The same JSON lives in [`infra/iam-policy.json`](../infra/iam-policy.json).

| Allowed | Why |
| --- | --- |
| `s3:ListBucket`, `s3:GetBucketLocation` | `aws s3 ls` and `list-objects-v2` (verify / PITR) |
| `s3:ListBucketMultipartUploads`, `s3:AbortMultipartUpload` | Large `aws s3 cp` uploads |
| `s3:GetObject` | Download backups and binlogs; `head-object` after upload |
| `s3:PutObject` | Upload full dumps, binlogs, manifests |

`aws sts get-caller-identity` works with no extra permission.

### Do not attach

- `AmazonS3FullAccess` / `AdministratorAccess` / `IAMFullAccess`
- `s3:DeleteObject` — S3 lifecycle expires objects after 14 days
- IAM, EC2, RDS, SSM, CloudWatch, KMS, Secrets Manager

The instance talks to RDS over MySQL (port 3306), not the RDS API, so it needs no RDS IAM policy. Pick the bucket name first; the policy can exist before the bucket does.

### Attach to EC2

On **Launch instance** → IAM instance profile, select `mysql-backup-ec2-role` or `mysql-backup-instance-profile`.

If the instance already exists: EC2 → instance → **Actions** → **Security** → **Modify IAM role**.

Wait about a minute, SSH in, and confirm:

```bash
aws sts get-caller-identity
aws s3 ls s3://YOUR_BUCKET_NAME/
```

You should see an assumed role (`mysql-backup-ec2-role`), not an IAM user and not access keys.

---

## 2. Laptop bootstrap user (access keys on your Mac)

`./infra/bootstrap-s3-iam.sh` talks to AWS from **your Mac**. The CLI needs credentials. That is this user — not the EC2 instance role.

If you already have an admin / SSO user on the Mac (`aws sts get-caller-identity` works), you can use that and skip this section. Create the user below when you want a dedicated, least-privilege access key instead of `AdministratorAccess`.

### Console steps

1. IAM → **Users** → **Create user**
2. User name: `mysql-infra-bootstrap`
3. Do **not** enable AWS Management Console access (CLI only)
4. **Attach policies directly** → **Create policy** → JSON
5. Paste the policy below, replace `YOUR_BUCKET_NAME`, create it as `mysql-infra-bootstrap`
6. Attach that policy to the user (no AWS managed policies)
7. Open the user → **Security credentials** → **Access keys** → **Create access key** → use case **Command Line Interface (CLI)**
8. Save the Access key ID and Secret access key (download the CSV). You will not see the secret again.

Do **not** put these keys on the EC2 instance, in `.env`, or in git.

### Permission policy

Same JSON as [`infra/bootstrap-admin-policy.json`](../infra/bootstrap-admin-policy.json). Replace `YOUR_BUCKET_NAME` with the bucket the script will create (or reuse).

Do **not** attach `AdministratorAccess`, `IAMFullAccess`, or `AmazonS3FullAccess`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3CreateAndHardenBackupBucket",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket",
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:PutBucketPublicAccessBlock",
        "s3:PutBucketVersioning",
        "s3:PutEncryptionConfiguration",
        "s3:PutLifecycleConfiguration"
      ],
      "Resource": "arn:aws:s3:::YOUR_BUCKET_NAME"
    },
    {
      "Sid": "IamBackupRoleAndProfile",
      "Effect": "Allow",
      "Action": [
        "iam:GetRole",
        "iam:CreateRole",
        "iam:PutRolePolicy",
        "iam:GetInstanceProfile",
        "iam:CreateInstanceProfile",
        "iam:AddRoleToInstanceProfile"
      ],
      "Resource": [
        "arn:aws:iam::*:role/mysql-backup-ec2-role",
        "arn:aws:iam::*:instance-profile/mysql-backup-instance-profile"
      ]
    },
    {
      "Sid": "PassBackupRoleToEc2",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::*:role/mysql-backup-ec2-role",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ec2.amazonaws.com"
        }
      }
    },
    {
      "Sid": "OptionalAttachProfileAndMysqlSg",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeIamInstanceProfileAssociations",
        "ec2:AssociateIamInstanceProfile",
        "ec2:AuthorizeSecurityGroupIngress"
      ],
      "Resource": "*"
    }
  ]
}
```

| Statement | Why |
| --- | --- |
| S3 create + harden | Create the bucket, then block public access, versioning, SSE-S3, 14-day lifecycle |
| IAM role + profile | Create or reuse `mysql-backup-ec2-role` and `mysql-backup-instance-profile` |
| `iam:PassRole` | Needed only if you pass `--instance-id` so EC2 can assume that role |
| Optional EC2 | `--instance-id` (attach profile) and `--mysql-sg` / `--app-sg` (open 3306) |

`sts:GetCallerIdentity` needs no extra permission. This user cannot delete S3 objects, cannot use any other bucket, and cannot create arbitrary IAM roles.

If you will not pass `--instance-id` or the SG flags, you can omit the last two statements and attach the instance profile / 3306 rule in the console instead.

### Configure the Mac

```bash
brew install awscli jq

aws configure --profile mysql-infra-bootstrap
# AWS Access Key ID:     <from the console>
# AWS Secret Access Key: <from the console>
# Default region:        ap-south-1
# Default output:        json
```

Confirm, then run bootstrap with that profile:

```bash
aws sts get-caller-identity --profile mysql-infra-bootstrap

AWS_PROFILE=mysql-infra-bootstrap ./infra/bootstrap-s3-iam.sh \
  --bucket YOUR_BUCKET_NAME \
  --region ap-south-1 \
  --instance-id i-xxxxxxxx \
  --mysql-sg sg-mysql \
  --app-sg sg-app
```

After bootstrap succeeds, you can deactivate or delete this access key. The EC2 instance does not use it; backups use the instance role from [section 1](#1-ec2-instance-role).
