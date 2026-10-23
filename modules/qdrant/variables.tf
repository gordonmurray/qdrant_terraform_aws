##############################################################################
# Required
##############################################################################

variable "name" {
  description = "Name of the Qdrant deployment. Used as a prefix for every resource and as the value of the `QdrantCluster` tag."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,19}$", var.name))
    error_message = "name must be 2-20 characters: lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "vpc_id" {
  description = "ID of the VPC to deploy into."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs (with outbound internet access, e.g. via NAT) to place nodes in. Without node_subnet_ids, node `i` uses `subnet_ids[i % length(subnet_ids)]`. Use explicit assignments for production."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "At least one subnet ID is required."
  }
}

##############################################################################
# Qdrant
##############################################################################

variable "qdrant_version" {
  description = "Qdrant image tag without the leading `v` (for example `1.20.0`). Pin an exact version; never use `latest`."
  type        = string
  default     = "1.20.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.qdrant_version))
    error_message = "qdrant_version must look like 1.20.0 (no leading v, no suffix)."
  }
}

variable "production_mode" {
  description = "Turn the safety warnings into hard errors for a customer-facing deployment: exactly 3 nodes in distinct AZs with explicit subnet assignments and an immutable image digest, TLS on the NLB, backups and monitoring on, an alarm destination, a pinned `ami_id`, a final snapshot on destroy, and a 7-day secret recovery window. Requires replication factor 3 and write consistency 2 for new collection defaults. See docs/production.md."
  type        = bool
  default     = false
}

variable "default_replication_factor" {
  description = "Default `replication_factor` for NEW collections (Qdrant `storage.collection.replication_factor`). Existing collections are not changed. Null leaves Qdrant's default of 1, except in `production_mode`, which uses 3 (or the node count if lower)."
  type        = number
  default     = null

  validation {
    condition     = var.default_replication_factor == null || coalesce(var.default_replication_factor, 1) >= 1
    error_message = "default_replication_factor must be at least 1."
  }
}

variable "default_write_consistency_factor" {
  description = "Default `write_consistency_factor` for NEW collections: how many replicas must apply a write before it succeeds. Must not exceed the replication factor. Null leaves Qdrant's default of 1, except in `production_mode`, which uses a majority of the replication factor."
  type        = number
  default     = null

  validation {
    condition     = var.default_write_consistency_factor == null || coalesce(var.default_write_consistency_factor, 1) >= 1
    error_message = "default_write_consistency_factor must be at least 1."
  }
}

variable "jwt_rbac_enabled" {
  description = "Enable Qdrant JWT role-based access control (`service.jwt_rbac`). Your backend can then issue short-lived tokens limited to read or read-write on named collections, so tenants never hold the global API keys. Tokens are signed with the primary `api_key`, so rotating that key invalidates every issued token. See docs/multitenancy.md."
  type        = bool
  default     = false
}

variable "default_strict_mode_config" {
  description = "Qdrant strict-mode defaults for NEW collections (`storage.collection.strict_mode`), for example `{ enabled = true, max_query_limit = 100, unindexed_filtering_retrieve = false }`. Existing collections are not changed. Limits apply per replica and are not per-tenant quotas. Null leaves strict mode off. See docs/multitenancy.md."
  type        = any
  default     = null
}

variable "container_image" {
  description = "Container image repository, without tag. Use ecr_repository_arn for private ECR authentication, or bake the image into the AMI."
  type        = string
  default     = "docker.io/qdrant/qdrant"
}

variable "log_level" {
  description = "Qdrant log level."
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["TRACE", "DEBUG", "INFO", "WARN", "ERROR"], var.log_level)
    error_message = "log_level must be one of TRACE, DEBUG, INFO, WARN, ERROR."
  }
}

variable "qdrant_config_overrides" {
  description = "Extra Qdrant configuration, written to `config/local.yaml` and deep-merged over the module's own settings by Qdrant. Example: `{ storage = { performance = { max_search_threads = 4 } } }`. Do not put secrets here."
  type        = any
  default     = {}
}

