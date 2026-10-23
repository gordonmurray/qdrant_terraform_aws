locals {
  client_ports = [local.rest_port, local.grpc_port]

  client_cidr_rules = {
    for pair in setproduct(range(length(var.allowed_cidr_blocks)), local.client_ports) :
    "cidr-${pair[0]}-${pair[1]}" => { cidr = var.allowed_cidr_blocks[pair[0]], port = pair[1] }
  }

  client_sg_rules = {
    for pair in setproduct(range(length(var.allowed_security_group_ids)), local.client_ports) :
    "sg-${pair[0]}-${pair[1]}" => { sg = var.allowed_security_group_ids[pair[0]], port = pair[1] }
  }
}

##############################################################################
# Node security group
##############################################################################

resource "aws_security_group" "node" {
  name_prefix = "${var.name}-node-"
  description = "Qdrant nodes"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${var.name}-node" })

  lifecycle {
    create_before_destroy = true
  }
}

# Nodes talk to each other on every Qdrant port (Raft, shard transfer, forwarded requests).
resource "aws_vpc_security_group_ingress_rule" "node_self" {
  for_each = toset([for p in [local.rest_port, local.grpc_port, local.p2p_port] : tostring(p)])

  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
  description                  = "Qdrant node to node ${each.value}"
}

# Behind the NLB, nodes only accept client ports from the NLB.
resource "aws_vpc_security_group_ingress_rule" "node_from_nlb" {
  for_each = var.enable_nlb ? toset([for p in local.client_ports : tostring(p)]) : toset([])

  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.nlb[0].id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
  description                  = "Qdrant client port ${each.value} from NLB"
}

# Without the NLB, clients connect to the nodes directly.
resource "aws_vpc_security_group_ingress_rule" "node_client_cidr" {
  for_each = var.enable_nlb ? {} : local.client_cidr_rules

  security_group_id = aws_security_group.node.id
  cidr_ipv4         = each.value.cidr
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  description       = "Qdrant client access"
}

resource "aws_vpc_security_group_ingress_rule" "node_client_sg" {
  for_each = var.enable_nlb ? {} : local.client_sg_rules

  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = each.value.sg
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = "Qdrant client access"
}

# Nodes need outbound access for package install, image pull and AWS APIs, and
# the destinations (Docker Hub, package repos, regional AWS endpoints) are not a
# fixed set of addresses. Restrict further with a NAT/firewall or VPC endpoints.
#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Outbound for package install, image pull and AWS APIs"
}

##############################################################################
# NLB security group
##############################################################################

resource "aws_security_group" "nlb" {
  count = var.enable_nlb ? 1 : 0

  name_prefix = "${var.name}-nlb-"
  description = "Qdrant internal NLB"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${var.name}-nlb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "nlb_client_cidr" {
  for_each = var.enable_nlb ? local.client_cidr_rules : {}

  security_group_id = aws_security_group.nlb[0].id
  cidr_ipv4         = each.value.cidr
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  description       = "Qdrant client access"
}

resource "aws_vpc_security_group_ingress_rule" "nlb_client_sg" {
  for_each = var.enable_nlb ? local.client_sg_rules : {}

  security_group_id            = aws_security_group.nlb[0].id
  referenced_security_group_id = each.value.sg
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = "Qdrant client access"
}

resource "aws_vpc_security_group_egress_rule" "nlb_to_nodes" {
  for_each = var.enable_nlb ? toset([for p in local.client_ports : tostring(p)]) : toset([])

  security_group_id            = aws_security_group.nlb[0].id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
  description                  = "NLB to Qdrant nodes ${each.value}"
}
