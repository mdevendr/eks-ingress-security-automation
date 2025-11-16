import json
import os
import logging
from datetime import datetime

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

elbv2 = boto3.client("elbv2")
wafv2 = boto3.client("wafv2")
route53 = boto3.client("route53")
dynamodb = boto3.client("dynamodb")

DDB_TABLE = os.environ.get("DDB_TABLE", "AlbStateTable")

'''
NOTE: 
DEMO ONLY!
Businesses use cases require production-grade code. Companies contact me for consulting.
If you need production-grade code with error handling, retries, idempotency, etc.

This Lambda function handles ALB create/delete events.
It performs the following actions:
- On CreateLoadBalancer:
  - Reads tags for WAF ACL ARN, Route53 record name and hosted zone ID
  - Creates a Route53 health check (not used in Alias A)
  - Associates WAF ACL if specified
  - Creates/updates Route53 Alias A record pointing to ALB
  - Stores state in DynamoDB
- On DeleteLoadBalancer:
  - Reads state from DynamoDB
  - Deletes Route53 Alias A record
  - Deletes Route53 health check
  - Deletes state from DynamoDB
'''

def lambda_handler(event, context):
    logger.info("Event: %s", json.dumps(event))

    detail = event.get("detail", {})
    event_name = detail.get("eventName")

    if event_name == "CreateLoadBalancer":
        return handle_create(detail)
    elif event_name == "DeleteLoadBalancer":
        return handle_delete(detail)
    else:
        logger.info("Ignoring eventName=%s", event_name)
        return {"status": "ignored", "eventName": event_name}

def handle_create(detail):
    lb = detail.get("responseElements", {}).get("loadBalancers", [{}])[0]

    lb_arn = lb.get("loadBalancerArn")
    dns_name = lb.get("dNSName")
    canonical_hz_id = lb.get("canonicalHostedZoneId")

    # ----- Tags -----
    tag_resp = elbv2.describe_tags(ResourceArns=[lb_arn])
    raw_tags = tag_resp["TagDescriptions"][0]["Tags"]
    tags = {t["Key"]: t["Value"] for t in raw_tags}

    web_acl_arn = tags.get("waf-acl-arn")
    record_name = tags.get("record-name")
    hosted_zone_id = tags.get("hosted-zone-id")

    # ----- Create health check (do NOT use in Alias A) -----
    import uuid
    caller_ref = str(uuid.uuid4())[:36]

    health_check_id = None
    try:
        resp = route53.create_health_check(
            CallerReference=caller_ref,
            HealthCheckConfig={
                "Type": "HTTPS",
                "FullyQualifiedDomainName": dns_name,
                "Port": 443,
                "ResourcePath": "/",
                "FailureThreshold": 3,
                "RequestInterval": 30
            }
        )
        health_check_id = resp["HealthCheck"]["Id"]
        logger.info(f"Created health check {health_check_id}")
    except ClientError as e:
        logger.error(f"Health check creation failed: {e}")

    # ----- Associate WAF -----
    if web_acl_arn:
        try:
            wafv2.associate_web_acl(WebACLArn=web_acl_arn, ResourceArn=lb_arn)
        except ClientError as e:
            logger.error(f"WAF association failed: {e}")

    # ----- UPSERT Alias A (NO HealthCheckId allowed) -----
    if record_name and hosted_zone_id:
        record_set = {
            "Name": record_name,
            "Type": "A",
            "AliasTarget": {
                "HostedZoneId": canonical_hz_id,
                "DNSName": dns_name,
                "EvaluateTargetHealth": True
            }
        }

        try:
            route53.change_resource_record_sets(
                HostedZoneId=hosted_zone_id,
                ChangeBatch={
                    "Comment": "ALB alias record",
                    "Changes": [
                        {
                            "Action": "UPSERT",
                            "ResourceRecordSet": record_set
                        }
                    ]
                }
            )
            logger.info("Alias A record created")
        except ClientError as e:
            logger.error(f"Alias record creation failed: {e}")

    # ----- Store in DynamoDB (correct key name) -----
    item = {
        "ALBArn": {"S": lb_arn},
        "DnsName": {"S": dns_name},
        "CanonicalHostedZoneId": {"S": canonical_hz_id}
    }

    if record_name:
        item["RecordName"] = {"S": record_name}
    if hosted_zone_id:
        item["HostedZoneId"] = {"S": hosted_zone_id}
    if web_acl_arn:
        item["WebACLArn"] = {"S": web_acl_arn}
    if health_check_id:
        item["HealthCheckId"] = {"S": health_check_id}

    try:
        dynamodb.put_item(TableName=DDB_TABLE, Item=item)
    except ClientError as e:
        logger.error(f"DynamoDB PutItem failed: {e}")

    return {"status": "ok", "albArn": lb_arn}

def handle_delete(detail):
    lb_arn = detail.get("requestParameters", {}).get("loadBalancerArn")
    print(f"[INFO] Delete ALB detected: {lb_arn}")

    # Fetch state from DynamoDB
    try:
        response = dynamodb.get_item(
            TableName=DDB_TABLE,
            Key={"ALBArn": {"S": lb_arn}}
        )
    except Exception as e:
        print(f"[ERROR] Failed to read state from DynamoDB: {e}")
        return

    if "Item" not in response:
        print(f"[WARN] No state stored for ALB {lb_arn}. Nothing to clean up.")
        return

    item = response["Item"]

    # Extract fields
    record_name = item.get("RecordName", {}).get("S")
    hosted_zone_id = item.get("HostedZoneId", {}).get("S")
    health_check_id = item.get("HealthCheckId", {}).get("S")
    dns_name = item.get("DnsName", {}).get("S")
    canonical_hz = item.get("CanonicalHostedZoneId", {}).get("S")

    # -------------------------
    # 1. Delete Route53 Alias
    # -------------------------
    try:
        if record_name and hosted_zone_id:
            print(f"[INFO] Removing Route53 alias {record_name}")
            route53.change_resource_record_sets(
                HostedZoneId=hosted_zone_id,
                ChangeBatch={
                    "Changes": [{
                        "Action": "DELETE",
                        "ResourceRecordSet": {
                            "Name": record_name,
                            "Type": "A",
                            "AliasTarget": {
                                "HostedZoneId": canonical_hz,
                                "DNSName": dns_name,
                                "EvaluateTargetHealth": False
                            }
                        }
                    }]
                }
            )
    except Exception as e:
        print(f"[ERROR] Failed deleting Route53 alias: {e}")

    # -------------------------
    # 2. Delete Health Check
    # -------------------------
    try:
        if health_check_id:
            print(f"[INFO] Deleting health check {health_check_id}")
            route53.delete_health_check(HealthCheckId=health_check_id)
    except Exception as e:
        print(f"[ERROR] Failed deleting health check: {e}")

    # -------------------------
    # 4. Delete DynamoDB Row
    # -------------------------
    try:
        print(f"[INFO] Deleting state record for {lb_arn}")
        dynamodb.delete_item(
            TableName=DDB_TABLE,
            Key={"ALBArn": {"S": lb_arn}}
        )
    except Exception as e:
        print(f"[ERROR] Failed deleting DynamoDB item: {e}")

def _get_str(item, key):
    val = item.get(key)
    if not val:
        return None
    return val.get("S")
