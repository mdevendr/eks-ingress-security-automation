"""Convert operational events into bounded, instruction-free AI input."""

from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone
from typing import Any

ALLOWED_FINDINGS = {
    "WAF_ASSOCIATION_DRIFT",
    "SHIELD_PROTECTION_MISSING",
    "SHIELD_HEALTH_CHECK_DRIFT",
    "ROUTE53_HEALTH_CHECK_MISSING",
    "ALB_MISSING",
    "CONTROLLER_NOT_READY",
}
ALLOWED_SOURCES = {"reconciler", "kubernetes", "cloudtrail", "waf", "shield"}
MAX_SAMPLES = 20
MAX_VALUE_BYTES = 2048
ALLOWED_POLICIES = {"", "regulated-public", "standard-public", "internal-api"}
ALLOWED_SEVERITIES = {"LOW", "MEDIUM", "HIGH", "CRITICAL", "UNKNOWN"}


class InvalidFinding(ValueError):
    pass


def _hash_untrusted(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), default=str).encode()
    if len(encoded) > MAX_VALUE_BYTES:
        encoded = encoded[:MAX_VALUE_BYTES]
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def normalize(raw: dict[str, Any]) -> dict[str, Any]:
    trusted = raw.get("trustedMetadata")
    if not isinstance(trusted, dict):
        raise InvalidFinding("trustedMetadata is required")
    finding_type = trusted.get("findingType")
    source = trusted.get("source")
    if finding_type not in ALLOWED_FINDINGS:
        raise InvalidFinding("findingType is not allowlisted")
    if source not in ALLOWED_SOURCES:
        raise InvalidFinding("source is not allowlisted")
    resource_arn = trusted.get("resourceArn", "")
    if not isinstance(resource_arn, str) or not resource_arn.startswith("arn:aws:"):
        raise InvalidFinding("resourceArn is invalid")

    expected_policy = trusted.get("expectedPolicy", "")
    if expected_policy not in ALLOWED_POLICIES:
        raise InvalidFinding("expectedPolicy is not allowlisted")
    observed_waf = trusted.get("observedWebAclArn", "")
    if observed_waf and not str(observed_waf).startswith("arn:aws:wafv2:"):
        raise InvalidFinding("observedWebAclArn is invalid")
    severity = trusted.get("severity", "UNKNOWN")
    if severity not in ALLOWED_SEVERITIES:
        raise InvalidFinding("severity is invalid")

    samples = raw.get("untrustedTrafficSamples") or []
    if not isinstance(samples, list):
        raise InvalidFinding("trafficSamples must be a list")
    hashes = [_hash_untrusted(sample) for sample in samples[:MAX_SAMPLES]]

    return {
        "schemaVersion": "1.0",
        "findingType": finding_type,
        "resourceArn": resource_arn,
        "expectedPolicy": expected_policy,
        "observedWebAclArn": observed_waf,
        "severity": severity,
        "source": source,
        "observedAt": str(trusted.get("observedAt") or datetime.now(timezone.utc).isoformat()),
        "untrustedTrafficSummary": {
            "sampleCount": len(samples),
            "sampleHashes": hashes,
            "rawContentIncluded": False,
            "trustLevel": "UNTRUSTED",
        },
    }
