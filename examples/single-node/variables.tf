variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-west-1"
}

variable "alarm_email" {
  description = "Email address for CloudWatch alarm notifications (needs confirming). Leave null to skip the subscription."
  type        = string
  default     = null
}
