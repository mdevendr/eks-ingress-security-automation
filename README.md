# EKS Ingress Security Automation – Auto‑ShieldAdvanced, Auto‑HealthChecks, WebACL Attachment

## 1. Executive Summary

When you expose workloads from Amazon EKS via Kubernetes Ingress, the AWS Load Balancer Controller automatically creates Application Load Balancers (ALBs).  
By default, however, those ALBs are **not**:

- Registered as protected resources in **AWS Shield Advanced**
- Attached to the correct **AWS WAF WebACL**
- Covered by a standardised **Amazon Route 53 Health Check** in the right hosted zone

This design implements an **event‑driven security automation layer** so that *every* ALB created by EKS Ingress is:

1. Automatically attached to the correct WebACL (created separately by CI/CD)
2. Automatically added as a Shield Advanced protected resource
3. Automatically given a Route 53 health check in the relevant hosted zone

On ALB deletion, the same automation safely:

- Deletes the corresponding Route 53 health check
- Removes the ALB from the Shield Advanced protected resources
- Cleans up its state from DynamoDB

WAF WebACLs and WAF logging to SIEM (for example Azure Sentinel via Kinesis → S3) are created and managed by CI/CD and security teams; this pattern focuses purely on **binding each new ALB into those existing controls**.

---

## 2. Problem Statement

Without automation:

- Developers can create public ALBs via Ingress without any Shield Advanced protection.
- WebACL association is manual and often forgotten.
- Health checks are inconsistent, making DNS‑based resilience unreliable.
- Deleting an ALB can leave orphaned health checks and misaligned Shield Advanced configuration.

The goal is to make **“secure by default”** the easiest path: if an ALB exists, it is protected and monitored.

---

## 3. High‑Level Flow

1. CI/CD deploys an EKS Ingress object with the AWS Load Balancer Controller annotations.
2. The controller provisions an internet‑facing ALB and applies any required tags.
3. CloudTrail records the `CreateLoadBalancer` API call.
4. An Amazon EventBridge rule matches this event and invokes the **ManageProtectedResources** Lambda.
5. Lambda:
   - Reads ALB tags to understand which WebACL and DNS record to use.
   - Creates a Route 53 health check for the ALB DNS name.
   - Creates or updates a Route 53 Alias record in the specified hosted zone, wired to that health check.
   - Calls Shield Advanced APIs to add the ALB as a protected resource.
   - Associates the ALB with the correct WAF WebACL.
   - Persists the mapping (ALBArn, HealthCheckId, HostedZoneId, RecordName, canonical zone id, DNS name) into DynamoDB.
6. When an ALB is deleted, CloudTrail emits `DeleteLoadBalancer`:
   - EventBridge triggers the same Lambda in “delete” mode.
   - Lambda looks up the ALBArn in DynamoDB.
   - It deletes the Route 53 health check.
   - It removes the ALB from Shield Advanced protected resources.
   - It deletes the DynamoDB item for that ALB.
   - WebACL disassociation happens automatically as part of resource deletion.

Result: **no public ALB created by EKS can exist without Shield Advanced, WebACL attachment, and a health check.**

---

## 4. Key AWS Components

### 4.1 EKS + AWS Load Balancer Controller

- Ingress resources with `kubernetes.io/ingress.class: alb` trigger ALB creation.
- TLS and listener behaviour are driven via standard ALB Ingress annotations (certificate ARN, HTTPS ports, scheme etc.).
- CI/CD is responsible for applying these manifests.

### 4.2 CloudTrail

- Records the `CreateLoadBalancer` and `DeleteLoadBalancer` API calls from the `elasticloadbalancing.amazonaws.com` service.
- Acts as the authoritative event source for ALB lifecycle.

### 4.3 EventBridge Rules

Two rules on the default event bus:

- `CreateLoadBalancer` rule:
  - source: `aws.elasticloadbalancing`
  - detail‑type: `AWS API Call via CloudTrail`
  - eventName: `CreateLoadBalancer`
- `DeleteLoadBalancer` rule:
  - source: `aws.elasticloadbalancing`
  - detail‑type: `AWS API Call via CloudTrail`
  - eventName: `DeleteLoadBalancer`

Each rule targets the **ManageProtectedResources** Lambda.

### 4.4 Lambda – ManageProtectedResources

Single Lambda function that implements two paths:

- **Create path**
  - Extract ALB ARN, DNS name and canonical hosted zone id from the CloudTrail event.
  - Call `DescribeTags` to read ALB tags:
    - `waf-acl-arn` – ARN of the WebACL created by CI/CD.
    - `record-name` – full DNS name to create in Route 53.
    - `hosted-zone-id` – Route 53 public hosted zone to update.
  - Create a Route 53 health check targeting the ALB DNS name.
  - Create or update an Alias A record in the hosted zone pointing to the ALB (alias target = ALB DNS name + canonical hosted zone id) linked to the health check.
  - Add the ALB as a protected resource in Shield Advanced.
  - Associate the WebACL to the ALB.
  - Store ALBArn and all derived IDs in a DynamoDB item.

