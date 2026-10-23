# Operations runbook

## Connecting

There is no SSH and no key pair. Use AWS Systems Manager Session Manager (needs the Session Manager plugin for the AWS CLI).

Find a node's instance ID:

```bash
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names <name>-0 \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text
```

Open a shell: `aws ssm start-session --target <instance-id>`

Port-forward Qdrant to your laptop (REST and dashboard at `http://localhost:6333/dashboard`):

```bash
aws ssm start-session --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["6333"],"localPortNumber":["6333"]}'
```

Read the API key:

```bash
aws secretsmanager get-secret-value --secret-id "$(terraform output -raw api_key_secret_arn)" \
  --query SecretString --output text | jq -r .api_key
```

## What runs on a node

| Item | Detail |
| --- | --- |
| Service | `qdrant.service` (systemd) runs the pinned `docker.io/qdrant/qdrant:v<version>` image with host networking |
| Data | EBS volume mounted at `/qdrant/data` (`storage/` and `snapshots/` inside) |
| Config | `/etc/qdrant/production.yaml` (managed) and optional `/etc/qdrant/local.yaml` (from `qdrant_config_overrides`) |
| Secrets | `/etc/qdrant/qdrant.env`, root only, refreshed from Secrets Manager every service start |
| Logs | CloudWatch log group `/qdrant/<name>`, one stream per node |
| Backup timers | `qdrant-snapshot.timer` (daily snapshot and manifest), `qdrant-backup-age.timer` (backup age metric) |
| Canary | `qdrant-canary.timer` runs every minute: authenticated write, read and search, peers and replica health |

On start, the node attaches its own ENI and data volume. That is what lets the Auto Scaling group replace a failed instance without losing the node's IP or data.

## Upgrading Qdrant

1. Read the release notes for every version you skip. Qdrant supports upgrading one minor version at a time; do not skip minors.
2. Take a fresh snapshot (`sudo systemctl start qdrant-snapshot.service`) and confirm it succeeded.
3. Change `qdrant_version` and apply. This creates a new launch template version only.
4. Replace nodes with `scripts/replace-node.sh asg-0 asg-1 asg-2`, one at a time. It needs `QDRANT_URL` and `QDRANT_API_KEY`, refuses to start if the cluster cannot afford to lose a node, waits for full replica health after each node, and stops at the first failure.

Version 1.20 turns internal (node-to-node) authentication on by default when an API key is set. The module always sets an API key on all nodes from the same secret, so this works out of the box.

## Rotating API keys

Never change the primary key and restart nodes one by one: in Qdrant 1.20 nodes authenticate to each other with the API key, so nodes holding different keys reject each other and a cluster can lose quorum. Use the two-key overlap that Qdrant provides (`alt_api_key`). The secret is JSON; the module reads `api_key`, `read_only_api_key` and `alt_api_key` on every service start. Keys may contain only `A-Za-z0-9._~+/=-`, and `api_key` must not be empty (a node refuses to start otherwise).

Let `OLD` be the current key and `NEW` the new one.

1. **Add the new key as alternative.** Set the secret to `{"api_key": OLD, "alt_api_key": NEW, ...}`. Restart nodes one at a time (`sudo systemctl restart qdrant`), waiting for each to be ready. Every node now accepts both keys. Switch your clients to `NEW` any time after this step.
2. **Promote it.** Set `{"api_key": NEW, "alt_api_key": OLD, ...}` and restart nodes one at a time again. Nodes accept both keys throughout, so mixed nodes still talk to each other.
3. **Retire the old key.** Remove `alt_api_key` and restart nodes one at a time.

If you let the module manage the secret, edit the secret value in Secrets Manager directly. Terraform will try to reset it on its next apply (`aws_secretsmanager_secret_version`), so for rotation use `api_key_secret_arn` with a secret you own.

## Patching the OS

Replace nodes with `scripts/replace-node.sh` (it needs `QDRANT_URL` and `QDRANT_API_KEY`). With the default `ami_id = null`, each replacement resolves the latest Amazon Linux 2023 AMI. Set `ami_id` to pin an AMI you have tested.

## Qdrant metrics in CloudWatch

With `enable_qdrant_metrics` (default on), each node's canary reads its own Qdrant `/metrics` once a minute and publishes a curated set to the `Qdrant` namespace: request and failed-response rates (REST and gRPC), maximum and average latency, pending consensus operations, running optimizations, dead replicas, total points and collections, and file descriptor use. They appear on the dashboard. Set `latency_alarm_threshold_seconds` to alarm on the slowest response of the last minute; it has no default because the right value depends on your queries.

These are node-wide numbers. Qdrant can also report per-collection response counts (`/metrics?per_collection=true`, Qdrant 1.18 and later), but publishing one CloudWatch metric per collection would add cost and cardinality as tenants grow. For per-tenant latency, errors and throttling, measure in your application, where the tenant is known. See [multitenancy.md](multitenancy.md).

## Alarms and what to do

