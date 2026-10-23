locals {
  alarm_actions = var.enable_monitoring ? [local.sns_topic_arn] : []
  sns_topic_arn = !var.enable_monitoring ? null : var.alarm_sns_topic_arn != null ? var.alarm_sns_topic_arn : aws_sns_topic.alarms[0].arn

  monitored_nodes = var.enable_monitoring ? local.nodes : {}
}

# CloudWatch alarms cannot publish to a topic encrypted with the AWS managed SNS key.
# Set alarm_sns_kms_key_id to a customer managed key whose policy allows
# cloudwatch.amazonaws.com to use it, or the topic stays unencrypted.
#trivy:ignore:AWS-0095
resource "aws_sns_topic" "alarms" {
  count = var.enable_monitoring && var.alarm_sns_topic_arn == null ? 1 : 0

  name              = "${var.name}-alarms"
  kms_master_key_id = var.alarm_sns_kms_key_id

  tags = local.tags
}

resource "aws_sns_topic_policy" "alarms" {
  count = var.enable_monitoring && var.alarm_sns_topic_arn == null ? 1 : 0

  arn = aws_sns_topic.alarms[0].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudWatchAlarms"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.alarms[0].arn
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}

resource "aws_sns_topic_subscription" "email" {
  count = var.enable_monitoring && var.alarm_sns_topic_arn == null && var.alarm_email != null ? 1 : 0

  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

##############################################################################
# Per-node alarms
##############################################################################

resource "aws_cloudwatch_metric_alarm" "node_down" {
  for_each = local.monitored_nodes

  alarm_name          = "${each.value.name}-node-down"
  alarm_description   = "No in-service instance in ASG ${each.value.name}. The node is down or being replaced."
  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceInstances"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.node[each.key].name }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "cpu" {
  for_each = local.monitored_nodes

  alarm_name          = "${each.value.name}-cpu-high"
  alarm_description   = "CPU above ${var.cpu_alarm_threshold_percent}% on ${each.value.name}."
  namespace           = "CWAgent"
  metric_name         = "cpu_usage_active"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.node[each.key].name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.cpu_alarm_threshold_percent
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "memory" {
  for_each = local.monitored_nodes

  alarm_name          = "${each.value.name}-memory-high"
  alarm_description   = "Memory above ${var.memory_alarm_threshold_percent}% on ${each.value.name}. Qdrant may be close to the OOM killer; scale up the instance type."
  namespace           = "CWAgent"
  metric_name         = "mem_used_percent"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.node[each.key].name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.memory_alarm_threshold_percent
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "disk" {
  for_each = local.monitored_nodes

  alarm_name          = "${each.value.name}-disk-high"
  alarm_description   = "Data volume above ${var.disk_alarm_threshold_percent}% on ${each.value.name}. Increase data_volume_size_gb."
  namespace           = "CWAgent"
  metric_name         = "disk_used_percent"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.node[each.key].name, path = local.data_mount }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.disk_alarm_threshold_percent
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = local.tags
}

# Hours since the last fully successful Qdrant snapshot, published every few
# minutes from a stamp on the data volume. Missing data also alarms: it means
# the checker itself stopped.
resource "aws_cloudwatch_metric_alarm" "backup_age" {
  for_each = var.enable_monitoring && var.enable_backups ? local.nodes : {}

  alarm_name          = "${each.value.name}-backup-stale"
  alarm_description   = "The last successful Qdrant snapshot on ${each.value.name} is older than ${var.backup_age_alarm_hours} hours, or backup age is no longer reported."
  namespace           = "Qdrant"
  metric_name         = "BackupAgeHours"
  dimensions          = { ClusterName = var.name, NodeIndex = tostring(each.value.index) }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.backup_age_alarm_hours
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = local.tags
}

# A write, read and search with the real API key against each node, every minute.
# Catches a wedged Qdrant that still answers /readyz.
resource "aws_cloudwatch_metric_alarm" "canary" {
  for_each = local.monitored_nodes

  alarm_name          = "${each.value.name}-canary-failing"
  alarm_description   = "The authenticated write/read/search canary is failing on ${each.value.name}, or no longer reporting. Qdrant may be wedged or unable to serve customers."
  namespace           = "Qdrant"
  metric_name         = "CanaryOK"
  dimensions          = { ClusterName = var.name, NodeIndex = tostring(each.value.index) }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "peer_count" {
  for_each = local.monitored_nodes

  alarm_name          = "${each.value.name}-cluster-peers-not-ready"
  alarm_description   = "Fewer than ${var.node_count} Qdrant nodes answer /readyz as seen from ${each.value.name}: a node is down, unreachable or not ready. (Cluster membership alone does not drop when a node stops, so this probes each peer.)"
  namespace           = "Qdrant"
  metric_name         = "ReadyPeers"
  dimensions          = { ClusterName = var.name, NodeIndex = tostring(each.value.index) }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  comparison_operator = "LessThanThreshold"
  threshold           = var.node_count
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "replica_deficit" {
  for_each = local.monitored_nodes

  alarm_name          = "${each.value.name}-replica-deficit"
  alarm_description   = "Some shards have fewer Active replicas than their collection's replication factor, as seen from ${each.value.name}: replicas are inactive or missing. Redundancy is reduced until they recover or are re-replicated."
  namespace           = "Qdrant"
  metric_name         = "ReplicaDeficit"
  dimensions          = { ClusterName = var.name, NodeIndex = tostring(each.value.index) }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 10
  datapoints_to_alarm = 10
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = local.tags
}

# Alarms on Qdrant's own metrics (published by the canary every minute).
resource "aws_cloudwatch_metric_alarm" "file_descriptors" {
  for_each = var.enable_monitoring && var.enable_qdrant_metrics ? local.nodes : {}

  alarm_name          = "${each.value.name}-file-descriptors-high"
  alarm_description   = "Qdrant on ${each.value.name} is using over 80% of its file descriptors. It will start refusing connections or segment opens."
  namespace           = "Qdrant"
  metric_name         = "FileDescriptorUtilizationPercent"
  dimensions          = { ClusterName = var.name, NodeIndex = tostring(each.value.index) }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 10
  datapoints_to_alarm = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "rest_latency" {
  for_each = var.enable_monitoring && var.enable_qdrant_metrics && var.latency_alarm_threshold_seconds != null ? local.nodes : {}

  alarm_name          = "${each.value.name}-rest-latency-high"
  alarm_description   = "The slowest REST response on ${each.value.name} exceeded ${var.latency_alarm_threshold_seconds}s (Qdrant rest_responses_max_duration_seconds)."
  namespace           = "Qdrant"
  metric_name         = "RestMaxLatencySeconds"
  dimensions          = { ClusterName = var.name, NodeIndex = tostring(each.value.index) }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 10
  datapoints_to_alarm = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.latency_alarm_threshold_seconds
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = local.tags
}

##############################################################################
# NLB alarms
##############################################################################

resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  for_each = var.enable_monitoring && var.enable_nlb ? aws_lb_target_group.this : {}

  alarm_name          = "${var.name}-${each.key}-unhealthy-targets"
  alarm_description   = "At least one Qdrant node is failing its /readyz health check behind the NLB (${each.key})."
  namespace           = "AWS/NetworkELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { TargetGroup = each.value.arn_suffix, LoadBalancer = aws_lb.this[0].arn_suffix }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = local.tags
}

##############################################################################
# Dashboard
##############################################################################

locals {
  dashboard_node_names = [for n in local.nodes : n.name]

  dashboard_widgets = concat(
    [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "CPU utilisation (%)"
          region = local.region
          stat   = "Average"
          period = 300
          metrics = [for n in local.dashboard_node_names :
            ["CWAgent", "cpu_usage_active", "AutoScalingGroupName", n]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Memory used (%)"
          region = local.region
          stat   = "Maximum"
          period = 300
          metrics = [for n in local.dashboard_node_names :
            ["CWAgent", "mem_used_percent", "AutoScalingGroupName", n]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "Data volume used (%)"
          region = local.region
          stat   = "Maximum"
          period = 300
          metrics = [for n in local.dashboard_node_names :
            ["CWAgent", "disk_used_percent", "AutoScalingGroupName", n, "path", local.data_mount]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "In-service instances per node"
          region = local.region
          stat   = "Minimum"
          period = 60
          metrics = [for n in local.dashboard_node_names :
            ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", n]
          ]
        }
      },
    ],
    [
      {
        type = "metric", x = 0, y = 18, width = 12, height = 6
        properties = {
          title  = "Canary OK (1 = write, read and search work)"
          region = local.region
          stat   = "Minimum"
          period = 60
          metrics = [for n in local.nodes :
            ["Qdrant", "CanaryOK", "ClusterName", var.name, "NodeIndex", tostring(n.index)]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 18, width = 12, height = 6
        properties = {
          title  = "Ready peers (probed) / cluster members / replica deficit"
          region = local.region
          stat   = "Maximum"
          period = 60
          metrics = concat(
            [for n in local.nodes : ["Qdrant", "ReadyPeers", "ClusterName", var.name, "NodeIndex", tostring(n.index)]],
            [for n in local.nodes : ["Qdrant", "PeerCount", "ClusterName", var.name, "NodeIndex", tostring(n.index)]],
            [for n in local.nodes : ["Qdrant", "ReplicaDeficit", "ClusterName", var.name, "NodeIndex", tostring(n.index)]],
          )
        }
      },
    ],
    [for w in [
      {
        type = "metric", x = 0, y = 12, width = 12, height = 6
        properties = {
          title  = "Hours since last good Qdrant snapshot"
          region = local.region
          stat   = "Maximum"
          period = 300
          metrics = [for n in local.nodes :
            ["Qdrant", "BackupAgeHours", "ClusterName", var.name, "NodeIndex", tostring(n.index)]
          ]
        }
      },
    ] : w if var.enable_backups],
    [for w in [
      {
        type = "metric", x = 0, y = 24, width = 12, height = 6
        properties = {
          title  = "REST requests and failed responses per minute"
          region = local.region
          stat   = "Sum"
          period = 60
          metrics = concat(
            [for n in local.nodes : ["Qdrant", "RestRequestsPerMin", "ClusterName", var.name, "NodeIndex", tostring(n.index)]],
            [for n in local.nodes : ["Qdrant", "RestFailedResponsesPerMin", "ClusterName", var.name, "NodeIndex", tostring(n.index)]],
          )
        }
      },
      {
        type = "metric", x = 12, y = 24, width = 12, height = 6
        properties = {
          title  = "REST latency (seconds, max / avg)"
          region = local.region
          period = 60
          metrics = concat(
            [for n in local.nodes : ["Qdrant", "RestMaxLatencySeconds", "ClusterName", var.name, "NodeIndex", tostring(n.index), { stat = "Maximum" }]],
            [for n in local.nodes : ["Qdrant", "RestAvgLatencySeconds", "ClusterName", var.name, "NodeIndex", tostring(n.index), { stat = "Maximum" }]],
          )
        }
      },
      {
        type = "metric", x = 0, y = 30, width = 12, height = 6
        properties = {
          title  = "Pending consensus operations / running optimizations"
          region = local.region
          stat   = "Maximum"
          period = 60
          metrics = concat(
            [for n in local.nodes : ["Qdrant", "PendingConsensusOperations", "ClusterName", var.name, "NodeIndex", tostring(n.index)]],
            [for n in local.nodes : ["Qdrant", "RunningOptimizations", "ClusterName", var.name, "NodeIndex", tostring(n.index)]],
          )
        }
      },
      {
        type = "metric", x = 12, y = 30, width = 12, height = 6
        properties = {
          title  = "Total points and file descriptor use (%)"
          region = local.region
          stat   = "Maximum"
          period = 300
          metrics = concat(
            [for n in local.nodes : ["Qdrant", "TotalPoints", "ClusterName", var.name, "NodeIndex", tostring(n.index)]],
            [for n in local.nodes : ["Qdrant", "FileDescriptorUtilizationPercent", "ClusterName", var.name, "NodeIndex", tostring(n.index), { yAxis = "right" }]],
          )
        }
      },
    ] : w if var.enable_qdrant_metrics],
    [for w in [
      {
        type = "metric", x = 12, y = 12, width = 12, height = 6
        properties = {
          title  = "Healthy / unhealthy targets (REST)"
          region = local.region
          period = 60
          metrics = [
            ["AWS/NetworkELB", "HealthyHostCount", "TargetGroup", try(aws_lb_target_group.this["rest"].arn_suffix, null), "LoadBalancer", try(aws_lb.this[0].arn_suffix, null), { stat = "Minimum" }],
            ["AWS/NetworkELB", "UnHealthyHostCount", "TargetGroup", try(aws_lb_target_group.this["rest"].arn_suffix, null), "LoadBalancer", try(aws_lb.this[0].arn_suffix, null), { stat = "Maximum" }],
          ]
        }
      },
    ] : w if var.enable_nlb],
  )
}

resource "aws_cloudwatch_dashboard" "this" {
  count = var.enable_monitoring ? 1 : 0

  dashboard_name = "${var.name}-qdrant"
  dashboard_body = jsonencode({ widgets = local.dashboard_widgets })
}