variable "api_key_secret_arn" {
  description = "ARN of an existing Secrets Manager secret holding JSON `{\"api_key\": \"...\", \"read_only_api_key\": \"...\"}` (`read_only_api_key` is optional). When null, the module generates both keys and stores them in a new secret. Generated keys are kept in Terraform state, so use an encrypted remote backend."
  type        = string
  default     = null
}

variable "secret_recovery_window_days" {
  description = "Recovery window for the generated secret. Use 0 to delete immediately on destroy (handy for throwaway environments)."
  type        = number
  default     = 7

  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "secret_recovery_window_days must be 0 or between 7 and 30."
  }
}

##############################################################################
# Compute and storage
##############################################################################

variable "node_count" {
  description = "Number of Qdrant nodes. Qdrant always runs in cluster (Raft) mode, so you can grow from 1 later. Use 1 for experiments and 3 or more for fault tolerance; 2 nodes cannot keep Raft quorum if one fails."
  type        = number
  default     = 1

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 12 && floor(var.node_count) == var.node_count
    error_message = "node_count must be a whole number between 1 and 12."
  }
}

variable "instance_type" {
  description = "EC2 instance type. Qdrant is memory- and disk-bound; r-family instances give the best RAM per dollar. Any instance type is covered by Compute Savings Plans."
  type        = string
  default     = "m7g.large"
}

variable "architecture" {
  description = "CPU architecture of the instance type: `arm64` (Graviton) or `x86_64`. Selects the Amazon Linux 2023 AMI. The Qdrant image is multi-arch."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.architecture)
    error_message = "architecture must be arm64 or x86_64."
  }
}

variable "ami_id" {
  description = "AMI ID to use. When null, the latest Amazon Linux 2023 AMI is resolved from SSM each time a node is (re)launched. Pin an AMI for reproducible replacements."
  type        = string
  default     = null
}

variable "root_volume_size_gb" {
  description = "Size of each node's root volume in GiB."
  type        = number
  default     = 20
}

variable "data_volume_size_gb" {
  description = "Size of each node's persistent data volume in GiB. Can be increased in place; it cannot be decreased."
  type        = number
  default     = 50

  validation {
    condition     = var.data_volume_size_gb >= 10
    error_message = "data_volume_size_gb must be at least 10."
  }
}

variable "data_volume_type" {
  description = "EBS type of the data volume: `gp3` (default) or `io2` for sustained IOPS beyond gp3's 16000 limit and more consistent latency, at a higher price. Changing it later modifies the volume in place (EBS allows one modification per volume every 6 hours)."
  type        = string
  default     = "gp3"

  validation {
    condition     = contains(["gp3", "io2"], var.data_volume_type)
    error_message = "data_volume_type must be gp3 or io2."
  }
}

variable "data_volume_iops" {
  description = "Provisioned IOPS of the data volume. gp3: 3000-16000, at most 500 per GiB. io2: 100-256000, at most 1000 per GiB; above 64000 needs an instance type that supports io2 Block Express."
  type        = number
  default     = 3000

  validation {
    condition     = var.data_volume_iops >= 100 && var.data_volume_iops <= 256000
    error_message = "data_volume_iops must be between 100 and 256000 (the allowed range depends on data_volume_type)."
  }
}

variable "data_volume_throughput" {
  description = "Provisioned throughput in MiB/s (125-1000). Applies to gp3 only; io2 throughput follows its IOPS and is ignored here."
  type        = number
  default     = 125

  validation {
    condition     = var.data_volume_throughput >= 125 && var.data_volume_throughput <= 1000
    error_message = "data_volume_throughput must be between 125 and 1000."
  }
}

variable "data_volume_snapshot_ids" {
  description = "Map of node index (as a string, for example \"0\") to an EBS snapshot ID to create that node's data volume from. Changing an entry replaces the volume; see docs/backup-restore.md before using it."
  type        = map(string)
  default     = {}
}

variable "kms_key_arn" {
  description = "Customer managed KMS key ARN for the EBS volumes, Secrets Manager secret and snapshot bucket. The key policy must also allow the Auto Scaling service-linked role (`AWSServiceRoleForAutoScaling`) to use the key and create grants, or instance launches fail; see docs/operations.md. When null, AWS managed keys and S3 SSE-S3 are used."
  type        = string
  default     = null
}

