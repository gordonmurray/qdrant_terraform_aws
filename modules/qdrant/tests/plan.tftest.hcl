mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }

  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }

  mock_data "aws_region" {
    defaults = { region = "eu-west-1", name = "eu-west-1" }
  }

  mock_data "aws_subnet" {
    defaults = { availability_zone = "eu-west-1a" }
  }

  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["arm64"], hypervisor = "nitro" }
  }

  mock_resource "aws_iam_instance_profile" {
    defaults = { arn = "arn:aws:iam::123456789012:instance-profile/qdrant" }
  }

  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/qdrant" }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:qdrant-AbCdEf" }
  }

  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::qdrant-snapshots" }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:eu-west-1:123456789012:log-group:/qdrant/test" }
  }

  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:eu-west-1:123456789012:qdrant-alarms" }
  }

  mock_resource "aws_ssm_parameter" {
    defaults = { arn = "arn:aws:ssm:eu-west-1:123456789012:parameter/qdrant/test/cluster-state" }
  }

  mock_resource "aws_network_interface" {
    defaults = { private_ip = "10.0.1.10" }
  }
}

mock_provider "random" {}

variables {
  name       = "test"
  vpc_id     = "vpc-0123456789abcdef0"
  subnet_ids = ["subnet-aaaa", "subnet-bbbb", "subnet-cccc"]
}

run "single_node_defaults" {
  command = plan

  variables {
    allowed_cidr_blocks = ["10.0.0.0/16"]
  }

  assert {
    condition     = length(aws_autoscaling_group.node) == 1 && length(aws_ebs_volume.data) == 1 && length(aws_network_interface.node) == 1
    error_message = "A single node needs exactly one ASG, one data volume and one ENI."
  }

  assert {
    condition     = length(aws_lb.this) == 1 && length(aws_lb_target_group_attachment.this) == 2
    error_message = "The NLB should register the node on both the REST and gRPC target groups."
  }

  assert {
    condition     = length(aws_dlm_lifecycle_policy.ebs) == 1 && length(aws_s3_bucket.snapshots) == 1
    error_message = "Backups should be on by default."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.node_down) == 1 && length(aws_cloudwatch_metric_alarm.backup_age) == 1 && length(aws_cloudwatch_metric_alarm.canary) == 1 && length(aws_cloudwatch_metric_alarm.peer_count) == 1
    error_message = "Monitoring should create per-node alarms by default."
  }

  assert {
    condition     = aws_launch_template.node["0"].metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required."
  }

  assert {
    condition     = aws_ebs_volume.data["0"].encrypted
    error_message = "Data volumes must be encrypted."
  }
}

run "three_node_cluster" {
  command = plan

  override_data {
    target = data.aws_subnet.selected[0]
    values = { availability_zone = "eu-west-1a" }
  }

  override_data {
    target = data.aws_subnet.selected[1]
    values = { availability_zone = "eu-west-1b" }
  }

  override_data {
    target = data.aws_subnet.selected[2]
    values = { availability_zone = "eu-west-1c" }
  }

  variables {
    node_count          = 3
    allowed_cidr_blocks = ["10.0.0.0/16"]
  }

  assert {
    condition     = length(aws_autoscaling_group.node) == 3 && length(aws_ebs_volume.data) == 3
    error_message = "Three nodes need three ASGs and three data volumes."
  }

  assert {
    condition     = length(aws_lb_target_group_attachment.this) == 6
    error_message = "Each of three nodes must be registered on two target groups."
  }

  assert {
    condition     = length(distinct([for k, v in aws_ebs_volume.data : v.availability_zone])) == 3
    error_message = "Each node's data volume must be created in the AZ of that node's subnet."
  }
}

run "no_nlb_direct_access" {
  command = plan

  variables {
    enable_nlb                 = false
    allowed_security_group_ids = ["sg-0123456789abcdef0"]
  }

  assert {
    condition     = length(aws_lb.this) == 0 && length(aws_security_group.nlb) == 0
    error_message = "No NLB resources expected when enable_nlb is false."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.node_client_sg) == 2 && length(aws_vpc_security_group_ingress_rule.node_from_nlb) == 0
    error_message = "Clients must be allowed directly on the node security group when there is no NLB."
  }
}

