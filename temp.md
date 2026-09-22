./infra/bootstrap-s3-iam.sh \
  --bucket db-bkp-20260922 \
  --region ap-south-1 \
  --instance-id i-0aeb3f43277311796


AWS_PROFILE=mysql-infra-bootstrap ./infra/bootstrap-s3-iam.sh \
  --bucket db-bkp-20260922 \ 
  --region ap-south-1 \
  --instance-id i-0aeb3f43277311796 \
  --mysql-sg sg-mysql \
  --app-sg sg-app

AWS_PROFILE=mysql-infra-bootstrap ./infra/bootstrap-s3-iam.sh \
  --bucket db-bkp-20260922 \
  --region ap-south-1


/opt/mysql-server/scripts/migrate-from-rds.sh \
  --host oswalbrothers.cpthiq4g2y9e.ap-south-1.rds.amazonaws.com \
  --user oswalbrothers \
  --databases 9930pa*,consign*