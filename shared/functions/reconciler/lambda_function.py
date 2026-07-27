"""Scheduled drift detection and remediation shared by Stages 1 and 2."""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.config import Config

LOG = logging.getLogger()
LOG.setLevel(os.getenv("LOG_LEVEL", "INFO"))
MODE = os.getenv("MODE", "AUDIT").upper()
SHIELD_ADVANCED_ENABLED = os.getenv("SHIELD_ADVANCED_ENABLED", "false").lower() == "true"
CONFIG = Config(retries={"total_max_attempts": 5, "mode": "adaptive"}, connect_timeout=3, read_timeout=10)
ELBV2 = boto3.client("elbv2", config=CONFIG)
WAFV2 = boto3.client("wafv2", config=CONFIG)
SHIELD = boto3.client("shield", config=CONFIG)
ROUTE53 = boto3.client("route53", config=CONFIG)
TABLE = boto3.resource("dynamodb", config=CONFIG).Table(
    os.environ.get("DDB_TABLE", "EksSecureAlbInventory")
)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _health_check_arn(check_id: str) -> str:
    return f"arn:{os.getenv('AWS_PARTITION', 'aws')}:route53:::healthcheck/{check_id}"


def _scan_inventory() -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    kwargs: dict[str, Any] = {}
    while True:
        response = TABLE.scan(**kwargs)
        items.extend(response.get("Items", []))
        key = response.get("LastEvaluatedKey")
        if not key:
            return items
        kwargs["ExclusiveStartKey"] = key


def _protection_for(alb_arn: str) -> dict[str, Any] | None:
    paginator = SHIELD.get_paginator("list_protections")
    for protection in paginator.paginate().search("Protections[]"):
        if protection and protection.get("ResourceArn") == alb_arn:
            return protection
    return None


def _alb_exists(alb_arn: str) -> bool:
    try:
        ELBV2.describe_load_balancers(LoadBalancerArns=[alb_arn])
        return True
    except ELBV2.exceptions.LoadBalancerNotFoundException:
        return False


def _waf_arn(alb_arn: str) -> str:
    response = WAFV2.get_web_acl_for_resource(ResourceArn=alb_arn)
    web_acl = response.get("WebACL") or response.get("WebACLSummary") or {}
    return web_acl.get("ARN", "")


def _health_check_exists(check_id: str) -> bool:
    try:
        ROUTE53.get_health_check(HealthCheckId=check_id)
        return True
    except ROUTE53.exceptions.NoSuchHealthCheck:
        return False


def reconcile(item: dict[str, Any]) -> dict[str, Any]:
    alb_arn = item["ALBArn"]
    findings: list[str] = []
    actions: list[str] = []
    if not _alb_exists(alb_arn):
        findings.append("ALB_MISSING")
    else:
        expected_waf = item.get("WebACLArn", "")
        actual_waf = _waf_arn(alb_arn) if expected_waf else ""
        if expected_waf and actual_waf != expected_waf:
            findings.append("WAF_ASSOCIATION_DRIFT")
            if MODE == "REMEDIATE":
                WAFV2.associate_web_acl(WebACLArn=expected_waf, ResourceArn=alb_arn)
                actions.append("WAF_REASSOCIATED")

        if SHIELD_ADVANCED_ENABLED:
            protection = _protection_for(alb_arn)
            if not protection:
                findings.append("SHIELD_PROTECTION_MISSING")
            else:
                protection_id = protection["Id"]
                described = SHIELD.describe_protection(ProtectionId=protection_id)["Protection"]
                check_id = item.get("HealthCheckId", "")
                if check_id and check_id not in described.get("HealthCheckIds", []):
                    findings.append("SHIELD_HEALTH_CHECK_DRIFT")
                    if MODE == "REMEDIATE" and _health_check_exists(check_id):
                        SHIELD.associate_health_check(
                            ProtectionId=protection_id,
                            HealthCheckArn=_health_check_arn(check_id),
                        )
                        actions.append("HEALTH_CHECK_REASSOCIATED")

        check_id = item.get("HealthCheckId", "")
        if check_id and not _health_check_exists(check_id):
            findings.append("ROUTE53_HEALTH_CHECK_MISSING")

    status = "COMPLIANT" if not findings else ("REMEDIATED" if actions else "NON_COMPLIANT")
    TABLE.update_item(
        Key={"ALBArn": alb_arn},
        UpdateExpression="SET LastObservedAt=:at, LastReconciliationStatus=:status, Findings=:findings, Actions=:actions",
        ExpressionAttributeValues={":at": _now(), ":status": status, ":findings": findings, ":actions": actions},
    )
    return {"albArn": alb_arn, "status": status, "findings": findings, "actions": actions}


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    results = [reconcile(item) for item in _scan_inventory()]
    summary = {"mode": MODE, "checked": len(results), "results": results}
    LOG.info(json.dumps(summary))
    return summary
