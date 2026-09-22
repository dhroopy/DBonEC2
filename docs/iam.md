# Create the IAM role beforehand

Create this **before** you launch the EC2 instance (or attach it right after). The MySQL host uses an instance profile to write backups to S3. There are no AWS access keys on the machine.

You can skip this page and let `./infra/bootstrap-s3-iam.sh` create the same role. If you already created it in the console, bootstrap is idempotent and will reuse it.

There are **two** identities. Do not mix their permissions.

| Identity | Where it lives | Purpose |
| --- | --- | --- |
| **EC2 instance role** (this page) | Attached to the MySQL instance | Get/put backup objects in one bucket |
| **Laptop / admin user** | Your Mac, SSO, or console login | Create the bucket, role, instance, and security groups |

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

## 2. Laptop / admin identity

Only needed if you run `./infra/bootstrap-s3-iam.sh` or create AWS resources from the CLI. This is **your** user or SSO role, not the instance role.

Typical permissions:

| Service | Actions |
| --- | --- |
| S3 | `CreateBucket`, `HeadBucket`, `PutBucketPublicAccessBlock`, `PutBucketVersioning`, `PutBucketEncryption`, `PutBucketLifecycleConfiguration` |
| IAM | `CreateRole`, `GetRole`, `PutRolePolicy`, `CreateInstanceProfile`, `GetInstanceProfile`, `AddRoleToInstanceProfile` |
| EC2 (optional) | `AssociateIamInstanceProfile`, `DescribeIamInstanceProfileAssociations`, `AuthorizeSecurityGroupIngress` |

Do **not** put these admin permissions on the MySQL instance role. Do not put `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in `.env` or on the instance.
