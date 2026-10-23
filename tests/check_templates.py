#!/usr/bin/env python3
"""Render real Terraform templates and lint the resulting shell programs."""
import itertools
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
VARIABLES = dict(region="eu-west-1", rest_port=6333, p2p_port=6335,
                 cluster_name="test", node_index=0, node_count=3, canary_replicas=3,
                 bucket="test-snapshots", data_mount="/qdrant/data",
                 eni_id="eni-123", volume_id="vol-123", secret_arn="arn:aws:secretsmanager:eu-west-1:123456789012:secret:test",
                 image="docker.io/qdrant/qdrant@sha256:" + "a" * 64,
                 node_ip="10.0.1.10", state_param="/qdrant/test/cluster-state",
                 log_group="/qdrant/test", node_name="test-0")


def render(path, variables, cwd, yaml=False):
    expression = f'templatefile({json.dumps(str(path))}, jsondecode({json.dumps(json.dumps(variables))}))'
    if yaml:
        expression = f"yamldecode({expression})"
    # jsonencode avoids Terraform's multiline display format.
    result = subprocess.run(["terraform", "console"], input=f"jsonencode({expression})", cwd=cwd,
                            text=True, capture_output=True, check=True)
    return json.loads(json.loads(result.stdout))


with tempfile.TemporaryDirectory() as tmp:
    directory = Path(tmp)
    count = 0
    for path in sorted((ROOT / "modules/qdrant/templates").glob("*.sh.tftpl")):
        variants = [dict(scrape_metrics=True, ecr_login=False, cached_image=False)]
        if path.name == "qdrant-run.sh.tftpl":
            variants = [dict(scrape_metrics=True, ecr_login=ecr, cached_image=cached)
                        for ecr, cached in itertools.product([False, True], repeat=2)]
        if path.name == "qdrant-canary.sh.tftpl":
            variants.append(dict(scrape_metrics=False, ecr_login=False, cached_image=False))
        for i, variant in enumerate(variants):
            script = directory / f"{path.stem}-{i}.sh"
            script.write_text(render(path, VARIABLES | variant, tmp))
            subprocess.run(["bash", "-n", str(script)], check=True)
            subprocess.run(["shellcheck", str(script)], check=True)
            count += 1
    for install, monitoring, backups in itertools.product([False, True], repeat=3):
        config = render(ROOT / "modules/qdrant/templates/user_data.yaml.tftpl", dict(
            install_packages=install, monitoring=monitoring, backups=backups,
            files=[dict(path="/etc/qdrant/test", permissions="0644", content="test\n")],
        ), tmp, yaml=True)
        script = directory / "cloud-init-runcmd.sh"
        script.write_text("#!/bin/bash\n" + "\n".join(config["runcmd"]) + "\n")
        subprocess.run(["bash", "-n", str(script)], check=True)
        subprocess.run(["shellcheck", str(script)], check=True)
        assert ("dnf install" in script.read_text()) == install
        count += 1
    print(f"Rendered and checked {count} shell and cloud-init template variants.")