variable "final_snapshot_on_destroy" {
  description = "Take a final EBS snapshot of each data volume when it is destroyed (including when `node_count` is lowered)."
  type        = bool
  default     = true
}

variable "placement_group_strategy" {
  description = "EC2 placement group for the nodes: `spread` puts each node on separate hardware (also works across AZs), `cluster` packs nodes together for the lowest network latency but only works when all nodes share one AZ, and null uses no placement group. A `cluster` group trades away AZ-level fault tolerance."
  type        = string
  default     = null

  validation {
    condition     = var.placement_group_strategy == null || contains(["spread", "cluster"], coalesce(var.placement_group_strategy, "none"))
    error_message = "placement_group_strategy must be null, \"spread\" or \"cluster\"."
  }
}

variable "detailed_monitoring" {
  description = "Enable EC2 detailed monitoring (1-minute metrics, extra cost)."
  type        = bool
  default     = false
}

##############################################################################
# Network access
##############################################################################

variable "allowed_cidr_blocks" {
  description = "IPv4 CIDR blocks allowed to reach the Qdrant REST (6333) and gRPC (6334) ports."
  type        = list(string)
  default     = []
}

variable "allowed_security_group_ids" {
  description = "Security group IDs allowed to reach the Qdrant REST (6333) and gRPC (6334) ports."
  type        = list(string)
  default     = []
}

variable "enable_nlb" {
  description = "Create an internal Network Load Balancer in front of the nodes. Client rules then apply to the NLB, and nodes only accept traffic from it."
  type        = bool
  default     = true
}

variable "nlb_hostname" {
  description = "DNS name that matches `nlb_certificate_arn` (for example `qdrant.example.com`). Create a DNS alias from it to the NLB yourself. When set, the `endpoint` and `grpc_endpoint` outputs use it instead of the AWS-generated NLB name, which a certificate cannot cover."
  type        = string
  default     = null
}

variable "nlb_certificate_arn" {
  description = "ACM certificate ARN. When set, the NLB terminates TLS on ports 6333 and 6334 and forwards plain TCP to the nodes. When null, the NLB listeners are plain TCP. Node-to-node traffic is never encrypted by this module."
  type        = string
  default     = null
}

##############################################################################
# Backups
##############################################################################

variable "enable_backups" {
  description = "Enable EBS snapshots (Data Lifecycle Manager) and daily Qdrant snapshots to S3."
  type        = bool
  default     = true
}

variable "ebs_snapshot_time_utc" {
  description = "Time of day (UTC, HH:MM) for the daily EBS snapshot."
  type        = string
  default     = "03:00"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.ebs_snapshot_time_utc))
    error_message = "ebs_snapshot_time_utc must be HH:MM in 24-hour format."
  }
}

variable "ebs_snapshot_retention_count" {
  description = "Number of daily EBS snapshots to keep per volume."
  type        = number
  default     = 7

  validation {
    condition     = var.ebs_snapshot_retention_count >= 1 && var.ebs_snapshot_retention_count <= 1000
    error_message = "ebs_snapshot_retention_count must be between 1 and 1000."
  }
}

variable "qdrant_snapshot_schedule" {
  description = "systemd `OnCalendar` expression for the daily Qdrant-native snapshot to S3 on each node."
  type        = string
  default     = "*-*-* 02:00:00 UTC"
}

variable "qdrant_snapshot_retention_days" {
  description = "Days to keep Qdrant snapshots (and noncurrent versions) in S3."
  type        = number
  default     = 14

  validation {
    condition     = var.qdrant_snapshot_retention_days >= 1
    error_message = "qdrant_snapshot_retention_days must be at least 1."
  }
}

variable "force_destroy_snapshot_bucket" {
  description = "Allow `terraform destroy` to delete the snapshot bucket even when it contains objects."
  type        = bool
  default     = false
}

##############################################################################
# Monitoring
##############################################################################

variable "enable_monitoring" {
  description = "Create CloudWatch alarms, a dashboard, and install the CloudWatch agent for memory and disk metrics."
  type        = bool
  default     = true
}