| Alarm | Meaning | First steps |
| --- | --- | --- |
| `<node>-node-down` | No in-service instance in the node's ASG | Check the ASG activity history. If the instance keeps failing, read the log group and `journalctl -u qdrant` |
| `<node>-cpu-high` | Sustained high CPU (CloudWatch agent metric) | Check query load and indexing. Scale up or out ([scaling.md](scaling.md)) |
| `<node>-memory-high` | Memory near the limit; Qdrant may be OOM-killed | Use a larger instance, or enable on-disk vectors or quantization |
| `<node>-disk-high` | Data volume filling | Increase `data_volume_size_gb` ([scaling.md](scaling.md)) |
| `<node>-file-descriptors-high` | Qdrant is using over 80% of its file descriptors | Check connection counts and the number of segments; raise limits only after finding the cause |
| `<node>-rest-latency-high` | Slowest REST response above `latency_alarm_threshold_seconds` (only if you set it) | Check running optimizations, disk metrics and the slow queries |
| `<node>-backup-stale` | The last good Qdrant snapshot is older than `backup_age_alarm_hours`, or age is no longer reported | `journalctl -u qdrant-snapshot` on the node; check the bucket, IAM and the `qdrant-backup-age.timer` |
| `<node>-canary-failing` | The authenticated write/read/search canary fails or stops reporting | `journalctl -u qdrant -u qdrant-canary`; restart the service or run `scripts/replace-node.sh` |
| `<node>-cluster-peers-not-ready` | Fewer than `node_count` nodes answer `/readyz` as seen from this node | Check the node that is down or unreachable, and the network between nodes |
| `<node>-replica-deficit` | A shard has fewer Active replicas than its replication factor for 10 minutes | `GET /collections/<name>/cluster`; replicate shards back |
| `<name>-*-unhealthy-targets` | A node fails `/readyz` behind the NLB | Check that node's logs; the ASG does not replace an instance that is running but not ready |

An instance that is running but whose Qdrant process is wedged is not replaced automatically (the ASG uses EC2 health checks, because the NLB targets are IP addresses, not instances). The canary and unhealthy-targets alarms tell you; restart the service or run `scripts/replace-node.sh`.

## Changes that replace a node's data volume, ENI or subnet

Some input changes make Terraform replace a node's stateful resources: `data_volume_snapshot_ids`, `kms_key_arn`, moving a node to a different subnet or AZ, and lowering `node_count`. The Auto Scaling group keeps running (the module never refreshes instances automatically), so Terraform would try to delete a volume or ENI that is still attached and fail with `VolumeInUse` or a similar error.

For each affected node, one at a time:

1. Take a fresh snapshot (EBS and Qdrant) and make sure the cluster can lose that node (all shards have another active replica).
2. Scale its ASG to zero and wait for the instance to terminate:
   `aws autoscaling update-auto-scaling-group --auto-scaling-group-name <node> --min-size 0 --max-size 0 --desired-capacity 0`
3. `terraform apply`. Terraform replaces the resources and sets the ASG back to one instance.

Run `terraform plan` first and look for `must be replaced` on `aws_ebs_volume.data` or `aws_network_interface.node`.

## Using a customer managed KMS key

When `kms_key_arn` is set, the key policy must allow more than the module's IAM role. Auto Scaling launches the instances with an encrypted root volume, using its service-linked role, so add these statements to the key policy (replace the account ID):

```json
{
  "Sid": "AllowAutoScalingServiceLinkedRoleUse",
  "Effect": "Allow",
  "Principal": {"AWS": "arn:aws:iam::<account-id>:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"},
  "Action": ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"],
  "Resource": "*"
},
{
  "Sid": "AllowAutoScalingServiceLinkedRoleGrants",
  "Effect": "Allow",
  "Principal": {"AWS": "arn:aws:iam::<account-id>:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"},
  "Action": "kms:CreateGrant",
  "Resource": "*",
  "Condition": {"Bool": {"kms:GrantIsForAWSResource": "true"}}
}
```

See the AWS documentation "Required AWS KMS key policy for use with encrypted volumes" for Auto Scaling. This path has not been exercised end to end; test it in a sandbox first.

See [production.md](production.md) for the production profile, what the module cannot promise, and the failure drills to run before go-live.

## Known limitations

- Only Nitro instance types are supported (the boot script finds the data volume by its NVMe device name).
- `container_image` must be pullable without credentials. Private registries (for example ECR) are not wired up.
- Node-to-node traffic is not encrypted. It stays inside your VPC and is protected by security groups and the API key. TLS to clients is available at the NLB with an ACM certificate; set `nlb_hostname` to the DNS name the certificate covers and point it at the NLB.
- A node runs in one AZ. If that AZ fails, the node is unavailable until it recovers. Cross-AZ replication (`replication_factor` of 2 or more, with subnets in several AZs) is what keeps the cluster serving.
- There is no automatic rebalancing ([scaling.md](scaling.md)).
- Instances need outbound internet access (NAT gateway) for package installation and the image pull. For locked-down networks, provide VPC endpoints plus a package mirror and an open image mirror via `container_image`.
