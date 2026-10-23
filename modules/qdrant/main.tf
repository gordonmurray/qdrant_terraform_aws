data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

# Keyed by list position, not by subnet ID: IDs may be unknown at plan time when
# the subnets are created in the same apply, and for_each keys must be known.
data "aws_subnet" "selected" {
  count = length(var.subnet_ids)
  id    = var.subnet_ids[count.index]
}

data "aws_ec2_instance_type" "this" {
  instance_type = var.instance_type
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  # Ports: REST, gRPC, and internal peer-to-peer (Raft + shard transfer).
  rest_port = 6333
  grpc_port = 6334
  p2p_port  = 6335

  data_mount = "/qdrant/data"

  node_indexes = range(var.node_count)
  node_keys    = [for i in local.node_indexes : tostring(i)]

  nodes = {
    for i in local.node_indexes : tostring(i) => {
      index     = i
      name      = "${var.name}-${i}"
      subnet_id = var.subnet_ids[i % length(var.subnet_ids)]
      az        = data.aws_subnet.selected[i % length(var.subnet_ids)].availability_zone
    }
  }

  tags = merge(var.tags, {
    QdrantCluster = var.name
    ManagedBy     = "terraform"
  })

  image_id = coalesce(
    var.ami_id,
    "resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${var.architecture}",
  )

  secret_arn = var.api_key_secret_arn != null ? var.api_key_secret_arn : aws_secretsmanager_secret.api_keys[0].arn

  az_counts = {
    for az in distinct([for n in local.nodes : n.az]) :
    az => length([for n in local.nodes : n if n.az == az])
  }
  max_nodes_per_az = max(values(local.az_counts)...)
  raft_quorum      = floor(var.node_count / 2) + 1

  effective_replication_factor = var.default_replication_factor != null ? var.default_replication_factor : (var.production_mode ? min(3, var.node_count) : null)
  effective_write_consistency = var.default_write_consistency_factor != null ? var.default_write_consistency_factor : (
    var.production_mode && local.effective_replication_factor != null ? floor(local.effective_replication_factor / 2) + 1 : null
  )

  snapshot_bucket_name = "${var.name}-snapshots-${local.account_id}-${local.region}"
  log_group_name       = "/qdrant/${var.name}"
}

check "node_count_quorum" {
  assert {
    condition     = var.node_count != 2
    error_message = "node_count = 2 gives no fault tolerance: Raft needs a majority, so losing one node blocks cluster changes. Use 1 or 3+."
  }
}

check "single_az" {
  assert {
    condition     = var.node_count == 1 || length(distinct([for n in local.nodes : n.az])) > 1
    error_message = "All nodes are in one availability zone. Pass subnets from several AZs for AZ-level fault tolerance."
  }
}

check "cluster_placement_single_az" {
  assert {
    condition     = var.placement_group_strategy != "cluster" || length(distinct([for n in local.nodes : n.az])) == 1
    error_message = "A cluster placement group needs every node in one AZ, but the nodes span several. Use a single subnet, or use the spread strategy."
  }
}

check "production_placement" {
  assert {
    condition     = !var.production_mode || var.node_count <= 3
    error_message = "production_mode with more than 3 nodes: Qdrant does not place replicas by AZ, so two replicas of one shard can share an AZ. Verify per-shard AZ placement yourself, or use 3 nodes in 3 AZs with replication factor 3."
  }
}

check "access_configured" {
  assert {
    condition     = length(var.allowed_cidr_blocks) + length(var.allowed_security_group_ids) > 0
    error_message = "No allowed_cidr_blocks or allowed_security_group_ids set: nothing can reach Qdrant except through SSM port forwarding."
  }
}

# Hard guard rails for production_mode. Unlike `check` blocks, a failed
# precondition stops the plan.
resource "terraform_data" "production_guard" {
  count = var.production_mode ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.node_count >= 3
      error_message = "production_mode needs node_count >= 3 so the Raft cluster survives losing a node."
    }

    precondition {
      condition     = local.max_nodes_per_az <= var.node_count - local.raft_quorum
      error_message = "production_mode needs nodes spread so that losing any one AZ keeps a Raft majority. With ${var.node_count} nodes at most ${var.node_count - local.raft_quorum} may share an AZ, but one AZ has ${local.max_nodes_per_az}. Pass subnets from more AZs, or use an odd node count such as 3 or 5."
    }

    precondition {
      condition     = var.enable_nlb && var.nlb_certificate_arn != null
      error_message = "production_mode requires enable_nlb = true and nlb_certificate_arn, so clients use TLS."
    }

    precondition {
      condition     = var.enable_backups && var.enable_monitoring
      error_message = "production_mode requires enable_backups and enable_monitoring."
    }

    precondition {
      condition     = var.alarm_sns_topic_arn != null || var.alarm_email != null
      error_message = "production_mode requires an alarm destination: set alarm_sns_topic_arn (preferred, wired to paging) or alarm_email."
    }

    precondition {
      condition     = var.ami_id != null
      error_message = "production_mode requires a pinned ami_id so node replacements are reproducible and tested."
    }

    precondition {
      condition     = var.final_snapshot_on_destroy
      error_message = "production_mode requires final_snapshot_on_destroy = true."
    }

    precondition {
      condition     = var.api_key_secret_arn != null || var.secret_recovery_window_days >= 7
      error_message = "production_mode requires secret_recovery_window_days >= 7 for the generated secret."
    }

    precondition {
      condition     = local.effective_write_consistency == null || local.effective_replication_factor == null || local.effective_write_consistency <= local.effective_replication_factor
      error_message = "default_write_consistency_factor must not exceed default_replication_factor."
    }
  }
}
