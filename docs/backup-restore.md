# Backup and restore

## What is backed up, and what you can promise

| Layer | What | Consistency | Restores |
| --- | --- | --- | --- |
| EBS snapshots (Data Lifecycle Manager) | Daily, one volume at a time, `ebs_snapshot_retention_count` kept | Crash-consistent; **not coordinated between volumes** | One node's disk |
| Qdrant snapshots in S3 | Daily, every collection's **local shards on that node**, uploaded by Qdrant to a versioned, encrypted bucket | Application-consistent per shard; nodes snapshot at slightly different times | Collections, shard by shard |
| Snapshot manifest in S3 | A JSON file per node per run, next to the snapshots (`<name>/manifests/node-N/<timestamp>.json`) | Describes what that run captured | Nothing by itself; it tells you what to restore |

The manifest records the cluster peers, every collection's full configuration (vectors, shard and replica counts, indexes), the shard layout on that node, the snapshot file name, and **all aliases** (Qdrant collection snapshots do not include aliases). Use it to recreate collections and to check you have every shard before declaring a restore complete.

**Recovery point (RPO).** Snapshots run daily, so after a total loss you can lose up to about a day of writes (plus the stagger between nodes) unless your application can replay them. Decide whether that is acceptable. If not, run snapshots more often (`qdrant_snapshot_schedule`), and keep a replayable source of truth outside Qdrant.

**Recovery time (RTO)** is not guaranteed. It depends on data size and on how well you have practised. Measure it in a drill.

## Checks that backups work

Alarms: `<node>-backup-stale` fires when a node's last fully successful snapshot is older than `backup_age_alarm_hours` (default 26), or when its age stops being reported. Failures also appear as `SnapshotSuccess = 0` in the `Qdrant` namespace.

```bash
# Snapshots and manifests
aws s3 ls "s3://$(terraform output -raw snapshot_bucket)/" --recursive | tail

# EBS snapshots
aws ec2 describe-snapshots --owner-ids self \
  --filters "Name=tag:QdrantCluster,Values=<name>" \
  --query 'Snapshots[].[SnapshotId,StartTime,State,VolumeId]' --output table
```

Run a snapshot on demand through SSM with `sudo systemctl start qdrant-snapshot.service`, then read `journalctl -u qdrant-snapshot`.

Sizing: a snapshot and index optimisation both use temporary space on the data volume. Size the volume for the data plus at least that much headroom (a common rule is 2 to 3 times the on-disk data size) and keep the disk alarm at 70% or lower for production.

## Scenario A: a node's instance fails, its volume is fine

Nothing to do. The Auto Scaling group replaces the instance, which re-attaches the same volume and IP and rejoins from its stored Raft state. Watch the `node-down` alarm clear and replicas return to Active.

## Scenario B: a node's data volume is lost (cluster still has quorum)

This was exercised on a real 3-node cluster by wiping node 0's storage. What happens, and what to do:

1. The replacement (or restarted) node starts with empty storage. Because the cluster is `initialized`, it does **not** create a new cluster. It finds a ready peer and tries to join through it, **including when the lost node was node 0**.
2. Qdrant rejects the join while the dead node's old entry is still in the member list (`peer URI ... already used by peer ...`). The start-up script clears the partial state that failed attempt left, so the next retry starts clean. Remove the dead peer from any healthy node: find it in `GET /cluster` (same IP) and call `DELETE /cluster/peer/<peer_id>?force=true`. The node's next retry then joins automatically and appears with a **new peer ID**.
3. The node now holds no replicas. Re-replicate every shard of every collection onto it until the `replica-deficit` alarm clears (and `scripts/replace-node.sh` stops waiting):
   ```bash
   curl -X POST "$QDRANT_URL/collections/<name>/cluster" -H "api-key: $QDRANT_API_KEY" -H 'Content-Type: application/json' \
     -d '{"replicate_shard": {"shard_id": 0, "from_peer_id": <healthy peer>, "to_peer_id": <new peer>}}'
   ```
   Repeat for each shard of each collection (including the `qdrant-canary` collection). `GET /collections/<name>/cluster` lists the shards and where their replicas live.
