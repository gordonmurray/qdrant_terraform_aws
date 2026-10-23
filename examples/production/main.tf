provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "qdrant-prod"
      Environment = "production"
    }
  }
}

# The example VPC has ONE NAT gateway. For production, bring your own network
# (a NAT gateway per AZ, VPC endpoints) and pass its IDs to the module instead.
module "network" {
  source = "../shared/vpc"

  name = "qdrant-prod"
}

module "qdrant" {
  source = "../../modules/qdrant"

  name       = "qdrant-prod"
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.private_subnet_ids # three AZs

  production_mode = true

  node_count          = 3
  instance_type       = "r7g.xlarge"
  data_volume_size_gb = 200

  ami_id              = var.ami_id
  nlb_certificate_arn = var.nlb_certificate_arn
  nlb_hostname        = var.nlb_hostname

  allowed_security_group_ids = var.client_security_group_ids

  alarm_sns_topic_arn = var.alarm_sns_topic_arn
}
