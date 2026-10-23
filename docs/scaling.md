# Scaling

Qdrant is stateful, and the self-hosted version has **no automatic rebalancing or resharding**. This module gives you the infrastructure levers; moving data is a deliberate step you perform through the Qdrant API. This page walks through each direction.

Throughout, set:

```bash
export QDRANT_URL=...   # module output `endpoint` (reach it via SSM port forward, see README)
export QDRANT_API_KEY=$(aws secretsmanager get-secret-value --secret-id "$(terraform output -raw api_key_secret_arn)" \
  --query SecretString --output text | jq -r .api_key)
```

## Plan shards before you need them

`shard_number` is fixed when a collection is created. Pick it for the cluster you may grow into, not the one you have today. This advice is for an ordinary collection that spreads across all nodes. For many tenants, a custom-sharded collection, or a promoted tenant that sits on a **single** shard, adding nodes cannot split that shard, so read [multitenancy.md](multitenancy.md) first.

- Use a multiple of the node counts you expect. **12** divides evenly across 1, 2, 3, 4, 6 and 12 nodes.
- Use at least 2 shards per node so there is something to move when you add a node.
- Set `replication_factor` to 2 or more on multi-node clusters. On self-hosted Qdrant, changing it later has no effect, so add or drop replicas manually.

```bash
curl -X PUT "$QDRANT_URL/collections/my_collection" \
  -H "api-key: $QDRANT_API_KEY" -H 'Content-Type: application/json' \
  -d '{"vectors": {"size": 768, "distance": "Cosine"}, "shard_number": 12, "replication_factor": 2}'
```

A collection created on a single node with the default shard count has one shard. You can replicate that shard to other nodes, but you cannot spread it. To spread the data, create a new collection with more shards and re-ingest or restore into it.

## Scale up (vertical)

Use this when RAM, CPU or disk is the limit. It needs no data movement.

**Larger instance type**

1. Change `instance_type` and run `terraform apply`. This creates a new launch template version only. Running instances are untouched, so there is no surprise outage.
2. Replace nodes **one at a time** with `scripts/replace-node.sh`. Set `QDRANT_URL` (the NLB endpoint) and `QDRANT_API_KEY`. Before each node the script checks that the cluster has enough peers and every collection has all its replicas Active at replication factor 2 or more; after each node it waits until the cluster is healthy again, and it stops at the first failure. The replacement re-attaches the node's ENI and data volume.
   - Single node: expect a few minutes of downtime while the instance replaces.
   - Cluster: before each replacement, confirm every collection shows all replicas `Active` (`GET /collections/{name}/cluster`), then wait for the node to rejoin before touching the next.
3. Check the CloudWatch dashboard for memory and CPU after the change.

Moving to a different CPU architecture also needs `architecture` changed to match, and a matching Qdrant image is pulled automatically (the official image is multi-arch).

**Larger disk**

1. Increase `data_volume_size_gb` and apply. EBS grows the volume online. AWS allows one modification per volume every 6 hours.
2. Grow the filesystem. It happens automatically the next time the Qdrant service starts, or immediately via SSM: `sudo xfs_growfs /qdrant/data`.

Volumes cannot shrink. To go smaller, scale out and move shards, or restore into a new, smaller volume.

## Scale out (add nodes)

1. Raise `node_count` (for example 1 to 3) and apply. Use subnets in several AZs so the new nodes land in different zones.
2. The new nodes start empty and join the cluster through a ready peer. Check `GET /cluster`: you should see one peer per node.
3. Put data on the new nodes. For each collection, either:
   - **Replicate** a shard to a new peer (gives redundancy and read capacity):
     ```bash
     curl -X POST "$QDRANT_URL/collections/my_collection/cluster" -H "api-key: $QDRANT_API_KEY" \
       -H 'Content-Type: application/json' \
       -d '{"replicate_shard": {"shard_id": 0, "from_peer_id": 111, "to_peer_id": 222}}'
     ```
   - **Move** a shard to a new peer (spreads data and load):
     ```bash
     curl -X POST "$QDRANT_URL/collections/my_collection/cluster" -H "api-key: $QDRANT_API_KEY" \
       -H 'Content-Type: application/json' \
       -d '{"move_shard": {"shard_id": 0, "from_peer_id": 111, "to_peer_id": 222}}'
     ```
4. New collections should use the shard and replication guidance above.

Peer IDs come from `GET /cluster`. Each peer's `uri` contains the node's private IP, which matches the module output `node_private_ips`.

## Scale in (remove nodes)

Terraform removes the **highest-index** nodes first, so always remove the node with the highest index.

1. Identify the peer for the highest-index node (match its IP from `node_private_ips` against `GET /cluster`).
2. Move or drop every shard replica off that peer, for each collection:
   - `move_shard` to another peer, or
   - `drop_replica` when another peer already holds a replica. Every shard must keep at least one active replica.
3. Remove the peer from the cluster: `curl -X DELETE "$QDRANT_URL/cluster/peer/<peer_id>" -H "api-key: $QDRANT_API_KEY"`.
4. Lower `node_count` and apply. Terraform destroys that node's ASG, ENI and data volume. With `final_snapshot_on_destroy = true` (the default), a final EBS snapshot is kept.
5. Do not leave `node_count` at 2: Raft needs a majority, so one failure blocks cluster changes. Go from 3 to 1, or stay at 3.

## Cost and Savings Plans while scaling

Because every node is plain On-Demand EC2, any instance type and size you move to is covered by a Compute Savings Plan. See [savings-plans.md](savings-plans.md) for how to size a commitment so scaling up or down does not strand it.
