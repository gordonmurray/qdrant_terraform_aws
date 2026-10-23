"""Exercise the real replacement script with an isolated fake AWS/API boundary."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
AWS = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
root = Path(os.environ["FAKE_STATE"])
with (root / "calls").open("a") as stream:
    stream.write(" ".join(args) + "\\n")
mode = os.environ.get("FAKE_MODE", "success")
if args[:2] == ["dynamodb", "put-item"]:
    if mode == "locked": sys.exit(1)
    (root / "lock").touch()
elif args[:2] == ["dynamodb", "delete-item"]:
    (root / "lock").unlink()
elif args[:2] == ["autoscaling", "describe-auto-scaling-groups"]:
    query = args[args.index("--query") + 1]
    if "Tags" in query: print("test")
    elif query.endswith("LaunchTemplate"):
        print(json.dumps({"LaunchTemplateId": "lt-test", "Version": "2"}))
    else: print("i-new" if (root / "terminated").exists() else "i-old")
elif args[:2] == ["autoscaling", "terminate-instance-in-auto-scaling-group"]:
    (root / "terminated").touch()
elif args[:2] == ["autoscaling", "describe-auto-scaling-instances"]:
    print(json.dumps({"LaunchTemplateId": "lt-test", "Version": "1" if mode == "wrong-version" else "2"}))
elif args[:2] == ["ec2", "describe-network-interfaces"]: print("10.0.1.10")
elif args[:2] == ["ec2", "wait"]: pass
elif args[:2] == ["elbv2", "describe-target-health"]:
    print(json.dumps({"TargetHealthDescriptions": [{"Target": {"Id": "10.0.1.10"}, "TargetHealth": {"State": "unhealthy" if mode == "unhealthy-preflight" else "healthy"}}]}))
else:
    print("Unexpected AWS command: " + str(args), file=sys.stderr)
    sys.exit(2)
'''
CURL = '''#!/usr/bin/env python3
import json, os, sys
url = sys.argv[-1]
if url.endswith("/readyz"): print("ok")
elif url.endswith("/collections/demo/cluster"):
    print(json.dumps({"result": {"local_shards": [{"shard_id": 0, "state": "Active"}], "remote_shards": [{"shard_id": 0, "state": "Active"}] * 2}}))
elif url.endswith("/cluster"): print(json.dumps({"result": {"peers": {"a": {}, "b": {}, "c": {}}}}))
elif url.endswith("/collections"):
    print(json.dumps({"result": {"collections": [{"name": "demo"}]}}))
elif url.endswith("/collections/demo"):
    print(json.dumps({"result": {"config": {"params": {"replication_factor": 1 if os.environ.get("FAKE_MODE") == "unsafe-collection" else 3, "write_consistency_factor": 2, "shard_number": 1}}}}))
else: sys.exit(2)
'''


class ReplacementTests(unittest.TestCase):
    def run_script(self, mode):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            for name, contents in {"aws": AWS, "curl": CURL}.items():
                path = directory / name
                path.write_text(contents)
                path.chmod(0o755)
            env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}", FAKE_STATE=tmp,
                       FAKE_MODE=mode, QDRANT_URL="https://qdrant.example.com:6333",
                       QDRANT_API_KEY="test", REPLACEMENT_LOCK_TABLE="test-maintenance",
                       HEALTH_STABLE_SECONDS="0", QDRANT_TARGET_GROUP_ARNS="arn:rest arn:grpc")
            result = subprocess.run(["bash", str(ROOT / "scripts/replace-node.sh"), "test-0"],
                                    env=env, text=True, capture_output=True, timeout=15)
            return result, (directory / "calls").read_text(), (directory / "lock").exists()

    def test_success_checks_version_targets_and_releases_lock(self):
        result, calls, locked = self.run_script("success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("describe-auto-scaling-instances", calls)
        self.assertEqual(calls.count("describe-target-health"), 4)
        self.assertFalse(locked)

    def test_competing_operator_cannot_terminate(self):
        result, calls, _ = self.run_script("locked")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("terminate-instance", calls)

    def test_wrong_version_retains_lock_and_stops(self):
        result, calls, locked = self.run_script("wrong-version")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected launch template", result.stderr)
        self.assertNotIn("delete-item", calls)
        self.assertTrue(locked)

    def test_unsafe_collection_cannot_terminate(self):
        result, calls, locked = self.run_script("unsafe-collection")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("terminate-instance", calls)
        self.assertTrue(locked)

    def test_unhealthy_target_cannot_terminate(self):
        result, calls, locked = self.run_script("unhealthy-preflight")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("terminate-instance", calls)
        self.assertTrue(locked)
