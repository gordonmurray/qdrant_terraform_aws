import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("policy", Path(__file__).resolve().parents[1] / "scripts/check-plan.py")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


def plan(kind, actions, before=None, after=None):
    return {"format_version": "1.2", "resource_changes": [{
        "address": f'module.qdrant.{kind}.data["0"]', "type": kind,
        "change": {"actions": actions, "before": before, "after": after},
    }]}


class PlanPolicyTests(unittest.TestCase):
    def test_replacements_blocked_in_both_orders(self):
        for kind in policy.PROTECTED:
            for actions in (["delete"], ["delete", "create"], ["create", "delete"]):
                with self.subTest(kind=kind, actions=actions):
                    self.assertTrue(list(policy.violations(plan(kind, actions))))

    def test_volume_expansion_and_new_node_allowed(self):
        self.assertFalse(list(policy.violations(plan("aws_ebs_volume", ["update"], {"size": 50}, {"size": 100}))))
        self.assertFalse(list(policy.violations(plan("aws_network_interface", ["create"]))))

    def test_controls_cannot_be_weakened(self):
        for kind, before, after in [
            ("aws_s3_bucket", {}, {"force_destroy": True}),
            ("aws_lb", {"enable_deletion_protection": True}, {"enable_deletion_protection": False}),
            ("aws_dynamodb_table", {"deletion_protection_enabled": True}, {}),
            ("aws_autoscaling_group", {"desired_capacity": 1}, {"desired_capacity": 0}),
        ]:
            with self.subTest(kind=kind):
                self.assertTrue(list(policy.violations(plan(kind, ["update"], before, after))))

    def test_invalid_and_incomplete_plan_rejected(self):
        for value in ({}, {"format_version": "1.2", "resource_changes": [], "complete": False}):
            self.assertTrue(list(policy.violations(value)))
