# Records whether this Qdrant cluster has ever been created. Node 0 may only
# start a NEW cluster while this says "uninitialized". After that, any node with
# empty storage must join through a ready peer or refuse to start, so a replaced
# node can never silently become a second, empty cluster.
resource "aws_ssm_parameter" "cluster_state" {
  name        = "/qdrant/${var.name}/cluster-state"
  description = "Whether the Qdrant cluster ${var.name} has been created"
  type        = "String"
  value       = "uninitialized"

  tags = local.tags

  lifecycle {
    # Node 0 sets the value to "initialized" after the cluster first becomes ready.
    ignore_changes = [value]
  }
}
