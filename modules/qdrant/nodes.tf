locals {
  image = "${var.container_image}:v${var.qdrant_version}"

  collection_defaults = {
    for k, v in {
      replication_factor       = local.effective_replication_factor
      write_consistency_factor = local.effective_write_consistency
      strict_mode              = var.default_strict_mode_config
    } : k => v if v != null
  }

  qdrant_config = merge({
    log_level = var.log_level
    storage = merge({
      storage_path   = "/qdrant/storage"
      snapshots_path = "/qdrant/snapshots"
      # jsonencode/jsondecode keeps both branches the same type for Terraform.
      snapshots_config = jsondecode(var.enable_backups ? jsonencode({
        snapshots_storage = "s3"
        s3_config = {
          bucket = aws_s3_bucket.snapshots[0].id
          region = local.region
          prefix = var.name
        }
      }) : jsonencode({ snapshots_storage = "local" }))
      },
      # Defaults for NEW collections only. A map comprehension keeps the type
      # identical whether or not any default is set.
    { for k, v in { collection = local.collection_defaults } : k => v if length(v) > 0 })
    cluster = {
      enabled = true
      p2p     = { port = local.p2p_port }
    }
    # Only present when enabled; a for-expression keeps the object type stable.
  }, { for k, v in { service = { jwt_rbac = true } } : k => v if var.jwt_rbac_enabled })

  cloudwatch_agent_config = {
    agent = { metrics_collection_interval = 60, run_as_user = "root" }
    metrics = {
      namespace              = "CWAgent"
      append_dimensions      = { AutoScalingGroupName = "$${aws:AutoScalingGroupName}" }
      aggregation_dimensions = [["AutoScalingGroupName"], ["AutoScalingGroupName", "path"]]
      metrics_collected = {
        cpu  = { measurement = ["cpu_usage_active"], totalcpu = true }
        mem  = { measurement = ["mem_used_percent"] }
        swap = { measurement = ["swap_used_percent"] }
        disk = { measurement = ["used_percent"], resources = [local.data_mount], drop_device = true }
      }
    }
  }

  qdrant_unit = <<-EOT
    [Unit]
    Description=Qdrant vector database
    After=docker.service network-online.target
    Requires=docker.service

    [Service]
    Restart=always
    RestartSec=10
    TimeoutStartSec=900
    ExecStartPre=/usr/local/bin/qdrant-prepare.sh
    ExecStartPre=-/usr/bin/docker rm -f qdrant
    ExecStart=/usr/local/bin/qdrant-run.sh
    ExecStop=/usr/bin/docker stop -t 60 qdrant

    [Install]
    WantedBy=multi-user.target
  EOT

  snapshot_unit = <<-EOT
    [Unit]
    Description=Qdrant snapshot to S3
    After=qdrant.service

    [Service]
    Type=oneshot
    ExecStart=/usr/local/bin/qdrant-snapshot.sh
  EOT

  snapshot_timer = <<-EOT
    [Unit]
    Description=Daily Qdrant snapshot

    [Timer]
    OnCalendar=${var.qdrant_snapshot_schedule}
    RandomizedDelaySec=1800
    Persistent=true

    [Install]
    WantedBy=timers.target
  EOT

  canary_unit = <<-EOT
    [Unit]
    Description=Qdrant canary (authenticated write, read, search and health metrics)
    After=qdrant.service

    [Service]
    Type=oneshot
    ExecStart=/usr/local/bin/qdrant-canary.sh
  EOT

  canary_timer = <<-EOT
    [Unit]
    Description=Qdrant canary every minute

    [Timer]
    OnBootSec=120
    OnUnitActiveSec=60
    AccuracySec=5s

    [Install]
    WantedBy=timers.target
  EOT

  backup_age_unit = <<-EOT
    [Unit]
    Description=Publish Qdrant backup age

    [Service]
    Type=oneshot
    ExecStart=/usr/local/bin/qdrant-backup-age.sh
  EOT

  backup_age_timer = <<-EOT
    [Unit]
    Description=Publish Qdrant backup age every 5 minutes

    [Timer]
    OnBootSec=180
    OnUnitActiveSec=300

    [Install]
    WantedBy=timers.target
  EOT

  user_data_plain = {
    for key, node in local.nodes : key => templatefile("${path.module}/templates/user_data.yaml.tftpl", {
      monitoring = var.enable_monitoring
      backups    = var.enable_backups
      files = concat(
        [
          {
            path        = "/usr/local/bin/qdrant-prepare.sh"
            permissions = "0755"
            content = templatefile("${path.module}/templates/qdrant-prepare.sh.tftpl", {
              region     = local.region
              volume_id  = aws_ebs_volume.data[key].id
              eni_id     = aws_network_interface.node[key].id
              data_mount = local.data_mount
              secret_arn = local.secret_arn
            })
          },
          {
            path        = "/usr/local/bin/qdrant-run.sh"
            permissions = "0755"
            content = templatefile("${path.module}/templates/qdrant-run.sh.tftpl", {
              image        = local.image
              region       = local.region
              log_group    = local.log_group_name
              node_name    = node.name
              node_ip      = aws_network_interface.node[key].private_ip
              node_index   = node.index
              cluster_name = var.name
              state_param  = aws_ssm_parameter.cluster_state.name
              p2p_port     = local.p2p_port
              rest_port    = local.rest_port
              data_mount   = local.data_mount
            })
          },
          {
            path        = "/etc/systemd/system/qdrant.service"
            permissions = "0644"
            content     = local.qdrant_unit
          },
          {
            path        = "/etc/qdrant/production.yaml"
            permissions = "0644"
            content     = yamlencode(local.qdrant_config)
          },
          {
            path        = "/etc/qdrant/local.yaml"
            permissions = "0644"
            content     = length(keys(var.qdrant_config_overrides)) > 0 ? yamlencode(var.qdrant_config_overrides) : ""
          },
          {
            path        = "/etc/sysctl.d/99-qdrant.conf"
            permissions = "0644"
            content     = "vm.max_map_count = 1048576\n"
          },
        ],
        [for f in [
          {
            path        = "/usr/local/bin/qdrant-snapshot.sh"
            permissions = "0755"
            content = templatefile("${path.module}/templates/qdrant-snapshot.sh.tftpl", {
              region       = local.region
              rest_port    = local.rest_port
              cluster_name = var.name
              node_index   = node.index
              bucket       = coalesce(one(aws_s3_bucket.snapshots[*].id), "none")
              data_mount   = local.data_mount
            })
          },
          {
            path        = "/usr/local/bin/qdrant-backup-age.sh"
            permissions = "0755"
            content = templatefile("${path.module}/templates/qdrant-backup-age.sh.tftpl", {
              region       = local.region
              cluster_name = var.name
              node_index   = node.index
              data_mount   = local.data_mount
            })
          },
          {
            path        = "/etc/systemd/system/qdrant-backup-age.service"
            permissions = "0644"
            content     = local.backup_age_unit
          },
          {
            path        = "/etc/systemd/system/qdrant-backup-age.timer"
            permissions = "0644"
            content     = local.backup_age_timer
          },
          {
            path        = "/etc/systemd/system/qdrant-snapshot.service"
            permissions = "0644"
            content     = local.snapshot_unit
          },
          {
            path        = "/etc/systemd/system/qdrant-snapshot.timer"
            permissions = "0644"
            content     = local.snapshot_timer
          },
        ] : f if var.enable_backups],
        [for f in [
          {
            path        = "/usr/local/bin/qdrant-canary.sh"
            permissions = "0755"
            content = templatefile("${path.module}/templates/qdrant-canary.sh.tftpl", {
              region          = local.region
              rest_port       = local.rest_port
              cluster_name    = var.name
              node_index      = node.index
              node_count      = var.node_count
              canary_replicas = min(3, var.node_count)
              scrape_metrics  = var.enable_qdrant_metrics
            })
          },
          {
            path        = "/etc/systemd/system/qdrant-canary.service"
            permissions = "0644"
            content     = local.canary_unit
          },
          {
            path        = "/etc/systemd/system/qdrant-canary.timer"
            permissions = "0644"
            content     = local.canary_timer
          },
          {
            path        = "/opt/aws/amazon-cloudwatch-agent/etc/qdrant.json"
            permissions = "0644"
            content     = jsonencode(local.cloudwatch_agent_config)
          },
        ] : f if var.enable_monitoring],
      )
    })
  }
}

