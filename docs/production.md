# Running this in production

`production_mode = true` makes the module refuse unsafe setups. It is a floor, not a guarantee: read "What the module cannot promise" and run the drills below before customers depend on it. A reviewer who read this code rated the design a good foundation but not production-ready until recovery and alerting had been demonstrated, and this page is the result of that review.

For existing deployments, read [the hardening migration guide](hardening-migration.md) before applying these changes.

## What `production_mode` enforces

The plan fails (a precondition, not a warning) unless all of these hold:

| Rule | Why |
| --- | --- |
| `node_count == 3` | The supported production topology has one node per AZ and one replica per node |
| Three distinct AZs | Losing one AZ leaves two peers and two replicas of each shard |
| Explicit `node_subnet_ids` | Reordering the NLB subnet list must not move nodes |
| Image digest and replication defaults | An immutable image, replication factor 3, and write consistency 2 are required |
| `nlb_hostname` and no forced bucket deletion | The client endpoint needs a certificate hostname and backups must survive accidental teardown |
| `enable_nlb` and `nlb_certificate_arn` | Clients use TLS (`nlb_hostname` should be the DNS name the certificate covers) |
| `enable_backups` and `enable_monitoring` | Backups, alarms and the canary are not optional |
| `alarm_sns_topic_arn` or `alarm_email` | There must be somewhere for alarms to go. Prefer a topic wired to a pager |
| `ami_id` pinned | Replacements are reproducible and tested. Build or choose an AMI, test it, then pin it |
| `final_snapshot_on_destroy` | A destroy keeps a last copy of each data volume |
| Secret recovery window of at least 7 days | A deleted secret can be recovered |

It also sets new collections to **replication factor 3 and write consistency 2** (a majority) through Qdrant's `storage.collection` defaults. Production mode rejects other defaults and conflicting configuration overrides. These apply to collections created afterwards. **Existing collections keep their old settings**, and clients can still override per collection, so audit the real placement: every collection should show every shard with Active replicas on distinct nodes.

See `examples/production` for a starting point.

## How lost nodes are handled

Cluster state lives in an SSM parameter, `/qdrant/<name>/cluster-state`: `uninitialized` (never created), `creating`, `initialized`. Node 0 may only create a cluster while it reads `uninitialized`, and it sets `creating` before it creates anything. Any node that reaches ready sets `initialized` (retrying until the write succeeds). If node 0 later finds empty storage while the state is `creating` or `initialized` and no peer is ready, it refuses to start. A crash during first initialisation therefore needs an operator decision (the log says which value to set). A deployment created before this marker existed needs the parameter set to `initialized` before the new scripts roll out.

- **Instance fails, volume intact:** replaced automatically, rejoins from stored state.
- **Volume lost:** the empty replacement joins through any ready peer. It never creates a second cluster. Only node 0, while the cluster has never been initialised (tracked by an SSM parameter `/qdrant/<name>/cluster-state`), may create one. If an empty node finds no ready peer, it refuses to start and retries.
- If a majority of nodes is down, replacements wait until a peer is ready. That is deliberate: the alternative is two clusters that disagree.

Steps for each case are in [backup-restore.md](backup-restore.md).

## Detection

Per node, every minute, a canary writes a point with a fresh nonce, reads it back, searches, and reports peers seen and the replica deficit. If it cannot inspect something it fails, so unknown health is never reported as healthy. Alarms:

| Alarm | Fires when |
| --- | --- |
| `canary-failing` | The write/read/search fails or stops reporting (catches a wedged process that still passes `/readyz`) |
| `cluster-peers-not-ready` | Fewer than `node_count` nodes answer `/readyz` as seen from this node (each node probes its peers, because Qdrant keeps a stopped node in its member list) |
| `replica-deficit` | For 10 minutes, some shard has fewer Active replicas than its collection's replication factor (inactive **or missing**, so it also catches a replaced node that has not been re-replicated yet) |
| `node-down`, `cpu-high`, `memory-high`, `disk-high` | As in [operations.md](operations.md) |
| `backup-stale` | A node's last good snapshot is older than `backup_age_alarm_hours`, or age stops being reported |
| `*-unhealthy-targets` | A node fails `/readyz` behind the NLB |

The canary uses a collection named `qdrant-canary`, visible in your cluster. The extra custom metrics add a small per-node CloudWatch cost.

The canary runs on each node against itself. It does not test the customer path through the NLB and TLS. Run `scripts/check-client.py` from the application network against `nlb_hostname`, and route all alarms to an on-call tool. An email address alone is not paging.

## What the module cannot promise

