# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed (found by running it on real AWS)

- User data exceeded EC2's 16 KB limit: files are now plain text in the cloud-config and the whole document is gzipped, with plan-time checks for size and YAML validity.
- A rejected join left a partial Raft state, so the next start came up as a separate single-node cluster. A failed fresh start is now cleaned up, and a node whose state lists only itself refuses to start while the cluster is initialised and a peer is ready.
- The canary collection is created with `min(3, node_count)` replicas, so node loss no longer takes part of it down and the `replace-node.sh` health gate can pass.
- `cluster-peers-missing` did not detect a stopped node (Qdrant keeps it in the member list). Nodes now probe each peer's `/readyz`, published as `ReadyPeers`, and the alarm is `cluster-peers-not-ready`.

### Added

- `production_mode`: enforces 3+ nodes spread so losing any AZ keeps a Raft majority, TLS on the NLB, backups and monitoring, an alarm destination, a pinned AMI, final snapshots and a secret recovery window. Defaults new collections to replication factor 3 and write consistency 2.
- Safe node recovery: an empty node joins through any ready peer; only node 0 on a never-initialised cluster (SSM marker) may create one; otherwise it refuses to start.
- Per-node canary (authenticated write, read and search), peer-count and inactive-replica alarms, and a backup-age alarm that measures elapsed time.
- Snapshot manifests in S3 (collection configs, aliases, shard layout, peer IDs).
- `docs/production.md` with the production profile, limits and failure drills; `examples/production`.
- `jwt_rbac_enabled`, `default_strict_mode_config` and `docs/multitenancy.md` (shared collections, shard keys, tiered promotion, noisy neighbours, tenant lifecycle).
- Qdrant metrics in CloudWatch (`enable_qdrant_metrics`), dashboard widgets, file descriptor and optional latency alarms.
- `scripts/replace-node.sh` now needs the cluster endpoint and API key, checks health before and after each node, replaces serially and stops on the first failure.
- `data_volume_type` (`gp3` or `io2`), `placement_group_strategy`, `nlb_hostname`, `data_volume_snapshot_ids`.

- Initial `qdrant` module: single node or Raft cluster on EC2 with persistent ENI and EBS per node, internal NLB with optional TLS, Secrets Manager API keys, EBS snapshots via DLM, daily Qdrant snapshots to S3, CloudWatch alarms and dashboard.
- `single-node` and `cluster` examples for `eu-west-1`.
- Runbooks for scaling, backup and restore, operations and Savings Plans.
