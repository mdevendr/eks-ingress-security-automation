"""
NOTE:
DEMO ONLY!

Business use cases require production-grade code. Companies may contact the
author for consulting if they need production-grade implementation, including
additional error handling, retries, idempotency, testing, and operational
controls.

This Lambda function handles ALB create/delete events.

It performs the following actions:
- On CreateLoadBalancer:
  - Reads the platform tags applied to the ALB
  - Records the ALB lifecycle event for Stage 0 EDA proving
  - In evolved stages, discovers the Route 53 health check created by ACK
  - When Shield Advanced is enabled, associates the health check with the
    existing Shield protection
  - Stores ALB, WAF, health-check, and lifecycle state in DynamoDB for the
    scheduled reconciler
- On DeleteLoadBalancer:
  - Reads the stored lifecycle state from DynamoDB
  - When Shield Advanced is enabled, removes the health-check association
  - Deletes the lifecycle state from DynamoDB

ExternalDNS owns Route 53 DNS records, ACK owns health-check creation and
deletion, and the AWS Load Balancer Controller owns ALB and WAF configuration.
"""

from __future__ import annotations

import json
import logging
import os
import time
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.config import Config

LOG = logging.getLogger()
LOG.setLevel(os.getenv("LOG_LEVEL", "INFO"))

CONFIG = Config(
    retries={"total_max_attempts": 6, "mode": "adaptive"},
    connect_timeout=3,
    read_timeout=10,
    user_agent_appid="eks-secure-alb-gap-filler/1.0",
)
ELBV2 = boto3.client("elbv2", config=CONFIG)
ROUTE53 = boto3.client("route53", config=CONFIG)
SHIELD = boto3.client("shield", config=CONFIG)
DDB = boto3.resource("dynamodb", config=CONFIG)
TABLE = DDB.Table(os.environ.get("DDB_TABLE", "EksSecureAlbInventory"))

MAX_DISCOVERY_ATTEMPTS = int(os.getenv("MAX_DISCOVERY_ATTEMPTS", "8"))
DISCOVERY_DELAY_SECONDS = float(os.getenv("DISCOVERY_DELAY_SECONDS", "5"))
SHIELD_ADVANCED_ENABLED = os.getenv("SHIELD_ADVANCED_ENABLED", "false").lower() == "true"
REQUIRE_HEALTH_CHECK = os.getenv("REQUIRE_HEALTH_CHECK", "true").lower() == "true"


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _log(message: str, **fields: Any) -> None:
    LOG.info(json.dumps({"message": message, **fields}, default=str))


def _event_name(detail: dict[str, Any]) -> str | None:
    return detail.get("eventName")


def _created_alb_arn(detail: dict[str, Any]) -> str | None:
    load_balancers = detail.get("responseElements", {}).get("loadBalancers") or []
    return load_balancers[0].get("loadBalancerArn") if load_balancers else None


def _deleted_alb_arn(detail: dict[str, Any]) -> str | None:
    return detail.get("requestParameters", {}).get("loadBalancerArn")


def _tags(alb_arn: str) -> dict[str, str]:
    response = ELBV2.describe_tags(ResourceArns=[alb_arn])
    descriptions = response.get("TagDescriptions", [])
    if not descriptions:
        return {}
    return {tag["Key"]: tag["Value"] for tag in descriptions[0].get("Tags", [])}


def _describe_alb(alb_arn: str) -> dict[str, Any]:
    response = ELBV2.describe_load_balancers(LoadBalancerArns=[alb_arn])
    return response["LoadBalancers"][0]


def _find_protection(alb_arn: str) -> dict[str, Any] | None:
    paginator = SHIELD.get_paginator("list_protections")
    for protection in paginator.paginate().search("Protections[]"):
        if protection and protection.get("ResourceArn") == alb_arn:
            return protection
    return None


def _find_health_check(hostname: str) -> dict[str, Any] | None:
    paginator = ROUTE53.get_paginator("list_health_checks")
    normalized = hostname.rstrip(".").lower()
    for check in paginator.paginate().search("HealthChecks[]"):
        fqdn = (check or {}).get("HealthCheckConfig", {}).get(
            "FullyQualifiedDomainName", ""
        )
        if fqdn.rstrip(".").lower() == normalized:
            return check
    return None


def _health_check_arn(health_check_id: str) -> str:
    partition = os.getenv("AWS_PARTITION", "aws")
    return f"arn:{partition}:route53:::healthcheck/{health_check_id}"


