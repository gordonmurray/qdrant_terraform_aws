# Adopt the production hardening changes

These changes require new inputs for production deployments. The existing numeric Terraform resource addresses remain unchanged.

## Preserve existing resources

1. Record each node's current subnet from Terraform state.
2. Set `node_subnet_ids` to those exact assignments.
3. Keep the existing deployment name and node indices.
4. Run the saved-plan policy before each production apply.

```hcl
node_subnet_ids = {
  "0" = "subnet-existing-node-0"
  "1" = "subnet-existing-node-1"
  "2" = "subnet-existing-node-2"
}
```

The production profile now supports exactly three nodes in three AZs. It requires replication factor three and write consistency two. Larger deployments need a separate policy for replica placement across AZs.

The production example now accepts an existing VPC. If your deployed root owns `module.network`, keep that block until you migrate its state to a network stack. Removing the block without a state migration schedules network deletion.

The NLB and maintenance table have deletion protection in production. Intentional teardown requires a separate reviewed change to remove protection.

## Prepare a production AMI

1. Start a clean Amazon Linux 2023 builder with the target CPU architecture.
2. Choose a reviewed Qdrant image digest for that architecture or its multi-platform manifest.
3. Run `scripts/prepare-ami.sh` as root on the builder.
4. Create an AMI through your image pipeline.
5. Boot a staging node from that AMI and complete the recovery drills.
6. Set `ami_id`, `container_image`, and `container_image_digest` to the tested artifacts.

```bash
sudo env QDRANT_IMAGE='docker.io/qdrant/qdrant@sha256:REPLACE_WITH_DIGEST' \
  bash scripts/prepare-ami.sh
```

For private ECR, supply `ECR_LOGIN=1` and `AWS_REGION` to the builder. Its role needs permission to pull the image. The script uses temporary registry credentials and removes them before exit.

The production example disables package installation and requires the image in the local Docker cache. The module also supports authenticated ECR pulls through `ecr_repository_arn`. That pull path requires network access to ECR and S3.

The AMI still needs access to EC2, Secrets Manager, SSM, CloudWatch Logs, CloudWatch metrics, and S3 at runtime. Configure the required VPC endpoints or resilient egress in the network stack. An AMI cache does not remove these dependencies.

## Configure remote state

Use separate state buckets or restricted prefixes for staging and production. The state bucket belongs in a separate foundation stack. Enable versioning and restrict access to the state and its KMS key.

1. Copy `examples/production/backend.hcl.example` to a local backend configuration file.
2. Replace the bucket and KMS key placeholders.
3. Initialize the backend.

```bash
cd examples/production
terraform init -backend-config=backend.hcl
```

For an existing local state, use `terraform init -migrate-state -backend-config=backend.hcl`. Preserve a secure state backup before migration. Never put AWS credentials in the backend file.

S3 locking uses `use_lockfile = true`. The operator needs access to the `.tflock` object as well as the state. See the [Terraform S3 backend documentation](https://developer.hashicorp.com/terraform/language/backend/s3).

## Review and apply a saved plan

```bash
# From the deployment root:
../../scripts/plan-production.sh -var-file=production.tfvars
terraform apply production.tfplan
```

The script rejects deletion or replacement of persistent resources and network resources. It also rejects reduced ASG capacity and removal of existing deletion protection. Volume expansion and new resources remain permitted.

This policy runs in the wrapper. A direct `terraform apply` bypasses it. Use the wrapper in your deployment pipeline and restrict direct production apply permissions. CI tests the policy without AWS credentials.

For an intentional replacement, use the recovery runbook and a separately reviewed maintenance plan. The wrapper has no bypass flag. Saved plans contain sensitive values and must remain access-controlled.

Commit each deployment root's `.terraform.lock.hcl`. CI initializes those roots with `-lockfile=readonly`.

## Replace nodes

1. Apply the new module configuration to create the maintenance table and select a numeric launch-template version.
2. Grant the operator `dynamodb:GetItem`, `dynamodb:PutItem`, and `dynamodb:DeleteItem` on that table.
3. Grant the operator the ASG, EC2 status, ENI discovery, and ELB read permissions used by the replacement script.
4. Export the deployment outputs and credentials.
5. Run the replacement script from a host that can reach the cluster.

```bash
export REPLACEMENT_LOCK_TABLE=$(terraform output -raw maintenance_lock_table)
export QDRANT_TARGET_GROUP_ARNS=$(terraform output -json nlb_target_group_arns | jq -r 'join(" ")')
export QDRANT_URL=$(terraform output -raw endpoint)
# Set QDRANT_API_KEY from Secrets Manager through your normal credential process.
../../scripts/replace-node.sh qdrant-prod-0 qdrant-prod-1 qdrant-prod-2
```

The script acquires one non-expiring lock for the deployment. It checks the actual replacement launch-template version. It checks all registered NLB targets, including the replacement IP. Deployments without an NLB require `ALLOW_NO_NLB_CHECK=1`. The cluster must remain healthy for 60 seconds before the script continues.

The lock remains after a failure or interruption. It does not expire while a slow replacement is still active. Automatic ASG failure recovery and Terraform apply do not acquire this lock. Do not run Terraform changes concurrently with maintenance.

### Recover an abandoned lock

1. Stop or locate the original replacement process.
2. Inspect the lock owner.
3. Complete recovery and check every peer, replica, and NLB target.
4. Delete the lock with its exact owner as a condition.

```bash
aws dynamodb get-item --table-name "$REPLACEMENT_LOCK_TABLE" \
  --consistent-read --key '{"LockID":{"S":"replacement"}}'

# Set LOCK_OWNER to the Owner value from the inspected item.
aws dynamodb delete-item --table-name "$REPLACEMENT_LOCK_TABLE" \
  --key '{"LockID":{"S":"replacement"}}' \
  --condition-expression '#owner = :owner' \
  --expression-attribute-names '{"#owner":"Owner"}' \
  --expression-attribute-values "$(jq -nc --arg owner "$LOCK_OWNER" '{":owner":{S:$owner}}')"
```

## Check the client path

```bash
QDRANT_URL=https://qdrant.example.com:6333 \
  python3 scripts/check-client.py --runner application-network-1
```

Set `QDRANT_API_KEY` through the runner's secret mechanism. Use a key with access to `qdrant-canary`. The existing node canary creates that collection.

The check writes a fresh nonce, reads the point, and queries it through the HTTPS endpoint. It checks certificate trust and refuses redirects. Each runner retains one point and replaces it on subsequent checks. Use a stable, unique runner name and prevent overlapping checks for that runner.

Run this check every minute from the application network. Route failures and missing executions to your monitoring system. The script prints JSON and exits nonzero on failure. Scheduling and paging integration depend on your monitoring platform and are not provisioned here. This check covers REST only. Exercise gRPC separately if applications use it.

## Required staging evidence

The new code has local tests. It does not establish production readiness by itself. Before deployment, record results for:

- An AZ outage under representative read and write load.
- A full cluster restore from backup artifacts, including aliases and every shard.
- A replacement from the baked AMI without public registry access.
- A restart during an AWS API or Secrets Manager outage.
- Certificate validation, gRPC traffic, and delivery of an alarm to a person.
- Snapshot, indexing, and recovery pressure with one node unavailable.

Backend and peer TLS, non-root container execution, coordinated disaster recovery, protected backup copies, and graceful NLB draining still need implementation and staging tests. The container now drops Linux capabilities and prevents privilege escalation.
