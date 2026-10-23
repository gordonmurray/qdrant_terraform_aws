output "endpoint" {
  description = "Qdrant REST endpoint for clients."
  value       = module.qdrant.endpoint
}

output "nlb_dns_name" {
  description = "Point your nlb_hostname DNS alias at this."
  value       = module.qdrant.nlb_dns_name
}

output "api_key_secret_arn" {
  description = "Secret holding the API keys."
  value       = module.qdrant.api_key_secret_arn
}

output "node_private_ips" {
  description = "Stable private IP of each node."
  value       = module.qdrant.node_private_ips
}