- **Delete path**
  - Extract ALB ARN from the CloudTrail event.
  - Look up the item in DynamoDB by ALBArn.
  - If the item is found:
    - Delete the Route 53 health check.
    - Remove the ALB from Shield Advanced protected resources.
    - Optionally clean up the Route 53 Alias record (depending on DNS strategy).
    - Delete the DynamoDB item.
  - If the item is not found, exit gracefully (idempotent behaviour).

### 4.5 DynamoDB – AlbStateTable

Used purely as a **lightweight state store** so the delete flow can safely undo what the create flow did.

Primary key:

- ALBArn (partition key, string)

Attributes:

- ALBArn
- DnsName
- CanonicalHostedZoneId
- HostedZoneId
- RecordName
- HealthCheckId

Billing mode: on‑demand for simplicity and cost‑efficiency.

### 4.6 Shield Advanced

- Shield Advanced is enabled at the account level.
- Lambda uses the Shield APIs to register and deregister ALB ARNs as protected resources.
- This ensures all EKS‑created public ALBs inherit DDoS detection, mitigation and reporting.

### 4.7 AWS WAF

- WebACLs are provisioned and configured via CI/CD (rules, rule groups, logging configuration etc.).
- Lambda only:
  - Looks up the WebACL ARN from the ALB tag.
  - Associates the ALB with that WebACL.
- When an ALB is deleted, WAF automatically removes the association; Lambda does **not** need to manage this explicitly.

---

## 5. Ingress and ALB Configuration

Although this repository focuses on the event‑driven automation, a consistent Ingress pattern is assumed.

Typical annotations on the Ingress:

- `kubernetes.io/ingress.class: alb`
- `alb.ingress.kubernetes.io/scheme: internet-facing`
- `alb.ingress.kubernetes.io/listen-ports: [{"HTTPS":443}]`
- `alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:REGION:ACCOUNT_ID:certificate/xxxx`

Typical tags on the resulting ALB (added via Ingress or post‑provision tagging):

- `waf-acl-arn` – ARN of the WebACL to attach.
- `record-name` – e.g. `service.example.com`.
- `hosted-zone-id` – ID of the public hosted zone where the Alias record must be created.

These tags decouple the automation from any specific application; the same Lambda can service many EKS clusters and ALBs.

---

## 6. IAM and Security Considerations

The Lambda execution role must be able to:

- Read ALB attributes and tags  
- Create and delete Route 53 health checks and alias records  
- Register and deregister protected resources in Shield Advanced  
- Associate ALBs to existing WAF WebACLs  
- Read/write items in the DynamoDB AlbStateTable  
- Write to CloudWatch Logs for observability  

Principle of least privilege still applies – in production, narrow the resources to specific hosted zones, WebACL ARNs and tables.

---

## 7. Operational Characteristics

- **Idempotent behaviour** – repeated events for the same ALB are handled safely by using DynamoDB as the single source of truth.
- **Failure visibility** – all actions (create / delete) are logged to CloudWatch Logs with ALB ARN context.
- **Scalability** – the pattern naturally scales with EventBridge and Lambda; DynamoDB on‑demand handles bursty ALB creation in large environments.
- **Separation of concerns** – CI/CD creates WebACL definitions and enables WAF logging; the event‑driven layer simply connects each ALB into those existing controls.

---

## 8. Business Value

For platform and security leaders, this pattern delivers:

- **Secure by default ingress** for EKS microservices.
- **Reduced operational risk** – no more “forgot to add Shield Advanced or WAF” incidents.
- **Consistent DNS and health‑check behaviour** across all externally exposed services.
- **Evidence of control** for regulators and auditors (PCI‑DSS, DORA, ISO 27001) showing that all public entry points are automatically protected.
- **Minimal developer friction** – teams continue to work with standard Ingress manifests while the platform takes care of advanced protections.

---

## 9. Future Extensions

- Multi‑region deployment with Route 53 latency/geo routing.
- Automatic selection of WebACL based on service tags or namespaces.
- Integration with AWS Config / Security Hub for drift detection.
- Use of AI/ML on WAF/SIEM data to recommend tighter rules per service.

---


Mahesh Devendran – Cloud Architect | Multi-Cloud (AWS/Azure/GCP) | Security, EKS, Serverless & Event-Driven Automation | Financial Services

This pattern was designed and tested as part of an EKS ingress hardening initiative, using real ALB create/delete events, Route 53 health checks, Shield Advanced protected resources, and DynamoDB‑backed state management.
