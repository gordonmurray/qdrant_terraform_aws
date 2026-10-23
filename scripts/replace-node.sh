#!/usr/bin/env bash
# Replace the EC2 instance behind one or more Qdrant nodes, for example to pick
# up a new instance type, AMI or user data after `terraform apply`.
#
# Each node's ENI (same IP) and data volume are re-attached to the replacement,
# so no data is lost. Nodes are replaced SERIALLY. Before each one the script
# checks that the cluster can afford to lose it, and after each one it waits
# until the cluster is fully healthy again. It stops at the first failure.
#
# Usage:
#   QDRANT_URL=https://qdrant.example.com:6333 QDRANT_API_KEY=... \
#     scripts/replace-node.sh [--skip-preflight] <asg-name> [<asg-name> ...] [-- region]
#
# Environment:
#   QDRANT_URL          Required. Cluster endpoint, ideally the NLB (reachable from
#                       where you run this, for example through the VPC or an SSM
#                       port forward). It does not have to avoid the node being replaced.
#   QDRANT_API_KEY      Required. Global API key (needed for the health checks).
#   EXPECTED_PEERS      Optional. Number of cluster peers that must be present
#                       before each replacement (default: the number of ASG names
#                       given is NOT assumed; the check is "at least 3" unless
#                       ALLOW_SMALL_CLUSTER=1).
#   ALLOW_SMALL_CLUSTER=1   Allow clusters with fewer than 3 peers (single node
#                       replacement means downtime).
#   ALLOW_SINGLE_REPLICA=1  Allow collections with replication factor 1.
#   ALLOW_WRITE_UNAVAILABILITY=1  Allow replacing a node even if, while it is gone,
#                       some shard would have fewer Active replicas than the
#                       collection's write consistency factor (writes to it would fail).
#   HEALTH_TIMEOUT_MIN  Minutes to wait for the cluster to be healthy after each
#                       replacement (default 30).
#
# --skip-preflight skips the checks BEFORE a replacement. Use it only to repair a
# node that is already broken. The checks after each replacement still run.

set -euo pipefail

skip_preflight=0
asgs=()
region="${AWS_REGION:-eu-west-1}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-preflight) skip_preflight=1 ;;
    --) shift; region="${1:-$region}"; break ;;
    -*) echo "Unknown option $1" >&2; exit 2 ;;
    *) asgs+=("$1") ;;
  esac
  shift
done

if [ "${#asgs[@]}" -eq 0 ]; then
  echo "usage: $0 [--skip-preflight] <asg-name> [<asg-name> ...] [-- region]" >&2
  exit 2
fi
: "${QDRANT_URL:?QDRANT_URL is required (the cluster endpoint)}"
: "${QDRANT_API_KEY:?QDRANT_API_KEY is required}"
export AWS_DEFAULT_REGION="$region"
timeout_min="${HEALTH_TIMEOUT_MIN:-30}"

api() { curl -fsS --max-time 30 -H "api-key: $QDRANT_API_KEY" "$QDRANT_URL$1"; }