- **Availability depends on how collections are created and where replicas land.** The replication default is only a default; enforce it in your application or provisioning code. Qdrant does not place replicas by AZ. The one topology where "survives losing an AZ" holds by construction is **3 nodes in 3 AZs with replication factor 3** (every shard on every node, write consistency 2). With 5 nodes, Raft keeps its majority if an AZ is lost, but two replicas of one shard can share an AZ, and losing that AZ can leave too few replicas for write consistency 2. If you use 5 nodes, verify and maintain per-shard AZ placement yourself. Production mode rejects more than three nodes.
- **Terraform evaluates the AZ rule when subnet AZs are known.** With subnets that are created in the same apply, the check can move to apply time.
- **Backups are daily and per node.** Expect up to about a day of data loss in a total loss. Cluster-wide recovery is a procedure you must practise, not a button.
- **Start-up depends on outside services.** By default, a new instance needs package repositories and the container registry. The production example instead requires a baked AMI. Every restart needs the EC2 API and Secrets Manager. During an unrelated outage a replacement can fail to start. Reduce this by pinning an AMI that already has Docker, using VPC endpoints for AWS APIs, and a cached image in the AMI or a private registry mirror. Private ECR authentication is supported.
- **Node-to-node traffic is not encrypted.** TLS covers client to NLB only. If your commitments require encryption in transit end to end, you need more than this module.
- **One AZ per node.** An AZ outage takes its node out until recovery. Replication across AZs keeps the service up.
- **Terraform can replace several nodes' volumes in one plan** (for example a KMS key change, or subnet reordering without explicit node assignments). Use `scripts/plan-production.sh` to reject destructive changes before apply. Read the saved plan. Change one node at a time ([operations.md](operations.md)).
- **No automatic rebalancing.** See [scaling.md](scaling.md).

## What has actually been tested

These results describe the earlier implementation. The new maintenance lock, baked-image path, and client check still need AWS staging drills.

The module was deployed to AWS (eu-west-1, the `examples/cluster` 3-node stack with replication factor 3 and write consistency 2 collections) and exercised for a few hours. Results:

| Drill | Result |
| --- | --- |
| Boot and cluster formation | Three nodes in three AZs formed one Raft cluster on first boot. Node 0 created it, nodes 1 and 2 joined, all agreed on one leader. NLB targets healthy through `/readyz` |
| Auth | 401 without a key; `/readyz` needs no key |
| Terminate a node under continuous read/write load through the NLB | 4 of 249 requests failed (5 second timeouts, about 26 seconds, while the NLB still routed to the dying node). Every one of 262 acknowledged writes was retrievable afterwards. The replacement kept its IP, volume and peer ID |
| Backup | Each node uploaded its own snapshot and a manifest to S3; the backup-age metric reset |
| Restore | A snapshot from S3 recovered into a new collection: green, 6 shards, replication factor 3, exactly the snapshotted points |
| Lose node 0's volume | Found two real bugs, now fixed (a rejected join left a partial state that made the node start as a separate cluster; the canary collection had replication factor 1). After the fixes: the node refuses a standalone state, a failed fresh start is cleaned up, and the runbook in [backup-restore.md](backup-restore.md) was followed to full recovery |
| Rolling replacement of all three nodes with `scripts/replace-node.sh` | Preflight and post-checks passed for each node; the gate waited for replicas to heal between nodes. The gate also correctly refused to start while the canary collection had a single replica |
| API key rotation (all three phases) | Cluster stayed at 3 peers through every restart; both keys worked during the overlap; the old key returned 401 at the end; snapshots worked with the rotated key |
| Stop Qdrant on one node (instance healthy) | The node's canary alarm fired after about 4 minutes. Membership alone did not drop, so the peer alarm was changed to probe each peer's `/readyz` (verified: `ReadyPeers` fell from 3 to 2 on the other nodes) |

Not tested yet: losing a whole AZ, memory and disk pressure, a package registry or Secrets Manager outage during replacement, the production-mode TLS path (ACM certificate), delivery of alarms to a pager, custom shard keys and tenant promotion, a full cluster rebuild from backups (Scenario C), and scaling beyond three nodes. Treat those as open drills below. The real run also found a 16 KB user data limit problem that mocked tests could not (now fixed), so expect other surprises there.

## Drills to run in staging before go-live

Run the same module settings as production, with a realistic dataset and sustained read and write load. For each drill record what customers would have seen, whether acknowledged writes survived, whether the alert arrived and how quickly, and how long recovery took.

1. Terminate each node in turn, including the current Raft leader. Check the replacement keeps its ENI, volume, peer identity and data.
2. Delete node 0's volume and recover it (Scenario B). Confirm it joins the existing cluster and never serves as a separate cluster. Do the same for node 1.
3. Isolate one AZ (security group or NACL), then partition peer traffic while leaving client traffic open. Check quorum, replica placement and how your client retries.
4. Stop and suspend Qdrant. Apply memory and disk pressure, including indexing and a snapshot at the same time. Confirm the right alarms fire and recovery works.
5. Restore a multi-shard dataset into a clean cluster using only backup artefacts (Scenario C). Check every shard, aliases, payloads, known queries and writes around the backup time.
6. Disable the snapshot timer and deny S3 writes. Confirm `backup-stale` fires within the expected time.
7. Block the package repositories and registry during a replacement, and Secrets Manager during a restart. Note which failures need an operator.
8. Run all three phases of API key rotation with mixed node states and confirm the old key is rejected at the end ([operations.md](operations.md)).

## Before go-live checklist

- [ ] `production_mode = true`, with a tested pinned `ami_id`.
- [ ] Every collection has replication factor of at least 2 (3 recommended) and write consistency of at least 2.
- [ ] Alarms go to a paging tool, and a test alarm reached a person.
- [ ] An external check hits `nlb_hostname` over TLS.
- [ ] All eight drills passed, with recovery times recorded.
- [ ] Volume headroom for snapshots and optimisation confirmed at peak (disk alarm at 70% or lower).
- [ ] Terraform state is in an encrypted, access-controlled remote backend.
- [ ] You have decided and written down your RPO, RTO, and what happens during an AZ outage.
