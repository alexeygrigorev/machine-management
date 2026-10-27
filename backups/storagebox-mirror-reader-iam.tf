# Dedicated READ-ONLY IAM principal for the Hetzner Storagebox mirror job.
#
# Purpose: replace AWS_PROFILE=main-temp (forbidden static main-account key)
# and the phone AWS Gate (unattended HTTP 403) with a least-privilege
# credential scoped to s3://dtc-coolify-backups-387546586013/coolify/*.
#
# Apply in DataTalksClub/aws-infra (MAIN account), e.g. copy into
# main/coolify-backups/iam-storagebox-reader.tf and `terraform apply` there.
# This file lives in machine-management so the mirror job documents its own
# credential requirement; the canonical apply site stays aws-infra.
#
# NO SECRETS IN GIT: this file creates the user + policy only. Create the
# access key out-of-band:
#   aws iam create-access-key --user-name storagebox-mirror-reader
# store it ONLY as the cron user's private AWS profile
#   [profile storagebox-mirror-reader]  (region eu-west-1)
# and never commit it.
#
# Permissions: Get/List ONLY on coolify/* — no Put, no Delete, no bucket
# creation, no IAM, no other prefixes. The mirror job never deletes from S3
# (sync has no --delete; pruning is local to Storagebox only).

resource "aws_iam_user" "storagebox_mirror_reader" {
  name = "storagebox-mirror-reader"

  tags = {
    Name    = "StorageboxMirrorReader"
    Purpose = "HetznerStorageboxS3MirrorReadOnly"
    Project = "coolify-backups"
  }
}

resource "aws_iam_user_policy" "storagebox_mirror_reader" {
  name = "storagebox-mirror-reader-readonly"
  user = aws_iam_user.storagebox_mirror_reader.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ListCoolifyPrefix"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = "arn:aws:s3:::dtc-coolify-backups-387546586013"
        Condition = {
          StringLike = {
            "s3:prefix" = ["", "coolify", "coolify/*"]
          }
        }
      },
      {
        Sid    = "GetCoolifyObjectsOnly"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "arn:aws:s3:::dtc-coolify-backups-387546586013/coolify/*"
      },
    ]
  })
}