# Prints a human-readable problem and returns non-zero if the cluster is not
# fully healthy: every peer present, every shard at its full replication factor
# with all replicas Active, no collection running with a single replica.
# With a first argument of "preflight" it also requires that the cluster can lose
# one node: every shard must keep at least write_consistency_factor Active
# replicas without it.
# Note: this checks cluster membership and replica states as Qdrant reports them.
# It cannot probe each node's readiness from outside the VPC; Qdrant only marks a
# replica non-Active after it fails. Wait for the alarms to be clear as well.
cluster_problem() {
  local mode="${1:-}" peers collections name path cfg rf wcf sn min_active
  curl -fsS --max-time 10 "$QDRANT_URL/readyz" >/dev/null 2>&1 || { echo "cluster endpoint is not ready"; return 1; }

  peers=$(api /cluster | jq -e '.result.peers | length') || { echo "cannot read cluster membership"; return 1; }
  if [ -n "${EXPECTED_PEERS:-}" ]; then
    [ "$peers" -eq "$EXPECTED_PEERS" ] || { echo "cluster has $peers peers, expected $EXPECTED_PEERS"; return 1; }
  elif [ "${ALLOW_SMALL_CLUSTER:-0}" != 1 ] && [ "$peers" -lt 3 ]; then
    echo "cluster has $peers peers; replacing a node of a cluster this small causes downtime (set ALLOW_SMALL_CLUSTER=1 to accept that)"
    return 1
  fi

  collections=$(api /collections | jq -er '.result.collections[].name') || { echo "cannot list collections"; return 1; }
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    path=$(jq -rn --arg n "$name" '$n | @uri')
    cfg=$(api "/collections/$path") || { echo "cannot read collection $name"; return 1; }
    rf=$(jq -e '.result.config.params.replication_factor // 1' <<<"$cfg") || return 1
    wcf=$(jq -e '.result.config.params.write_consistency_factor // 1' <<<"$cfg") || return 1
    sn=$(jq -e 'if .result.config.params.sharding_method == "custom" then 0 else (.result.config.params.shard_number // 0) end' <<<"$cfg") || return 1
    if [ "$rf" -lt 2 ] && [ "${ALLOW_SINGLE_REPLICA:-0}" != 1 ]; then
      echo "collection $name has replication factor $rf; replacing a node would make its data unavailable (set ALLOW_SINGLE_REPLICA=1 to accept that)"
      return 1
    fi
    deficit=$(api "/collections/$path/cluster" | jq -e --argjson rf "$rf" --argjson sn "$sn" '
        if (.result.local_shards | type) == "array" then
          [.result.local_shards[], (.result.remote_shards // [])[]] as $all
          | ($all | group_by(.shard_id)) as $groups
          | ($groups | map(($rf - ([.[] | select(.state == "Active")] | length)) | if . > 0 then . else 0 end) | add // 0) as $present
          | (if $sn > ($groups | length) then ($sn - ($groups | length)) * $rf else 0 end) as $absent
          | $present + $absent
        else error("no shard list") end') || { echo "cannot inspect shards of $name"; return 1; }
    [ "$deficit" -eq 0 ] || { echo "collection $name is $deficit replica(s) short of its replication factor"; return 1; }
    if [ "$mode" = preflight ] && [ "${ALLOW_WRITE_UNAVAILABILITY:-0}" != 1 ]; then
      min_active=$(api "/collections/$path/cluster" | jq -e '
          [.result.local_shards[], (.result.remote_shards // [])[]]
          | group_by(.shard_id) | map([.[] | select(.state == "Active")] | length) | min // 0') || { echo "cannot inspect shards of $name"; return 1; }
      if [ $((min_active - 1)) -lt "$wcf" ]; then
        echo "collection $name has a shard with only $min_active Active replica(s) and write consistency factor $wcf: while one node is replaced, writes to it would fail (set ALLOW_WRITE_UNAVAILABILITY=1 to accept that)"
        return 1
      fi
    fi
  done <<<"$collections"
  return 0
}

in_service_instance() {
  # shellcheck disable=SC2016 # backticks are JMESPath literals, not shell
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$1" \
    --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId | [0]' --output text
}

wait_healthy() {
  local deadline problem
  deadline=$(( $(date +%s) + timeout_min * 60 ))
  while :; do
    if problem=$(cluster_problem); then
      echo "Cluster is healthy."
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "Cluster did not become healthy within $timeout_min minutes: $problem" >&2
      return 1
    fi
    echo "  waiting: $problem"
    sleep 15
  done
}

for asg in "${asgs[@]}"; do
  echo "=== $asg"

  if [ "$skip_preflight" = 1 ]; then
    echo "Skipping preflight checks (--skip-preflight)."
  else
    if ! problem=$(cluster_problem preflight); then
      echo "Preflight failed, not replacing $asg: $problem" >&2
      exit 1
    fi
    echo "Preflight passed."
  fi

  old_id=$(in_service_instance "$asg")
  if [ -z "$old_id" ] || [ "$old_id" = "None" ]; then
    echo "No in-service instance found in $asg" >&2
    exit 1
  fi

  echo "Terminating $old_id in $asg (the ASG will launch a replacement)..."
  aws autoscaling terminate-instance-in-auto-scaling-group \
    --instance-id "$old_id" --no-should-decrement-desired-capacity >/dev/null

  echo "Waiting for a new in-service instance..."
  new_id=""
  for _ in $(seq 1 90); do
    new_id=$(in_service_instance "$asg")
    if [ -n "$new_id" ] && [ "$new_id" != "None" ] && [ "$new_id" != "$old_id" ]; then
      break
    fi
    new_id=""
    sleep 10
  done
  if [ -z "$new_id" ]; then
    echo "Timed out waiting for the replacement instance in $asg" >&2
    exit 1
  fi

  echo "Replacement is $new_id. Waiting for EC2 status checks..."
  aws ec2 wait instance-status-ok --instance-ids "$new_id"

  echo "Waiting for the cluster to be healthy again (peers present, replicas Active)..."
  wait_healthy || exit 1
done

echo "All requested nodes replaced."