locals {
  # gzip keeps the rendered cloud-config well under EC2's 16 KB user data limit;
  # cloud-init decompresses it automatically.
  user_data = { for key, text in local.user_data_plain : key => base64gzip(text) }
}

# A customer managed key would need a key policy for the CloudWatch Logs service;
# logs use the default AWS-owned encryption.
#trivy:ignore:AWS-0017
resource "aws_cloudwatch_log_group" "qdrant" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days

  tags = local.tags
}

resource "aws_launch_template" "node" {
  for_each = local.nodes

  name_prefix            = "${each.value.name}-"
  image_id               = local.image_id
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.node.id]
  user_data              = local.user_data[each.key]
  update_default_version = true
  ebs_optimized          = true

  iam_instance_profile {
    arn = aws_iam_instance_profile.node.arn
  }

  # IMDSv2 only. Hop limit 2 lets containers that are not on the host network
  # reach instance credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  monitoring {
    enabled = var.detailed_monitoring
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_size_gb
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = each.value.name, QdrantNodeIndex = tostring(each.value.index) })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.tags, { Name = "${each.value.name}-root" })
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = contains(data.aws_ec2_instance_type.this.supported_architectures, var.architecture)
      error_message = "instance_type ${var.instance_type} does not support architecture ${var.architecture}. Set architecture to match, or choose a different instance type."
    }

    precondition {
      condition     = can(yamldecode(local.user_data_plain[each.key]))
      error_message = "The rendered cloud-config for node ${each.key} is not valid YAML. Check the templates and any content passed to the files list."
    }

    precondition {
      # EC2 limits user data to 16384 bytes before base64 (about 21800 characters after).
      condition     = length(local.user_data[each.key]) <= 20000
      error_message = "Compressed user data for node ${each.key} is ${length(local.user_data[each.key])} base64 characters; EC2 allows about 21800. Trim the scripts or the config overrides."
    }

    precondition {
      condition     = data.aws_ec2_instance_type.this.hypervisor == "nitro"
      error_message = "instance_type ${var.instance_type} is not a Nitro instance. The boot scripts locate the data volume through its NVMe device name, so only Nitro instance types are supported."
    }
  }
}

