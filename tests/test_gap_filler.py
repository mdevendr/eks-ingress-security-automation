import importlib.util
import os
import pathlib
import sys
import types
import unittest
from unittest.mock import MagicMock, patch

os.environ.setdefault("AWS_DEFAULT_REGION", "eu-west-2")
os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")

boto3 = types.ModuleType("boto3")
boto3.client = MagicMock(return_value=MagicMock())
boto3.resource = MagicMock(return_value=MagicMock())
sys.modules.setdefault("boto3", boto3)
botocore = types.ModuleType("botocore")
botocore_config = types.ModuleType("botocore.config")
botocore_config.Config = MagicMock
sys.modules.setdefault("botocore", botocore)
sys.modules.setdefault("botocore.config", botocore_config)

MODULE_PATH = pathlib.Path(__file__).parents[1] / "shared" / "functions" / "gap-filler" / "lambda_function.py"
SPEC = importlib.util.spec_from_file_location("gap_filler", MODULE_PATH)
gap_filler = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(gap_filler)


class GapFillerTests(unittest.TestCase):
    def test_extracts_create_arn(self):
        detail = {"responseElements": {"loadBalancers": [{"loadBalancerArn": "arn:alb"}]}}
        self.assertEqual(gap_filler._created_alb_arn(detail), "arn:alb")

    def test_extracts_delete_arn(self):
        detail = {"requestParameters": {"loadBalancerArn": "arn:alb"}}
        self.assertEqual(gap_filler._deleted_alb_arn(detail), "arn:alb")

    def test_health_check_arn(self):
        self.assertEqual(gap_filler._health_check_arn("abc"), "arn:aws:route53:::healthcheck/abc")

    def test_ignores_unrelated_event(self):
        result = gap_filler.lambda_handler({"detail": {"eventName": "ModifyLoadBalancerAttributes"}}, MagicMock())
        self.assertEqual(result["status"], "ignored")

    @patch.object(gap_filler, "TABLE")
    @patch.object(gap_filler, "_discover")
    def test_stage_zero_create_does_not_require_hostname(self, discover, table):
        discover.return_value = (
            {"DNSName": "demo.elb.amazonaws.com", "CanonicalHostedZoneId": "ZALB"},
            {"secure-alb/id": "secure-alb-demo/demo"},
            None,
            None,
        )
        detail = {"responseElements": {"loadBalancers": [{"loadBalancerArn": "arn:alb"}]}}
        result = gap_filler.handle_create(detail, "event-1")
        self.assertEqual(result["Hostname"], "")
        self.assertEqual(result["HealthCheckStatus"], "NOT_REQUIRED")
        table.put_item.assert_called_once()

    @patch.object(gap_filler, "TABLE")
    def test_delete_is_idempotent(self, table):
        table.get_item.return_value = {}
        result = gap_filler.handle_delete(
            {"requestParameters": {"loadBalancerArn": "arn:alb"}}, "event-1"
        )
        self.assertEqual(result["status"], "already-absent")


if __name__ == "__main__":
    unittest.main()