def _discover(alb_arn: str) -> tuple[dict[str, Any], dict[str, str], dict[str, Any] | None, dict[str, Any] | None]:
    last_missing: list[str] = []
    for attempt in range(1, MAX_DISCOVERY_ATTEMPTS + 1):
        alb = _describe_alb(alb_arn)
        tags = _tags(alb_arn)
        hostname = tags.get("secure-alb/hostname")
        protection = _find_protection(alb_arn) if SHIELD_ADVANCED_ENABLED else None
        health_check = _find_health_check(hostname) if hostname else None
        last_missing = [
            name
            for name, value in (
                ("secure-alb/hostname tag", hostname if REQUIRE_HEALTH_CHECK else True),
                ("Shield protection", protection if SHIELD_ADVANCED_ENABLED else True),
                ("Route 53 health check", health_check if REQUIRE_HEALTH_CHECK else True),
            )
            if not value
        ]
        if not last_missing:
            return alb, tags, protection, health_check
        _log("dependencies_not_ready", attempt=attempt, missing=last_missing, albArn=alb_arn)
        if attempt < MAX_DISCOVERY_ATTEMPTS:
            time.sleep(DISCOVERY_DELAY_SECONDS)
    raise RuntimeError(f"Dependencies not ready for {alb_arn}: {', '.join(last_missing)}")


def handle_create(detail: dict[str, Any], event_id: str) -> dict[str, Any]:
    alb_arn = _created_alb_arn(detail)
    if not alb_arn:
        raise ValueError("CreateLoadBalancer event has no loadBalancerArn")

    alb, tags, protection, health_check = _discover(alb_arn)
    health_check_id = health_check["Id"] if health_check else ""
    protection_id = protection["Id"] if protection else ""
    if SHIELD_ADVANCED_ENABLED:
        attached_ids = SHIELD.describe_protection(ProtectionId=protection_id)["Protection"].get(
            "HealthCheckIds", []
        )
        if health_check_id not in attached_ids:
            SHIELD.associate_health_check(
                ProtectionId=protection_id,
                HealthCheckArn=_health_check_arn(health_check_id),
            )

    item = {
        "ALBArn": alb_arn,
        "SecureALBId": tags.get("secure-alb/id", alb_arn.rsplit("/", 1)[-1]),
        "Hostname": tags.get("secure-alb/hostname", ""),
        "DNSName": alb["DNSName"],
        "CanonicalHostedZoneId": alb["CanonicalHostedZoneId"],
        "WebACLArn": tags.get("secure-alb/web-acl-arn", ""),
        "ProtectionId": protection_id,
        "ShieldAdvancedStatus": "ASSOCIATED" if SHIELD_ADVANCED_ENABLED else "NOT_EXECUTED",
        "HealthCheckId": health_check_id,
        "HealthCheckStatus": "DISCOVERED" if health_check else "NOT_REQUIRED",
        "LifecycleState": "ACTIVE",
        "LastEventId": event_id,
        "LastObservedAt": _now(),
        "LastReconciliationStatus": "PENDING",
    }
    TABLE.put_item(Item=item)
    _log("inventory_recorded", albArn=alb_arn, protectionId=protection_id, healthCheckId=health_check_id, shieldAdvancedEnabled=SHIELD_ADVANCED_ENABLED)
    return {"status": "associated", **item}


def handle_delete(detail: dict[str, Any], event_id: str) -> dict[str, Any]:
    alb_arn = _deleted_alb_arn(detail)
    if not alb_arn:
        raise ValueError("DeleteLoadBalancer event has no loadBalancerArn")
    item = TABLE.get_item(Key={"ALBArn": alb_arn}, ConsistentRead=True).get("Item")
    if not item:
        _log("delete_is_idempotent", albArn=alb_arn, eventId=event_id)
        return {"status": "already-absent", "ALBArn": alb_arn}

    protection_id = item.get("ProtectionId")
    health_check_id = item.get("HealthCheckId")
    if protection_id and health_check_id:
        try:
            SHIELD.disassociate_health_check(
                ProtectionId=protection_id,
                HealthCheckArn=_health_check_arn(health_check_id),
            )
        except SHIELD.exceptions.ResourceNotFoundException:
            pass
    TABLE.delete_item(Key={"ALBArn": alb_arn})
    _log("inventory_removed", albArn=alb_arn, eventId=event_id)
    return {"status": "deleted", "ALBArn": alb_arn}


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    detail = event.get("detail", {})
    name = _event_name(detail)
    event_id = event.get("id", getattr(context, "aws_request_id", "unknown"))
    _log("event_received", eventName=name, eventId=event_id)
    if name == "CreateLoadBalancer":
        return handle_create(detail, event_id)
    if name == "DeleteLoadBalancer":
        return handle_delete(detail, event_id)
    return {"status": "ignored", "eventName": name}
