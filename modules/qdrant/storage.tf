##############################################################################
# Per-node persistent state: a fixed network identity (ENI) and a data volume.
#
# Both outlive the EC2 instance. When the ASG replaces an instance, the new one
# re-attaches the same ENI (same private IP, so the Raft peer address is
# stable) and the same EBS volume (same data).
##############################################################################

resource "aws_network_interface" "node" {
  for_each = local.nodes

  subnet_id       = each.value.subnet_id
  security_groups = [aws_security_group.node.id]
  description     = "Qdrant ${each.value.name} stable address"

  tags = merge(local.tags, { Name = each.value.name })
}

resource "aws_ebs_volume" "data" {
  for_each = local.nodes

  availability_zone = each.value.az
  type              = var.data_volume_type
  size              = var.data_volume_size_gb
  snapshot_id       = lookup(var.data_volume_snapshot_ids, each.key, null)
  iops              = var.data_volume_iops
  throughput        = var.data_volume_type == "gp3" ? var.data_volume_throughput : null
  encrypted         = true
  kms_key_id        = var.kms_key_arn
  final_snapshot    = var.final_snapshot_on_destroy

  tags = merge(local.tags, {
    Name         = "${each.value.name}-data"
    QdrantBackup = var.enable_backups ? var.name : "disabled"
  })

  lifecycle {
    precondition {
      condition     = var.data_volume_type != "gp3" || (var.data_volume_iops >= 3000 && var.data_volume_iops <= 16000 && var.data_volume_iops <= 500 * var.data_volume_size_gb)
      error_message = "For gp3, data_volume_iops must be 3000-16000 and at most 500 per GiB of data_volume_size_gb."
    }

    precondition {
      condition     = var.data_volume_type != "io2" || (var.data_volume_iops >= 100 && var.data_volume_iops <= 1000 * var.data_volume_size_gb)
      error_message = "For io2, data_volume_iops must be at least 100 and at most 1000 per GiB of data_volume_size_gb."
    }
  }
}
