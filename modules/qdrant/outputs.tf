output "endpoint" {
  description = "Base URL clients should use (NLB when enabled, otherwise node 0). Scheme is https only when `nlb_certificate_arn` is set."
  value = var.enable_nlb ? (
    "${var.nlb_certificate_arn != null ? "https" : "http"}://${coalesce(var.nlb_hostname, aws_lb.this[0].dns_name)}:${local.rest_port}"
  ) : "http://${aws_network_interface.node["0"].private_ip}:${local.rest_port}"
}

output "grpc_endpoint" {
  description = "Host:port for gRPC clients (NLB when enabled, otherwise node 0)."
  value       = var.enable_nlb ? "${coalesce(var.nlb_hostname, aws_lb.this[0].dns_name)}:${local.grpc_port}" : "${aws_network_interface.node["0"].private_ip}:${local.grpc_port}"
}

output "nlb_dns_name" {
  description = "DNS name of the internal NLB, or null when `enable_nlb` is false."
  value       = var.enable_nlb ? aws_lb.this[0].dns_name : null
}

output "node_private_ips" {
  description = "Stable private IP of each node, keyed by node index."
  value       = { for k, eni in aws_network_interface.node : k => eni.private_ip }
}

output "node_names" {
  description = "Name of each node (also the name of its Auto Scaling group), keyed by node index."
  value       = { for k, n in local.nodes : k => n.name }
}

output "autoscaling_group_names" {
  description = "Auto Scaling group name of each node, keyed by node index."
  value       = { for k, asg in aws_autoscaling_group.node : k => asg.name }
}

output "data_volume_ids" {
  description = "EBS data volume ID of each node, keyed by node index."
  value       = { for k, v in aws_ebs_volume.data : k => v.id }
}

output "security_group_id" {
  description = "Security group attached to the Qdrant nodes. Add it as a source in other security groups only if you want to trust the nodes."
  value       = aws_security_group.node.id
}

output "nlb_security_group_id" {
  description = "Security group of the NLB, or null when `enable_nlb` is false."
  value       = var.enable_nlb ? aws_security_group.nlb[0].id : null
}

output "api_key_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the Qdrant API keys."
  value       = local.secret_arn
}

output "snapshot_bucket" {
  description = "Name of the S3 bucket holding Qdrant snapshots, or null when backups are disabled."
  value       = var.enable_backups ? aws_s3_bucket.snapshots[0].id : null
}

output "log_group_name" {
  description = "CloudWatch log group receiving the Qdrant container logs."
  value       = aws_cloudwatch_log_group.qdrant.name
}

output "alarm_sns_topic_arn" {
  description = "SNS topic receiving alarm notifications, or null when monitoring is disabled."
  value       = local.sns_topic_arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard name, or null when monitoring is disabled."
  value       = var.enable_monitoring ? aws_cloudwatch_dashboard.this[0].dashboard_name : null
}

output "iam_role_arn" {
  description = "ARN of the IAM role used by the Qdrant instances."
  value       = aws_iam_role.node.arn
}
