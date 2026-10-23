locals {
  # Built from the name so the policy does not depend on the bucket existing.
  snapshot_bucket_arn = "arn:${local.partition}:s3:::${local.snapshot_bucket_name}"
  ec2_arn_prefix      = "arn:${local.partition}:ec2:${local.region}:${local.account_id}"

  iam_statements = concat(
    [
      {
        Sid      = "DescribeForAttach"
        Effect   = "Allow"
        Action   = ["ec2:DescribeNetworkInterfaces", "ec2:DescribeVolumes", "ec2:DescribeInstances", "ec2:DescribeTags"]
        Resource = "*"
      },
      {
        # Only resources tagged for this deployment can be attached.
        Sid    = "AttachOwnStatefulResources"
        Effect = "Allow"
        Action = ["ec2:AttachNetworkInterface", "ec2:AttachVolume"]
        Resource = [
          "${local.ec2_arn_prefix}:network-interface/*",
          "${local.ec2_arn_prefix}:volume/*",
          "${local.ec2_arn_prefix}:instance/*",
        ]
        Condition = { StringEquals = { "aws:ResourceTag/QdrantCluster" = var.name } }
      },
      {
        Sid      = "ClusterStateMarker"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:PutParameter"]
        Resource = aws_ssm_parameter.cluster_state.arn
      },
      {
        Sid      = "ReadApiKeys"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = local.secret_arn
      },
      {
        Sid      = "PutLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.qdrant.arn}:*"
      },
      {
        Sid       = "PutMetrics"
        Effect    = "Allow"
        Action    = ["cloudwatch:PutMetricData"]
        Resource  = "*"
        Condition = { StringEquals = { "cloudwatch:namespace" = ["CWAgent", "Qdrant"] } }
      },
    ],
    [for s in [
      {
        Sid      = "SnapshotBucketList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
        Resource = local.snapshot_bucket_arn
      },
      {
        Sid      = "SnapshotBucketObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
        Resource = "${local.snapshot_bucket_arn}/*"
      },
    ] : s if var.enable_backups],
    [for s in [
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid      = "PullQdrantImage"
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
        Resource = var.ecr_repository_arn
      },
    ] : s if var.ecr_repository_arn != null],
    [for s in [
      {
        Sid      = "UseCustomerManagedKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = var.kms_key_arn
      },
      {
        Sid       = "GrantForEbsAttach"
        Effect    = "Allow"
        Action    = ["kms:CreateGrant"]
        Resource  = var.kms_key_arn
        Condition = { Bool = { "kms:GrantIsForAWSResource" = "true" } }
      },
    ] : s if var.kms_key_arn != null],
  )
}

resource "aws_iam_role" "node" {
  name_prefix = "${var.name}-node-"
  description = "Qdrant EC2 nodes"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "node" {
  name = "qdrant-node"
  role = aws_iam_role.node.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.iam_statements
  })
}

# Session Manager access: there is no SSH and no key pair.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "node" {
  name_prefix = "${var.name}-node-"
  role        = aws_iam_role.node.name

  tags = local.tags
}
