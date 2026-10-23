resource "random_password" "api_key" {
  count = var.api_key_secret_arn == null ? 1 : 0

  length  = 48
  special = false
}

resource "random_password" "read_only_api_key" {
  count = var.api_key_secret_arn == null ? 1 : 0

  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "api_keys" {
  count = var.api_key_secret_arn == null ? 1 : 0

  name                    = "${var.name}/qdrant-api-keys"
  description             = "Qdrant API keys for ${var.name}"
  recovery_window_in_days = var.secret_recovery_window_days
  kms_key_id              = var.kms_key_arn

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "api_keys" {
  count = var.api_key_secret_arn == null ? 1 : 0

  secret_id = aws_secretsmanager_secret.api_keys[0].id
  secret_string = jsonencode({
    api_key           = random_password.api_key[0].result
    read_only_api_key = random_password.read_only_api_key[0].result
  })
}
