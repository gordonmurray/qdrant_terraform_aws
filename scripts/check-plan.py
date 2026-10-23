#!/usr/bin/env python3
"""Reject destructive changes to Qdrant state and unsafe deployment controls."""
import argparse
import json
import sys

# Applied to all matching types in the deployment, including resources removed
# from configuration. Deletion includes both replacement action orderings.
PROTECTED = {
    "aws_ebs_volume", "aws_network_interface", "aws_s3_bucket",
    "aws_kms_key", "aws_secretsmanager_secret", "aws_dynamodb_table",
    "aws_ssm_parameter", "aws_autoscaling_group",
    "aws_vpc", "aws_subnet", "aws_route_table", "aws_nat_gateway", "aws_internet_gateway",
}


def violations(plan):
    if plan.get("errored") or plan.get("complete") is False:
        yield "Plan is errored or incomplete."
    if "resource_changes" not in plan or not str(plan.get("format_version", "")).startswith("1."):
        yield "Expected a Terraform plan JSON document (format version 1.x)."
        return
    for resource in plan["resource_changes"]:
        address = resource["address"]
        kind = resource["type"]
        change = resource["change"]
        actions = change["actions"]
        if kind in PROTECTED and "delete" in actions:
            yield f"{address}: persistent resource deletion or replacement ({', '.join(actions)})."
        before = change.get("before") or {}
        after = change.get("after") or {}
        if kind == "aws_s3_bucket" and after.get("force_destroy"):
            yield f"{address}: force_destroy would allow deletion of backups."
        if kind in {"aws_lb", "aws_dynamodb_table"}:
            key = "enable_deletion_protection" if kind == "aws_lb" else "deletion_protection_enabled"
            if before.get(key) and not after.get(key):
                yield f"{address}: deletion protection removed."
        if kind == "aws_autoscaling_group" and "update" in actions:
            old = before.get("desired_capacity")
            new = after.get("desired_capacity")
            if old is not None and new is not None and new < old:
                yield f"{address}: desired capacity reduced. Drain and remove the peer first."


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", help="JSON from terraform show -json saved.tfplan")
    args = parser.parse_args()
    try:
        with open(args.plan, encoding="utf-8") as stream:
            errors = list(violations(json.load(stream)))
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"Cannot validate plan: {exc}", file=sys.stderr)
        return 1
    if errors:
        print("Plan blocked:\n" + "\n".join(f"- {error}" for error in errors), file=sys.stderr)
        return 1
    print("Plan passed the destructive-change policy.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
