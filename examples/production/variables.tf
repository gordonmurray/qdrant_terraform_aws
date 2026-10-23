variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-west-1"
}

variable "ami_id" {
  description = "Tested Amazon Linux 2023 AMI ID to pin for all nodes (arm64 for the default Graviton instance type)."
  type        = string
}

variable "nlb_certificate_arn" {
  description = "ACM certificate ARN for the NLB TLS listeners."
  type        = string
}

variable "nlb_hostname" {
  description = "DNS name covered by the certificate. Create an alias from it to the NLB (see the nlb_dns_name output)."
  type        = string
}

variable "client_security_group_ids" {
  description = "Security groups of the applications allowed to reach Qdrant."
  type        = list(string)
}

variable "alarm_sns_topic_arn" {
  description = "SNS topic wired to your paging tool."
  type        = string
}
