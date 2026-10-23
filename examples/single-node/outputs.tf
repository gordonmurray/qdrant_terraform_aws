output "endpoint" {
  description = "Qdrant REST endpoint (reachable from inside the VPC)."
  value       = module.qdrant.endpoint
}

output "grpc_endpoint" {
  description = "Qdrant gRPC endpoint (reachable from inside the VPC)."
  value       = module.qdrant.grpc_endpoint
}

output "api_key_secret_arn" {
  description = "Secret holding the API keys. Read with: aws secretsmanager get-secret-value --secret-id <arn>"
  value       = module.qdrant.api_key_secret_arn
}

output "autoscaling_group_names" {
  description = "ASG names, one per node. Use with SSM to open a shell or port-forward."
  value       = module.qdrant.autoscaling_group_names
}

output "dashboard_name" {
  description = "CloudWatch dashboard."
  value       = module.qdrant.dashboard_name
}

output "snapshot_bucket" {
  description = "S3 bucket with Qdrant snapshots."
  value       = module.qdrant.snapshot_bucket
}