variable "alarm_sns_topic_arn" {
  description = "Existing SNS topic ARN for alarm notifications. When null and monitoring is enabled, the module creates a topic."
  type        = string
  default     = null
}

variable "alarm_sns_kms_key_id" {
  description = "Customer managed KMS key ID, ARN or alias to encrypt the module-created SNS topic. The key policy must allow `cloudwatch.amazonaws.com` to use it. When null the topic is unencrypted, because CloudWatch cannot publish to a topic using the AWS managed SNS key."
  type        = string
  default     = null
}

variable "alarm_email" {
  description = "Email address to subscribe to the module-created SNS topic. Ignored when `alarm_sns_topic_arn` is set. The recipient must confirm the subscription."
  type        = string
  default     = null
}

variable "backup_age_alarm_hours" {
  description = "Alarm when a node's last successful Qdrant snapshot is older than this many hours. The snapshot runs daily, so keep this above 24."
  type        = number
  default     = 26
}

variable "enable_qdrant_metrics" {
  description = "Publish a curated set of Qdrant's own Prometheus metrics (request rate, failures, latency, pending consensus operations, running optimizations, dead replicas, file descriptors, point counts) to CloudWatch from each node, once a minute. Adds about a dozen custom metrics per node."
  type        = bool
  default     = true
}

variable "latency_alarm_threshold_seconds" {
  description = "Alarm when a node's slowest REST response in the last minute exceeds this many seconds (Qdrant's `rest_responses_max_duration_seconds`). Null disables the alarm, because a sensible value depends on your queries."
  type        = number
  default     = null
}

variable "cpu_alarm_threshold_percent" {
  description = "CPU utilisation (percent) that triggers the CPU alarm."
  type        = number
  default     = 80
}

variable "memory_alarm_threshold_percent" {
  description = "Memory utilisation (percent) that triggers the memory alarm."
  type        = number
  default     = 85
}

variable "disk_alarm_threshold_percent" {
  description = "Data volume utilisation (percent) that triggers the disk alarm."
  type        = number
  default     = 80
}

variable "log_retention_days" {
  description = "Retention of the Qdrant container log group. Must be a value CloudWatch Logs accepts."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to all resources. Tag keys you use for cost allocation are inherited by instances and volumes."
  type        = map(string)
  default     = {}
}

variable "node_subnet_ids" {
  description = "Explicit subnet assignment keyed by existing numeric node index. Supply every node to keep placement stable when subnet_ids is reordered. Subnets must also appear in subnet_ids."
  type        = map(string)
  default     = {}

  validation {
    condition = length(var.node_subnet_ids) == 0 || (
      toset(keys(var.node_subnet_ids)) == toset([for i in range(var.node_count) : tostring(i)]) &&
      alltrue([for id in values(var.node_subnet_ids) : contains(var.subnet_ids, id)])
    )
    error_message = "node_subnet_ids must contain exactly indices 0 through node_count-1, with values from subnet_ids."
  }
}

variable "container_image_digest" {
  description = "Optional immutable sha256 image digest. Overrides qdrant_version for image selection. Required in production mode."
  type        = string
  default     = null

  validation {
    condition     = var.container_image_digest == null || can(regex("^sha256:[a-f0-9]{64}$", var.container_image_digest))
    error_message = "container_image_digest must be sha256 followed by 64 lowercase hexadecimal characters."
  }
}

variable "ecr_repository_arn" {
  description = "Private ECR repository ARN for container_image. Enables registry login and grants pull access to this repository only. Use a repository in the deployment region."
  type        = string
  default     = null
}

variable "bootstrap_install_packages" {
  description = "Install runtime packages during cloud-init. Set false for a tested AMI with Docker, AWS CLI, jq, XFS tools and the CloudWatch agent already installed."
  type        = bool
  default     = true
}

variable "require_cached_image" {
  description = "Refuse to pull an image at boot. The selected image must already exist in the AMI Docker cache."
  type        = bool
  default     = false
}

variable "nlb_deletion_protection" {
  description = "Protect the NLB from deletion. Null enables protection in production mode."
  type        = bool
  default     = null
}