run "everything_optional_off" {
  command = plan

  variables {
    enable_nlb          = false
    enable_backups      = false
    enable_monitoring   = false
    allowed_cidr_blocks = ["10.0.0.0/16"]
  }

  assert {
    condition     = length(aws_s3_bucket.snapshots) == 0 && length(aws_dlm_lifecycle_policy.ebs) == 0
    error_message = "Backup resources must not exist when backups are disabled."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.cpu) == 0 && length(aws_cloudwatch_dashboard.this) == 0 && length(aws_sns_topic.alarms) == 0
    error_message = "Monitoring resources must not exist when monitoring is disabled."
  }
}

run "tls_listener_on_nlb" {
  command = plan

  variables {
    nlb_certificate_arn = "arn:aws:acm:eu-west-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    allowed_cidr_blocks = ["10.0.0.0/16"]
  }

  assert {
    condition     = alltrue([for l in aws_lb_listener.this : l.protocol == "TLS"])
    error_message = "Listeners must use TLS when a certificate is provided."
  }
}

run "two_nodes_warns" {
  command = plan

  variables {
    node_count          = 2
    allowed_cidr_blocks = ["10.0.0.0/16"]
  }

  # check blocks only warn in real runs; terraform test reports them as failures, so expect them.
  expect_failures = [check.node_count_quorum, check.single_az]

  assert {
    condition     = length(aws_autoscaling_group.node) == 2
    error_message = "Two nodes are allowed (with a warning)."
  }
}

run "rejects_invalid_node_count" {
  command = plan

  variables {
    node_count          = 0
    allowed_cidr_blocks = ["10.0.0.0/16"]
  }

  expect_failures = [var.node_count]
}

run "rejects_version_with_v_prefix" {
  command = plan

  variables {
    qdrant_version      = "v1.20.0"
    allowed_cidr_blocks = ["10.0.0.0/16"]
  }

  expect_failures = [var.qdrant_version]
}

run "rejects_architecture_mismatch" {
  command = plan

  variables {
    architecture        = "x86_64"
    allowed_cidr_blocks = ["10.0.0.0/16"]
  }

  expect_failures = [aws_launch_template.node]
}

run "warns_when_nothing_can_reach_qdrant" {
  command = plan

  expect_failures = [check.access_configured]
}

run "spread_placement_group" {
  command = plan

  variables {
    node_count               = 3
    placement_group_strategy = "spread"
    allowed_cidr_blocks      = ["10.0.0.0/16"]
  }

  override_data {
    target = data.aws_subnet.selected[0]
    values = { availability_zone = "eu-west-1a" }
  }

  override_data {
    target = data.aws_subnet.selected[1]
    values = { availability_zone = "eu-west-1b" }
  }

  override_data {
    target = data.aws_subnet.selected[2]
    values = { availability_zone = "eu-west-1c" }
  }

  assert {
    condition     = length(aws_placement_group.this) == 1 && aws_placement_group.this[0].strategy == "spread"
    error_message = "A spread placement group should be created."
  }
}

run "rejects_invalid_placement_strategy" {
  command = plan

  variables {
    placement_group_strategy = "partition"
    allowed_cidr_blocks      = ["10.0.0.0/16"]
  }

  expect_failures = [var.placement_group_strategy]
}

run "io2_data_volume" {
  command = plan

  variables {
    data_volume_type    = "io2"
    data_volume_iops    = 40000
    data_volume_size_gb = 100
    allowed_cidr_blocks = ["10.0.0.0/16"]
  }

  assert {
    condition     = aws_ebs_volume.data["0"].type == "io2" && aws_ebs_volume.data["0"].iops == 40000
    error_message = "The io2 type and IOPS should be passed to the volume."
  }
}

run "rejects_gp3_iops_above_limit" {
  command = plan

  variables {
    data_volume_iops    = 20000
    data_volume_size_gb = 100
    allowed_cidr_blocks = ["10.0.0.0/16"]
  }

  expect_failures = [aws_ebs_volume.data]
}

run "rejects_io2_iops_above_size_ratio" {
  command = plan

  variables {
    data_volume_type    = "io2"
    data_volume_iops    = 60000
    data_volume_size_gb = 50
    allowed_cidr_blocks = ["10.0.0.0/16"]
  }

  expect_failures = [aws_ebs_volume.data]
}

