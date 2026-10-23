# qdrant module

Runs a self-hosted [Qdrant](https://qdrant.tech) vector database on EC2 and EBS. It supports one node or a multi-node Raft cluster, an optional internal NLB, daily backups, and CloudWatch alarms and dashboards.

See the [project README](../../README.md) for the architecture, a quick start and costs, and [docs/](../../docs) for the runbooks.

## Usage

```hcl
module "qdrant" {
  source = "github.com/gordonmurray/qdrant_terraform_aws//modules/qdrant?ref=v0.1.0"

  name       = "qdrant"
  vpc_id     = "vpc-0123456789abcdef0"
  subnet_ids = ["subnet-aaa", "subnet-bbb", "subnet-ccc"] # private, one per AZ

  node_count    = 3
  instance_type = "r7g.large"

  allowed_cidr_blocks = ["10.0.0.0/16"]
  alarm_email         = "ops@example.com"
}
```

## Behaviour worth knowing

- **Stable identity.** Each node has its own ENI (fixed private IP) and EBS volume, outside the instance. A single-instance Auto Scaling group per node replaces failed instances in the same AZ and re-attaches both.
- **No instance refresh.** Changing `instance_type`, `qdrant_version`, user data or the AMI creates a new launch template version only. You then replace nodes one at a time with `scripts/replace-node.sh`. This avoids replacing every node of a cluster at once.
- **Always cluster mode.** Qdrant runs with `cluster.enabled: true` even for one node, so growing from 1 to 3 needs no reconfiguration of node 0.
- **Secrets.** API keys live in Secrets Manager and are fetched at start-up. They are not in user data. Generated keys are in Terraform state, so use an encrypted remote backend.
- **Scaling in destroys data.** Lowering `node_count` removes the highest-index node and its volume (a final EBS snapshot is kept by default). Move shards off first: see [docs/scaling.md](../../docs/scaling.md).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.10 |
| aws | >= 6.0, < 7.0 |
| random | ~> 3.6 |

## Providers

| Name | Version |
|------|---------|
| aws | >= 6.0, < 7.0 |
| random | ~> 3.6 |
| terraform | n/a |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_autoscaling_group.node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/autoscaling_group) | resource |
| [aws_cloudwatch_dashboard.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_dashboard) | resource |
| [aws_cloudwatch_log_group.qdrant](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_metric_alarm.backup_age](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.canary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.cpu](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.disk](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.file_descriptors](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.memory](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.node_down](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.peer_count](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.replica_deficit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.rest_latency](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.unhealthy_targets](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_dlm_lifecycle_policy.ebs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/dlm_lifecycle_policy) | resource |
| [aws_ebs_volume.data](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ebs_volume) | resource |
| [aws_iam_instance_profile.node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_role.dlm](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.dlm](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.ssm](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_launch_template.node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_template) | resource |
| [aws_lb.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb) | resource |
| [aws_lb_listener.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_listener) | resource |
| [aws_lb_target_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_target_group) | resource |
| [aws_lb_target_group_attachment.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_target_group_attachment) | resource |
| [aws_network_interface.node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/network_interface) | resource |
| [aws_placement_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/placement_group) | resource |
| [aws_s3_bucket.snapshots](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.snapshots](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_ownership_controls.snapshots](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.snapshots](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.snapshots](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.snapshots](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.snapshots](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_secretsmanager_secret.api_keys](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.api_keys](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_security_group.nlb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group.node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_sns_topic.alarms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic) | resource |
| [aws_sns_topic_policy.alarms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_policy) | resource |
| [aws_sns_topic_subscription.email](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_subscription) | resource |
| [aws_ssm_parameter.cluster_state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [aws_vpc_security_group_egress_rule.nlb_to_nodes](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.node_all](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.nlb_client_cidr](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.nlb_client_sg](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.node_client_cidr](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.node_client_sg](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.node_from_nlb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.node_self](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [random_password.api_key](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_password.read_only_api_key](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [terraform_data.production_guard](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_ec2_instance_type.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ec2_instance_type) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_subnet.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| name | Name of the Qdrant deployment. Used as a prefix for every resource and as the value of the `QdrantCluster` tag. | `string` | n/a | yes |
| subnet\_ids | Private subnet IDs (with outbound internet access, e.g. via NAT) to place nodes in. Node `i` uses `subnet_ids[i % length(subnet_ids)]`, so pass one subnet per AZ for a multi-AZ cluster. | `list(string)` | n/a | yes |
| vpc\_id | ID of the VPC to deploy into. | `string` | n/a | yes |
| alarm\_email | Email address to subscribe to the module-created SNS topic. Ignored when `alarm_sns_topic_arn` is set. The recipient must confirm the subscription. | `string` | `null` | no |
| alarm\_sns\_kms\_key\_id | Customer managed KMS key ID, ARN or alias to encrypt the module-created SNS topic. The key policy must allow `cloudwatch.amazonaws.com` to use it. When null the topic is unencrypted, because CloudWatch cannot publish to a topic using the AWS managed SNS key. | `string` | `null` | no |
| alarm\_sns\_topic\_arn | Existing SNS topic ARN for alarm notifications. When null and monitoring is enabled, the module creates a topic. | `string` | `null` | no |
| allowed\_cidr\_blocks | IPv4 CIDR blocks allowed to reach the Qdrant REST (6333) and gRPC (6334) ports. | `list(string)` | `[]` | no |
| allowed\_security\_group\_ids | Security group IDs allowed to reach the Qdrant REST (6333) and gRPC (6334) ports. | `list(string)` | `[]` | no |
| ami\_id | AMI ID to use. When null, the latest Amazon Linux 2023 AMI is resolved from SSM each time a node is (re)launched. Pin an AMI for reproducible replacements. | `string` | `null` | no |
| api\_key\_secret\_arn | ARN of an existing Secrets Manager secret holding JSON `{"api_key": "...", "read_only_api_key": "..."}` (`read_only_api_key` is optional). When null, the module generates both keys and stores them in a new secret. Generated keys are kept in Terraform state, so use an encrypted remote backend. | `string` | `null` | no |
| architecture | CPU architecture of the instance type: `arm64` (Graviton) or `x86_64`. Selects the Amazon Linux 2023 AMI. The Qdrant image is multi-arch. | `string` | `"arm64"` | no |
| backup\_age\_alarm\_hours | Alarm when a node's last successful Qdrant snapshot is older than this many hours. The snapshot runs daily, so keep this above 24. | `number` | `26` | no |
| container\_image | Container image repository, without tag. Must be pullable without authentication from the instances (a public registry or an open mirror). Private registries such as ECR need credentials that this module does not configure. | `string` | `"docker.io/qdrant/qdrant"` | no |
| cpu\_alarm\_threshold\_percent | CPU utilisation (percent) that triggers the CPU alarm. | `number` | `80` | no |
| data\_volume\_iops | Provisioned IOPS of the data volume. gp3: 3000-16000, at most 500 per GiB. io2: 100-256000, at most 1000 per GiB; above 64000 needs an instance type that supports io2 Block Express. | `number` | `3000` | no |
| data\_volume\_size\_gb | Size of each node's persistent data volume in GiB. Can be increased in place; it cannot be decreased. | `number` | `50` | no |
| data\_volume\_snapshot\_ids | Map of node index (as a string, for example "0") to an EBS snapshot ID to create that node's data volume from. Changing an entry replaces the volume; see docs/backup-restore.md before using it. | `map(string)` | `{}` | no |
| data\_volume\_throughput | Provisioned throughput in MiB/s (125-1000). Applies to gp3 only; io2 throughput follows its IOPS and is ignored here. | `number` | `125` | no |
| data\_volume\_type | EBS type of the data volume: `gp3` (default) or `io2` for sustained IOPS beyond gp3's 16000 limit and more consistent latency, at a higher price. Changing it later modifies the volume in place (EBS allows one modification per volume every 6 hours). | `string` | `"gp3"` | no |
| default\_replication\_factor | Default `replication_factor` for NEW collections (Qdrant `storage.collection.replication_factor`). Existing collections are not changed. Null leaves Qdrant's default of 1, except in `production_mode`, which uses 3 (or the node count if lower). | `number` | `null` | no |
| default\_strict\_mode\_config | Qdrant strict-mode defaults for NEW collections (`storage.collection.strict_mode`), for example `{ enabled = true, max_query_limit = 100, unindexed_filtering_retrieve = false }`. Existing collections are not changed. Limits apply per replica and are not per-tenant quotas. Null leaves strict mode off. See docs/multitenancy.md. | `any` | `null` | no |
| default\_write\_consistency\_factor | Default `write_consistency_factor` for NEW collections: how many replicas must apply a write before it succeeds. Must not exceed the replication factor. Null leaves Qdrant's default of 1, except in `production_mode`, which uses a majority of the replication factor. | `number` | `null` | no |
| detailed\_monitoring | Enable EC2 detailed monitoring (1-minute metrics, extra cost). | `bool` | `false` | no |
| disk\_alarm\_threshold\_percent | Data volume utilisation (percent) that triggers the disk alarm. | `number` | `80` | no |
| ebs\_snapshot\_retention\_count | Number of daily EBS snapshots to keep per volume. | `number` | `7` | no |
| ebs\_snapshot\_time\_utc | Time of day (UTC, HH:MM) for the daily EBS snapshot. | `string` | `"03:00"` | no |
| enable\_backups | Enable EBS snapshots (Data Lifecycle Manager) and daily Qdrant snapshots to S3. | `bool` | `true` | no |
| enable\_monitoring | Create CloudWatch alarms, a dashboard, and install the CloudWatch agent for memory and disk metrics. | `bool` | `true` | no |
| enable\_nlb | Create an internal Network Load Balancer in front of the nodes. Client rules then apply to the NLB, and nodes only accept traffic from it. | `bool` | `true` | no |
| enable\_qdrant\_metrics | Publish a curated set of Qdrant's own Prometheus metrics (request rate, failures, latency, pending consensus operations, running optimizations, dead replicas, file descriptors, point counts) to CloudWatch from each node, once a minute. Adds about a dozen custom metrics per node. | `bool` | `true` | no |
| final\_snapshot\_on\_destroy | Take a final EBS snapshot of each data volume when it is destroyed (including when `node_count` is lowered). | `bool` | `true` | no |
| force\_destroy\_snapshot\_bucket | Allow `terraform destroy` to delete the snapshot bucket even when it contains objects. | `bool` | `false` | no |
| instance\_type | EC2 instance type. Qdrant is memory- and disk-bound; r-family instances give the best RAM per dollar. Any instance type is covered by Compute Savings Plans. | `string` | `"m7g.large"` | no |
| jwt\_rbac\_enabled | Enable Qdrant JWT role-based access control (`service.jwt_rbac`). Your backend can then issue short-lived tokens limited to read or read-write on named collections, so tenants never hold the global API keys. Tokens are signed with the primary `api_key`, so rotating that key invalidates every issued token. See docs/multitenancy.md. | `bool` | `false` | no |
| kms\_key\_arn | Customer managed KMS key ARN for the EBS volumes, Secrets Manager secret and snapshot bucket. The key policy must also allow the Auto Scaling service-linked role (`AWSServiceRoleForAutoScaling`) to use the key and create grants, or instance launches fail; see docs/operations.md. When null, AWS managed keys and S3 SSE-S3 are used. | `string` | `null` | no |
| latency\_alarm\_threshold\_seconds | Alarm when a node's slowest REST response in the last minute exceeds this many seconds (Qdrant's `rest_responses_max_duration_seconds`). Null disables the alarm, because a sensible value depends on your queries. | `number` | `null` | no |
| log\_level | Qdrant log level. | `string` | `"INFO"` | no |
| log\_retention\_days | Retention of the Qdrant container log group. Must be a value CloudWatch Logs accepts. | `number` | `30` | no |
| memory\_alarm\_threshold\_percent | Memory utilisation (percent) that triggers the memory alarm. | `number` | `85` | no |
| nlb\_certificate\_arn | ACM certificate ARN. When set, the NLB terminates TLS on ports 6333 and 6334 and forwards plain TCP to the nodes. When null, the NLB listeners are plain TCP. Node-to-node traffic is never encrypted by this module. | `string` | `null` | no |
| nlb\_hostname | DNS name that matches `nlb_certificate_arn` (for example `qdrant.example.com`). Create a DNS alias from it to the NLB yourself. When set, the `endpoint` and `grpc_endpoint` outputs use it instead of the AWS-generated NLB name, which a certificate cannot cover. | `string` | `null` | no |
| node\_count | Number of Qdrant nodes. Qdrant always runs in cluster (Raft) mode, so you can grow from 1 later. Use 1 for experiments and 3 or more for fault tolerance; 2 nodes cannot keep Raft quorum if one fails. | `number` | `1` | no |
| placement\_group\_strategy | EC2 placement group for the nodes: `spread` puts each node on separate hardware (also works across AZs), `cluster` packs nodes together for the lowest network latency but only works when all nodes share one AZ, and null uses no placement group. A `cluster` group trades away AZ-level fault tolerance. | `string` | `null` | no |
| production\_mode | Turn the safety warnings into hard errors for a customer-facing deployment: at least 3 nodes spread so losing any one AZ keeps quorum, TLS on the NLB, backups and monitoring on, an alarm destination, a pinned `ami_id`, a final snapshot on destroy, and a 7-day secret recovery window. Also defaults new collections to replication factor 3 and write consistency 2. See docs/production.md. | `bool` | `false` | no |
| qdrant\_config\_overrides | Extra Qdrant configuration, written to `config/local.yaml` and deep-merged over the module's own settings by Qdrant. Example: `{ storage = { performance = { max_search_threads = 4 } } }`. Do not put secrets here. | `any` | `{}` | no |
| qdrant\_snapshot\_retention\_days | Days to keep Qdrant snapshots (and noncurrent versions) in S3. | `number` | `14` | no |
| qdrant\_snapshot\_schedule | systemd `OnCalendar` expression for the daily Qdrant-native snapshot to S3 on each node. | `string` | `"*-*-* 02:00:00 UTC"` | no |
| qdrant\_version | Qdrant image tag without the leading `v` (for example `1.20.0`). Pin an exact version; never use `latest`. | `string` | `"1.20.0"` | no |
| root\_volume\_size\_gb | Size of each node's root volume in GiB. | `number` | `20` | no |
| secret\_recovery\_window\_days | Recovery window for the generated secret. Use 0 to delete immediately on destroy (handy for throwaway environments). | `number` | `7` | no |
| tags | Tags applied to all resources. Tag keys you use for cost allocation are inherited by instances and volumes. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| alarm\_sns\_topic\_arn | SNS topic receiving alarm notifications, or null when monitoring is disabled. |
| api\_key\_secret\_arn | ARN of the Secrets Manager secret holding the Qdrant API keys. |
| autoscaling\_group\_names | Auto Scaling group name of each node, keyed by node index. |
| dashboard\_name | CloudWatch dashboard name, or null when monitoring is disabled. |
| data\_volume\_ids | EBS data volume ID of each node, keyed by node index. |
| endpoint | Base URL clients should use (NLB when enabled, otherwise node 0). Scheme is https only when `nlb_certificate_arn` is set. |
| grpc\_endpoint | Host:port for gRPC clients (NLB when enabled, otherwise node 0). |
| iam\_role\_arn | ARN of the IAM role used by the Qdrant instances. |
| log\_group\_name | CloudWatch log group receiving the Qdrant container logs. |
| nlb\_dns\_name | DNS name of the internal NLB, or null when `enable_nlb` is false. |
| nlb\_security\_group\_id | Security group of the NLB, or null when `enable_nlb` is false. |
| node\_names | Name of each node (also the name of its Auto Scaling group), keyed by node index. |
| node\_private\_ips | Stable private IP of each node, keyed by node index. |
| security\_group\_id | Security group attached to the Qdrant nodes. Add it as a source in other security groups only if you want to trust the nodes. |
| snapshot\_bucket | Name of the S3 bucket holding Qdrant snapshots, or null when backups are disabled. |
<!-- END_TF_DOCS -->
