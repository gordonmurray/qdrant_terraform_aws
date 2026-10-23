##############################################################################
# Layer 1: Qdrant-native snapshots in S3
##############################################################################

# Server access logging is left to the account owner (it needs a separate log bucket).
#trivy:ignore:AWS-0089
resource "aws_s3_bucket" "snapshots" {
  count = var.enable_backups ? 1 : 0

  bucket        = local.snapshot_bucket_name
  force_destroy = var.force_destroy_snapshot_bucket

  tags = local.tags
}

resource "aws_s3_bucket_public_access_block" "snapshots" {
  count = var.enable_backups ? 1 : 0

  bucket                  = aws_s3_bucket.snapshots[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "snapshots" {
  count = var.enable_backups ? 1 : 0

  bucket = aws_s3_bucket.snapshots[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "snapshots" {
  count = var.enable_backups ? 1 : 0

  bucket = aws_s3_bucket.snapshots[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "snapshots" {
  count = var.enable_backups ? 1 : 0

  bucket = aws_s3_bucket.snapshots[0].id

  rule {
    bucket_key_enabled = var.kms_key_arn != null

    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn != null ? "aws:kms" : "AES256"
      kms_master_key_id = var.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "snapshots" {
  count = var.enable_backups ? 1 : 0

  bucket = aws_s3_bucket.snapshots[0].id

  rule {
    id     = "expire-snapshots"
    status = "Enabled"

    filter {}

    expiration {
      days = var.qdrant_snapshot_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.qdrant_snapshot_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 2
    }
  }

  depends_on = [aws_s3_bucket_versioning.snapshots]
}

resource "aws_s3_bucket_policy" "snapshots" {
  count = var.enable_backups ? 1 : 0

  bucket = aws_s3_bucket.snapshots[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.snapshots[0].arn, "${aws_s3_bucket.snapshots[0].arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.snapshots]
}

##############################################################################
# Layer 2: EBS snapshots (crash-consistent, fastest whole-node restore)
##############################################################################

resource "aws_iam_role" "dlm" {
  count = var.enable_backups ? 1 : 0

  name_prefix = "${var.name}-dlm-"
  description = "Data Lifecycle Manager role for ${var.name} EBS snapshots"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "dlm" {
  count = var.enable_backups ? 1 : 0

  role       = aws_iam_role.dlm[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "ebs" {
  count = var.enable_backups ? 1 : 0

  description        = "Daily snapshots of ${var.name} Qdrant data volumes"
  execution_role_arn = aws_iam_role.dlm[0].arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { QdrantBackup = var.name }

    schedule {
      name = "daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = [var.ebs_snapshot_time_utc]
      }

      retain_rule {
        count = var.ebs_snapshot_retention_count
      }

      copy_tags = true

      tags_to_add = merge(local.tags, { SnapshotCreator = "dlm" })
    }
  }

  tags = local.tags

  depends_on = [aws_iam_role_policy_attachment.dlm]
}
