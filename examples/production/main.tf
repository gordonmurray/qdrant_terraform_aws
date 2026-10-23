provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "qdrant-prod"
      Environment = "production"
    }
  }
}

module "qdrant" {
  source = "../../modules/qdrant"

  name       = "qdrant-prod"
  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  production_mode = true
  node_subnet_ids = var.node_subnet_ids

  container_image              = var.container_image
  container_image_digest       = var.container_image_digest
  ecr_repository_arn           = var.ecr_repository_arn
  bootstrap_install_packages   = false
  require_cached_image         = true
  disk_alarm_threshold_percent = 70

  node_count          = 3
  instance_type       = "r7g.xlarge"
  data_volume_size_gb = 200

  ami_id              = var.ami_id
  nlb_certificate_arn = var.nlb_certificate_arn
  nlb_hostname        = var.nlb_hostname

  allowed_security_group_ids = var.client_security_group_ids

  alarm_sns_topic_arn = var.alarm_sns_topic_arn
}
