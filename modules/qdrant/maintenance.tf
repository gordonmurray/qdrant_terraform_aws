# The operator role, not the nodes, needs GetItem/PutItem/DeleteItem here.
# Locks do not expire: an interrupted replacement requires operator recovery.
resource "aws_dynamodb_table" "maintenance" {
  name                        = "${var.name}-maintenance"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "LockID"
  deletion_protection_enabled = var.production_mode

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  tags = local.tags
}
