# Multi-tenancy

"Multitenancy" is Qdrant's term for serving many customers (tenants) from one cluster. This module gives you the infrastructure and a few configuration switches. The tenant logic itself (who is allowed to see what, quotas, onboarding and deletion) belongs in your application or a small provisioning service, because only your application knows who the tenant is.

Everything below follows Qdrant's multitenancy and security documentation for the versions noted. Check the version of those docs that matches your `qdrant_version`, and test each API call in staging before relying on it. Items I could not confirm are marked **verify**.

## 1. Choose a model

| Model | Use it when | Trade-offs |
| --- | --- | --- |
| **Shared collection, tenant in the payload** (default choice) | Many small and medium tenants | Best resource use. Isolation is only as good as the tenant filter your backend adds to every request. One tenant's heavy queries share CPU and disk with everyone |
| **Custom shard keys** (one shard key per tenant, or per group of tenants) | You want a tenant's data on its own shard, to move or size it | Needs `sharding_method: custom`. A shard sits on one node, so a hot tenant cannot be spread by adding nodes |
| **Tiered: fallback shard plus promoted tenants** (Qdrant 1.16+) | Many small tenants, a few that grow large | Small tenants share one fallback shard (so one node). Large tenants are promoted to their own shard. See the constraints below |
| **Collection per tenant** | A small number of large tenants that need different settings or stronger separation | Each collection has fixed overhead. Qdrant recommends against thousands of collections |
| **Dedicated cluster per tenant** | Contractual or regulatory isolation, or a very large tenant | The strongest isolation and the highest operating cost. Deploy another copy of this module |

Start with a shared collection. Move a tenant to its own shard or collection when measurements show it is dominating a node.

## 2. Shared collection setup

Create the collection, then create the tenant payload index **before** you load data (`is_tenant` needs Qdrant 1.11 or later):

```bash
curl -X PUT "$QDRANT_URL/collections/shared" -H "api-key: $QDRANT_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"vectors": {"size": 768, "distance": "Cosine"}, "shard_number": 12, "replication_factor": 3}'

curl -X PUT "$QDRANT_URL/collections/shared/index" -H "api-key: $QDRANT_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"field_name": "tenant_id", "field_schema": {"type": "keyword", "is_tenant": true}}'
```

The index makes Qdrant store each tenant's vectors close together, which speeds up filtered search. **It is not access control.** Your backend must add `{"must": [{"key": "tenant_id", "match": {"value": "<tenant>"}}]}` to every search, scroll, count, update and delete, and must never let a client choose the tenant.

Rules that prevent most tenant mix-ups:

- Point IDs are unique per collection, not per tenant. Prefix them with the tenant (for example a UUID derived from tenant and document ID), or one tenant can overwrite another's point by sending the same ID.
- Reject any payload write that changes `tenant_id`.
- Add a payload index for every other field you filter on.

**HNSW for tenant-filtered workloads.** If every query is filtered by tenant, Qdrant documents building the index per tenant: `"hnsw_config": {"payload_m": 16, "m": 0}` at collection creation. Always set `payload_m` explicitly (it inherits `m` otherwise, so `m: 0` would also switch off the payload links), and note that `m: 0` disables the global graph, so unfiltered search over the whole collection becomes slow. Benchmark it on your data before adopting it.

## 3. Custom shard keys and tiered promotion

Create a custom-sharded collection and give a tenant a shard:

```bash
curl -X PUT "$QDRANT_URL/collections/tenants" -H "api-key: $QDRANT_API_KEY" -H 'Content-Type: application/json' \
  -d '{"vectors": {"size": 768, "distance": "Cosine"}, "shard_number": 1, "sharding_method": "custom"}'

curl -X PUT "$QDRANT_URL/collections/tenants/shards" -H "api-key: $QDRANT_API_KEY" -H 'Content-Type: application/json' \
  -d '{"shard_key": "tenant_a"}'
```

Send `"shard_key": "tenant_a"` with writes and searches so the request only touches that shard.

**Tiered multitenancy (1.16+)** keeps small tenants on a shared `default` shard and promotes a tenant to its own shard when it grows. Requests use `"shard_key": {"fallback": "default", "target": "tenant_a"}` plus the tenant filter. To promote a tenant:

1. Create its shard in `Partial` state: `PUT /collections/tenants/shards` with `{"shard_key": "tenant_a", "shards_number": 1, "replication_factor": 1, "initial_state": "Partial"}`.
2. Copy its points: `POST /collections/tenants/cluster` with `{"replicate_points": {"filter": {"must": {"key": "tenant_id", "match": {"value": "tenant_a"}}}, "from_shard_key": "default", "to_shard_key": "tenant_a"}}`.
3. Once the shard is Active, routing follows it. Delete the tenant's points from the fallback shard, then **add replicas** to the new shard to restore your replication factor.

Qdrant's documented constraints: fallback and dedicated shards use one shard each (`shards_number` 1); a new dedicated shard starts at replication factor 1; all small tenants share one shard and therefore one node; keep dedicated shards to roughly 1,000 per cluster; promote around 20,000 points.

What this means for operations on this module:

- **Adding nodes does not spread a shard.** A tenant's single shard stays on one node. Size that node for the largest tenant, or move the shard to a bigger instance's node.
- **Promotion temporarily lowers redundancy** (replication factor 1). The `replica-deficit` alarm will fire until you add replicas. Treat that as expected during a promotion and finish quickly.
- **The canary under-detects shard loss in custom-sharded collections.** For `sharding_method: custom` it counts only shards it can see; it cannot know which shard keys should exist. Keep your own list of expected shard keys and check it (**verify** how the shard list reports keys on your version).
- **The backup restore procedure in [backup-restore.md](backup-restore.md) has not been validated for custom-sharded collections.** Drill it first.

## 4. Access control

The primary and read-only API keys are **global**: anyone holding one can read or write every collection. Keep them in your backend and operations tooling, never in tenant-facing code.

Set `jwt_rbac_enabled = true` to turn on Qdrant's JWT role-based access control. Your backend then signs short-lived tokens (HS256, signed with the primary API key) with an `exp` claim and an `access` claim listing the collections and levels (`r` or `rw`) the token may use, for example `{"access": [{"collection": "tenants", "access": "r"}], "exp": 1766055305}`. Clients send it as `Authorization: Bearer <token>`.

Limits you need to design around:

- **Tokens are scoped to collections, not to a tenant inside a shared collection.** Qdrant's security documentation does not describe restricting a token to a payload value (**verify** on your version before trusting any such claim). In a shared collection, every request must still go through your backend, which adds the tenant filter. Tokens are useful to separate tenants that live in different collections, or to give a service read-only access.
- Tokens are signed with the primary `api_key`. **Rotating that key invalidates every issued token.** Whether tokens signed with the old key keep working during the `alt_api_key` overlap in [operations.md](operations.md) is not something I confirmed. **Verify** in staging and plan token reissue.
- `/metrics` needs a global read or manage token. A collection-scoped token cannot read it.

## 5. Limits and noisy neighbours

Set defaults for new collections with `default_strict_mode_config` (it writes `storage.collection.strict_mode`):

```hcl
default_strict_mode_config = {
  enabled                      = true
  max_query_limit              = 100
  max_timeout                  = 5
  unindexed_filtering_retrieve = false
  unindexed_filtering_update   = false
  search_max_hnsw_ef           = 128
}
```

These key names come from Qdrant's `config.yaml`; **verify** them against the file for your pinned version. Tune the values with load tests. Strict mode only applies to collections created after you set it. Patch existing collections through their strict-mode setting.

Strict mode limits are per request or per replica. They stop a single bad query, but they are **not per-tenant quotas**. Enforce per-tenant request rate, concurrency, ingestion volume and storage budget in your backend, where you know the tenant.

A tenant that dominates a node can be separated, in increasing order of effort and isolation: give it dedicated indexes or settings in a separate collection, promote it to its own shard, move that shard to its own node, or run it on a dedicated cluster.

## 6. Tuning knobs

| Lever | Where | Notes |
| --- | --- | --- |
| Tenant index and other payload indexes | Collection | The biggest win for filtered search. Index every field you filter on |
| `payload_m` / `m` | Collection | See section 2. Benchmark |
| Quantization, `on_disk` vectors | Collection | Trades accuracy and disk IOPS for memory. With on-disk data, provision EBS IOPS ([performance.md](performance.md)) |
| `shard_number`, `replication_factor`, `write_consistency_factor` | Collection, with module defaults | More replicas add read capacity; consistency 2 of 3 is the production default ([production.md](production.md)) |
| `qdrant_config_overrides` | Module | Qdrant settings such as search threads and optimizer options |
| Instance type, EBS type and IOPS, placement group | Module | [performance.md](performance.md) |

## 7. Seeing per-tenant behaviour

The module publishes node-wide Qdrant metrics to CloudWatch ([operations.md](operations.md)). It does not publish per-collection or per-tenant series, because that cardinality grows with your customers. Measure per-tenant latency, errors, throttling and usage in your application, with a bounded set of tenant dimensions or sampled traces. If you need per-collection response counts from Qdrant itself, it can report them at `/metrics?per_collection=true` (Qdrant 1.18 and later); scrape that into your own Prometheus or Grafana setup.

## 8. Tenant lifecycle

- **Onboard:** create the tenant's shard key or ensure the shared collection and its tenant index exist, record the tenant in your system, and issue credentials through your backend.
- **Export:** page through the tenant's points with a filtered scroll that includes vectors and payloads, together with the collection schema. Quiesce writes or record your own change log so the export is consistent.
- **Delete:** revoke access, stop ingestion, delete the tenant's points by filter (or drop its shard key), and confirm nothing is left (including any copy on a fallback shard). **Backups still contain the data** until they expire: Qdrant snapshots and manifests in S3 (`qdrant_snapshot_retention_days`) and EBS snapshots (`ebs_snapshot_retention_count`). If you promised deletion within a period, make those retention settings fit it, or keep a deletion log to re-apply after any restore.
- **Restore one tenant:** restore the shared backup into an isolated cluster, then export that tenant and import it into production. Do not restore a shared collection over a live one to recover one tenant.

## 9. What is not in this module

- A provisioner for collections, indexes, shard keys and promotion.
- Tenant authentication, token issuing and per-tenant quotas.
- Adversarial isolation tests (try to read, overwrite and delete across tenants, with and without shard keys, in batch operations). Write them in your application repository and run them in CI against staging.
- Tenant export and deletion tooling.

Treat the first three as launch requirements for a multi-tenant product.