resource "aws_placement_group" "this" {
  count = var.placement_group_strategy != null ? 1 : 0

  name     = var.name
  strategy = var.placement_group_strategy

  tags = local.tags
}

# One single-instance ASG per node. The ASG gives self-healing: if the instance
# fails, a replacement starts in the same AZ and re-attaches the node's ENI and
# data volume. There is deliberately no instance_refresh block: changing the
# launch template never replaces all nodes at once. Roll nodes one at a time
# (see docs/operations.md).
resource "aws_autoscaling_group" "node" {
  for_each = local.nodes

  name                      = each.value.name
  min_size                  = 1
  max_size                  = 1
  desired_capacity          = 1
  vpc_zone_identifier       = [each.value.subnet_id]
  placement_group           = one(aws_placement_group.this[*].id)
  health_check_type         = "EC2"
  health_check_grace_period = 300
  enabled_metrics           = ["GroupInServiceInstances"]
  metrics_granularity       = "1Minute"

  launch_template {
    id      = aws_launch_template.node[each.key].id
    version = "$Latest"
  }

  dynamic "tag" {
    for_each = merge(local.tags, { Name = each.value.name })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = false
    }
  }

  depends_on = [
    aws_iam_role_policy.node,
    aws_iam_role_policy_attachment.ssm,
  ]
}
