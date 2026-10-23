# Performance tuning

Change one thing at a time and measure with your own queries and data. Qdrant's own benchmarks do not tell you how your workload behaves on this setup.

## What to look at first

| Symptom | Likely limit | Where to look |
| --- | --- | --- |
| High memory, swapping, OOM kills | RAM | `memory-high` alarm, dashboard |
| High CPU during search | CPU | `cpu-high` alarm |
| Slow search with low CPU, collection stored on disk | EBS IOPS or throughput | CloudWatch EBS metrics (`VolumeReadOps`, `VolumeQueueLength`, `VolumeThroughputPercentage`) |
| Slow indexing or snapshots | EBS throughput, instance EBS bandwidth | Same EBS metrics, `EBSIOBalance%` and `EBSByteBalance%` on the instance |

## Module parameters

| Parameter | Effect |
| --- | --- |
| `instance_type` | The biggest lever. More RAM keeps more vectors in memory; more vCPUs serve more concurrent searches. It also sets the instance's EBS bandwidth ceiling |
| `data_volume_type` | `gp3` (default) or `io2`. See "gp3 or io2" below |
| `data_volume_iops` | gp3: 3000 to 16000, at most 500 per GiB, so 16000 IOPS needs at least 32 GiB. io2: 100 to 256000, at most 1000 per GiB |
| `data_volume_throughput` | gp3 only: 125 to 1000 MiB/s, capped at 0.25 MiB/s per provisioned IOPS, so 1000 MiB/s needs 4000 IOPS or more. io2 throughput follows its IOPS and this setting is ignored |
| `data_volume_size_gb` | Size has no performance effect on gp3 beyond the IOPS ratio above |
| `architecture` | Graviton (`arm64`) usually gives better price per performance. Test your own workload before committing a Savings Plan |
| `placement_group_strategy` | See below |
| `qdrant_config_overrides` | Qdrant settings written to `config/local.yaml`, for example `storage.performance.max_search_threads` and optimizer options |
| `detailed_monitoring` | One-minute EC2 metrics for faster diagnosis, small extra cost |

Instances have their own EBS limits. A small instance may have a burstable EBS baseline well below what you provisioned on the volume, so raising volume IOPS can do nothing. Check the instance type's EBS bandwidth and IOPS in the EC2 documentation, and size the instance and volume together.

## gp3 or io2

Start with gp3 and raise IOPS and throughput until EBS metrics stop being the limit. Move to `io2` (`data_volume_type = "io2"`) when:

- you need more than 16000 IOPS per node, or
- latency spikes under sustained load show up in `VolumeQueueLength` or read latency, and your collections or HNSW index are stored on disk.

io2 is designed for consistent, low-latency IOPS and has a much higher durability target, but you pay for every provisioned IOPS, so it costs noticeably more than gp3. If your vectors fit in RAM, EBS speed matters mostly at start-up and during snapshots, and gp3 is usually enough.

Notes:

- Above 64000 IOPS, an io2 volume needs an instance type that supports io2 Block Express. Check the EC2 documentation for your instance type; the instance's own EBS IOPS limit still applies.
- Switching type, IOPS or size is an in-place change with no downtime, but EBS allows one modification per volume every 6 hours and the volume stays slower while it optimizes.
- Raising IOPS never helps if the instance's EBS limit is the cap. Check that first.

## Placement groups

Set `placement_group_strategy`:

- **`spread`** puts every node on separate hardware, which limits correlated hardware failure. It also works across AZs, so it suits a multi-AZ cluster, and it is a good choice when you keep all nodes in one AZ.
- **`cluster`** packs nodes close together for the lowest latency and highest network throughput between them. It only works in a single AZ, so it gives up AZ-level fault tolerance. The module warns if the nodes span several AZs. Use it only if node-to-node traffic (replication, shard moves, distributed search) is your bottleneck and you accept the AZ risk.

Cross-AZ latency in the same region is typically about a millisecond or two. For most Qdrant workloads, replica reads served by the node the NLB picks matter more than node-to-node latency, so test before giving up AZ spread.

A cluster placement group can fail to launch an instance if AWS has no capacity close to the existing nodes. Instance replacement is the moment this shows up; starting from a larger instance family you already run helps.

## Not supported by the module (yet)

- **Instance store (NVMe, `d` instance types such as `r7gd`).** Local disks are lost when the instance is replaced, which conflicts with the persistent-volume design.
- **Dedicated tenancy, huge pages or CPU pinning.**

## Qdrant-side levers

These matter as much as the infrastructure. See the Qdrant documentation for each:

- Quantization (scalar, binary, product) cuts memory use a lot, at some accuracy cost.
- Keeping vectors or the HNSW index on disk (`on_disk`) trades RAM for disk IOPS. With on-disk data, EBS IOPS and throughput become the limit, so provision them.
- Shard count and replication: more replicas add read capacity. More shards help parallelism and let you spread data later ([scaling.md](scaling.md)).
- Payload indexes on fields you filter by.
