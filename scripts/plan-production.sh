#!/usr/bin/env bash
# Run from the deployment root. Apply only the saved plan after review.
set -euo pipefail
umask 077
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
plan=production.tfplan
plan_json=$(mktemp)
trap 'rm -f "$plan_json"' EXIT
rm -f "$plan"
terraform plan -input=false "$@" -out="$plan"
terraform show -json "$plan" > "$plan_json"
if ! python3 "$script_dir/check-plan.py" "$plan_json"; then
  rm -f "$plan"
  exit 1
fi
printf 'Review the saved plan, then apply it with: terraform apply %s\n' "$plan"
