provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = "qdrant-cluster"
    }
  }
}

module "network" {
  source = "../shared/vpc"

  name = "qdrant-cluster"
}

module "qdrant" {
  source = "../../modules/qdrant"

  name       = "qdrant-cluster"
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.private_subnet_ids

  node_count          = 3
  instance_type       = "r7g.large"
  data_volume_size_gb = 100

  # Clients inside the VPC. Replace with your application's CIDR or security group.
  allowed_cidr_blocks = [module.network.vpc_cidr_block]

  alarm_email = var.alarm_email

  # Throwaway-friendly settings for a learning environment. For anything you
  # care about, keep the defaults (7-day secret recovery, bucket protected).
  secret_recovery_window_days   = 0
  force_destroy_snapshot_bucket = true
}