4. **A node that comes up as a standalone, empty cluster refuses to run.** If the join attempt ever leaves a state file that lists only that node, while the cluster is `initialized` and another node is ready, the start-up script exits with "Raft state lists only this node" instead of serving an empty, separate cluster behind the load balancer. If the node holds nothing you need, stop Qdrant, empty `/qdrant/data/storage`, and start it again so it joins the real cluster.

Prefer an empty volume plus re-replication over restoring an old EBS snapshot of one node: an old snapshot carries old Raft state.

## Scenario C: logical damage or total loss (rebuild from backups)

Use this for a bad delete, corruption, or loss of the cluster. It is the least automated path; practise it before you need it.

1. Choose the backup run. Take the manifests for **every node** from that run (same date). Check that each node has a manifest and that together they cover every shard (compare against `shard_number` and replica counts in the manifests). Each manifest also records the time its run started.
2. Start from a healthy, empty cluster (a new deployment of this module, or after `DELETE`ing the damaged collections). Do not mix with existing data of the same name unless you intend to overwrite it.
3. Recreate each collection with the configuration saved in the manifest (same `shard_number`, `replication_factor`, vectors, indexes).
4. Restore the **freshest single node's** snapshot for each collection. This procedure is supported only when the replication factor equals the node count (the recommended 3 nodes with factor 3, where every node holds every shard). A replicated shard appears in several nodes' snapshots, taken at slightly different times, and with `"priority": "snapshot"` every restore makes its data win. Restoring several nodes' snapshots one after another would let an older copy overwrite newer data, and with a lower replication factor the collection-level snapshots overlap in ways that no selection of whole snapshots avoids. If your replication factor is lower than your node count, there is no tested procedure here: plan a shard-level recovery and drill it before you rely on it.

   Download the chosen node's snapshot to that node and recover it, sending the request **directly to that node** (through its own SSM port forward, not the NLB):
   ```bash
   curl -X PUT "$QDRANT_URL/collections/<name>/snapshots/recover" \
     -H "api-key: $QDRANT_API_KEY" -H 'Content-Type: application/json' \
     -d '{"location": "file:///qdrant/snapshots/<file>.snapshot", "priority": "snapshot"}'
   ```
   `"priority": "snapshot"` makes the snapshot win over data already in the cluster; the default (`replica`) prefers existing data and can leave a restored collection empty. Wait for each recovery to finish. Follow the Qdrant snapshot documentation for distributed collections.
5. Recreate aliases from the manifest.
6. Re-replicate (`replicate_shard`, see [scaling.md](scaling.md)) until the `replica-deficit` alarm clears and every shard has all its replicas Active (`GET /collections/<name>/cluster`). Compare point counts with the manifest, run known queries, then cut your application over.

Because nodes snapshot at different times and writes continue, a restore gives you a state as of roughly the backup time, not an exact cluster-wide point in time. Anything written after must be replayed from your own source of truth. This procedure has not been exercised on real infrastructure; drill it (see [production.md](production.md)).

## Restore from an EBS snapshot (whole-node rollback, single node)

For a one-node deployment, or to roll one node back:

1. Stop the instance by scaling its ASG to zero and wait for termination ([operations.md](operations.md)).
2. Set `data_volume_snapshot_ids = { "0" = "snap-0123456789abcdef0" }` and apply. Terraform replaces the volume (keeping a final snapshot of the old one by default) and restores the ASG to one instance.
3. Check `/readyz`, then `GET /collections`.

The new volume must be at least as large as the snapshot. Do not use this to roll back several nodes of a cluster to "the same moment": the daily EBS snapshots of different volumes are taken independently, so they are not a consistent cluster-wide point in time.

## Test your restores

An untested backup is a hope, not a backup. Run Scenario C into a throwaway deployment on a schedule (at least quarterly, and after any major change), record how long it took, and compare point counts and known query results with production.

## Disaster recovery notes

- The snapshot bucket has versioning and a retention lifecycle (`qdrant_snapshot_retention_days`). Protection against loss of the whole AWS account or region needs S3 replication, which the module does not manage.
- `terraform destroy` fails to remove a non-empty snapshot bucket unless `force_destroy_snapshot_bucket = true`. Volumes produce a final snapshot unless `final_snapshot_on_destroy = false`. Delete leftover EBS snapshots yourself.
- Keep Terraform state in an encrypted remote backend. It holds the generated API keys.