run "production_mode_accepts_three_nodes_in_three_azs" {
  command = plan

  variables {
    production_mode     = true
    node_count          = 3
    ami_id              = "ami-0123456789abcdef0"
    nlb_certificate_arn = "arn:aws:acm:eu-west-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    alarm_email         = "oncall@example.com"
    allowed_cidr_blocks = ["10.0.0.0/16"]
  }

  override_data {
    target = data.aws_subnet.selected[0]
    values = { availability_zone = "eu-west-1a" }
  }

  override_data {
    target = data.aws_subnet.selected[1]
    values = { availability_zone = "eu-west-1b" }
  }

  override_data {
    target = data.aws_subnet.selected[2]
    values = { availability_zone = "eu-west-1c" }
  }

  assert {
    condition     = length(terraform_data.production_guard) == 1
    error_message = "The production guard should be active."
  }
}

run "production_mode_accepts_five_nodes_two_two_one" {
  command = plan

  variables {
    production_mode     = true
    node_count          = 5
    ami_id              = "ami-0123456789abcdef0"
    nlb_certificate_arn = "arn:aws:acm:eu-west-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    alarm_email         = "oncall@example.com"
    allowed_cidr_blocks = ["10.0.0.0/16"]
  }

  override_data {
    target = data.aws_subnet.selected[0]
    values = { availability_zone = "eu-west-1a" }
  }

  override_data {
    target = data.aws_subnet.selected[1]
    values = { availability_zone = "eu-west-1b" }
  }

  override_data {
    target = data.aws_subnet.selected[2]
    values = { availability_zone = "eu-west-1c" }
  }

  # The AZ rule passes; the placement caveat for more than 3 nodes is a warning.
  expect_failures = [check.production_placement]

  assert {
    condition     = length(aws_autoscaling_group.node) == 5
    error_message = "Five nodes split 2+2+1 across three AZs keep a majority if one AZ is lost."
  }
}

run "production_mode_rejects_one_node" {
  command = plan

  variables {
    production_mode     = true
    ami_id              = "ami-0123456789abcdef0"
    nlb_certificate_arn = "arn:aws:acm:eu-west-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    alarm_email         = "oncall@example.com"
    allowed_cidr_blocks = ["10.0.0.0/16"]
  }

  expect_failures = [terraform_data.production_guard]
}

run "production_mode_rejects_three_nodes_in_two_azs" {
  command = plan

  variables {
    production_mode     = true
    node_count          = 3
    subnet_ids          = ["subnet-aaaa", "subnet-bbbb"]
    ami_id              = "ami-0123456789abcdef0"
    nlb_certificate_arn = "arn:aws:acm:eu-west-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    alarm_email         = "oncall@example.com"
    allowed_cidr_blocks = ["10.0.0.0/16"]
  }

  override_data {
    target = data.aws_subnet.selected[0]
    values = { availability_zone = "eu-west-1a" }
  }

  override_data {
    target = data.aws_subnet.selected[1]
    values = { availability_zone = "eu-west-1b" }
  }

  expect_failures = [terraform_data.production_guard]
}

run "production_mode_rejects_missing_tls_alarm_and_ami" {
  command = plan

  variables {
    production_mode     = true
    node_count          = 3
    allowed_cidr_blocks = ["10.0.0.0/16"]
  }

  override_data {
    target = data.aws_subnet.selected[0]
    values = { availability_zone = "eu-west-1a" }
  }

  override_data {
    target = data.aws_subnet.selected[1]
    values = { availability_zone = "eu-west-1b" }
  }

  override_data {
    target = data.aws_subnet.selected[2]
    values = { availability_zone = "eu-west-1c" }
  }

  expect_failures = [terraform_data.production_guard]
}

run "metrics_alarms_and_tenant_options" {
  command = plan

  variables {
    jwt_rbac_enabled                = true
    default_strict_mode_config      = { enabled = true, max_query_limit = 100, unindexed_filtering_retrieve = false }
    latency_alarm_threshold_seconds = 2
    allowed_cidr_blocks             = ["10.0.0.0/16"]
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.rest_latency) == 1 && length(aws_cloudwatch_metric_alarm.file_descriptors) == 1
    error_message = "Qdrant metric alarms should exist when metrics and a latency threshold are enabled."
  }
}

run "metrics_off" {
  command = plan

  variables {
    enable_qdrant_metrics = false
    allowed_cidr_blocks   = ["10.0.0.0/16"]
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.file_descriptors) == 0 && length(aws_cloudwatch_metric_alarm.rest_latency) == 0
    error_message = "No Qdrant metric alarms when the metrics are disabled."
  }
}
