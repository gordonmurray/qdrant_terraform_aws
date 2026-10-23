locals {
  nlb_listeners = {
    rest = { port = local.rest_port, health = true }
    grpc = { port = local.grpc_port, health = false }
  }

  # Flattened (listener, node) pairs for target registration.
  nlb_targets = var.enable_nlb ? {
    for pair in setproduct(keys(local.nlb_listeners), local.node_keys) :
    "${pair[0]}-${pair[1]}" => { listener = pair[0], node = pair[1] }
  } : {}
}

resource "aws_lb" "this" {
  count = var.enable_nlb ? 1 : 0

  name                             = "${var.name}-nlb"
  load_balancer_type               = "network"
  internal                         = true
  subnets                          = var.subnet_ids
  security_groups                  = [aws_security_group.nlb[0].id]
  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = false

  tags = local.tags
}

resource "aws_lb_target_group" "this" {
  for_each = var.enable_nlb ? local.nlb_listeners : {}

  name        = "${var.name}-${each.key}"
  port        = each.value.port
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  # Qdrant serves /readyz on the REST port without authentication. Both target
  # groups use it, so gRPC targets are only healthy when REST is ready.
  health_check {
    protocol            = "HTTP"
    port                = tostring(local.rest_port)
    path                = "/readyz"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = local.tags
}

resource "aws_lb_target_group_attachment" "this" {
  for_each = local.nlb_targets

  target_group_arn = aws_lb_target_group.this[each.value.listener].arn
  target_id        = aws_network_interface.node[each.value.node].private_ip
  port             = local.nlb_listeners[each.value.listener].port
}

resource "aws_lb_listener" "this" {
  for_each = var.enable_nlb ? local.nlb_listeners : {}

  load_balancer_arn = aws_lb.this[0].arn
  port              = each.value.port
  protocol          = var.nlb_certificate_arn != null ? "TLS" : "TCP"
  certificate_arn   = var.nlb_certificate_arn
  ssl_policy        = var.nlb_certificate_arn != null ? "ELBSecurityPolicy-TLS13-1-2-2021-06" : null
  alpn_policy       = var.nlb_certificate_arn != null && each.key == "grpc" ? "HTTP2Preferred" : null

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.key].arn
  }

  tags = local.tags
}
