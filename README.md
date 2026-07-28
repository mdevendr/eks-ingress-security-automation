## EKS Ingress Security Automation – Event-Driven Shield Advanced, WAF, and Health-Check Enforcement
#### Mahesh Devendran — Cloud Architect | Multi-Cloud | Security & Resilience Architecture | EKS | Serverless | Event-Driven Platforms | Financial Services
https://www.linkedin.com/in/mahesh-devendran-83a3b214/

### Executive Overview

Modern organisations deploying workloads on Amazon EKS rely on Kubernetes Ingress to publish services externally. The AWS Load Balancer Controller automatically provisions Application Load Balancers (ALBs) for these ingress definitions, but these ALBs are not secure by default.

They are created without mandatory security and resilience controls such as:

- Registration as protected resources in AWS Shield Advanced
- Association with the correct AWS WAF WebACL
- Route 53 health checks required for reliable DNS failover
- Consistent lifecycle governance and clean deletion behaviour

In regulated sectors such as Financial Services, Insurance, and Payments, this becomes a governance, compliance, and operational risk.

This architecture introduces an event-driven security automation layer that ensures every ALB created through EKS Ingress is automatically protected, monitored, and centrally governed.

Linkedin Post : https://lnkd.in/p/epDv3wSY

---

# 2026 Native-Capability Implementation

The repository now includes a script-driven implementation of the evolved architecture:

- Amazon EKS with a single diversified Spot managed node group and no NAT Gateway
- Stage 0 control case using the established Kubernetes Ingress model
- Kubernetes Gateway API and AWS Load Balancer Controller ALB Gateway support
- Stage 1 explicit Gateway API resources with ACK and ExternalDNS
- Stage 2 managed kro composition through a platform-authored `SecureALB` API
- ConfigMap-backed logical WAF policies, so applications never submit raw WebACL ARNs
- mandatory WAF, Shield Advanced, TLS, invalid-header dropping, and ALB access logs
- a gap-filler Lambda that associates the ACK health check with the Shield protection
- a scheduled reconciler with `AUDIT` and `REMEDIATE` modes
- admission enforcement for WAF, Shield, and access logging
- smoke, drift-remediation, evidence, and teardown scripts

Firewall Manager is intentionally outside the current scope.

## Cost and safety boundary

The lab never creates a Shield Advanced subscription. `SHIELD_ALREADY_SUBSCRIBED=true` is required and `describe-subscription` must succeed. Use an account that is already subscribed and tear the lab down immediately after evidence capture.

## Configure

Prerequisites are AWS CLI v2, Python 3, kubectl, an existing Regional WAFv2 WebACL, public hosted zone, validated ACM certificate, ALB-log S3 bucket, and Shield Advanced subscription.

```bash
cp config/example.env config/lab.env
${EDITOR:-vi} config/lab.env
./scripts/install-tools.sh
```

## Validate locally

```bash
python -m py_compile shared/functions/gap-filler/lambda_function.py shared/functions/reconciler/lambda_function.py stages/03-ai-operations/normalizer.py
python -m unittest discover -s tests -p 'test_*.py'
bash -n scripts/*.sh
./scripts/package-functions.sh
```

## Deploy, test, and collect evidence

Run from Git Bash:

```bash
./scripts/deploy-all.sh config/lab.env 0
./scripts/deploy-all.sh config/lab.env 1
./scripts/test-drift.sh config/lab.env
./scripts/capture-evidence.sh config/lab.env 1
```

Stage 0 is the original-model EDA control case. It deploys a minimal HTTP Kubernetes `Ingress` and proves the ALB create/delete path through CloudTrail, EventBridge, Lambda and DynamoDB without requiring WAF, Shield, ACM, Route 53, ACK or ExternalDNS. Stage 1 is the Gateway API golden baseline and deploys explicit `Gateway`, `HTTPRoute`, `LoadBalancerConfiguration`, `TargetGroupConfiguration`, and ACK `HealthCheck` resources. ExternalDNS owns Route 53 records from Stage 1 onward; the Lambda owns lifecycle inventory and the optional Shield health-check association.

After Stage 1 evidence is captured, transition to Stage 2 without rebuilding the cluster:

```bash
./stages/01-gateway-api/teardown.sh config/lab.env
./scripts/enable-capabilities.sh config/lab.env ALL
./scripts/deploy-kubernetes.sh config/lab.env 2
./scripts/smoke-test.sh config/lab.env
./stages/02-kro/test-policy-guardrails.sh
./scripts/test-drift.sh config/lab.env
./scripts/capture-evidence.sh config/lab.env 2
```

Stage 2 must produce the same AWS controls as Stage 1. Differences are treated as kro-specific until proven otherwise.

## Repository stages

```text
shared/                  reusable Lambdas, IAM and platform controls
stages/00-ingress/       existing Ingress and annotation-based control case
stages/01-gateway-api/   explicit golden-baseline resources
stages/02-kro/           SecureALB RGD, WAF catalogue and RBAC tests
stages/03-ai-operations/ normalized, instruction-free AI input boundary
```

Stage 3 remains advisory until both deterministic stages have evidence. Raw attacker-controlled headers, paths and request data are never passed to the model; the normalizer provides bounded hashes and trusted finding metadata.

The platform-version milestones and the reason each stage exists are maintained in [Architecture evolution and version timeline](docs/architecture-evolution.md). Update that document whenever a platform capability changes a stage boundary.

## Teardown

```bash
./scripts/teardown-all.sh config/lab.env "$RUN_ID"
```

Teardown removes the `SecureALB` while kro and ACK are active, then deletes the capabilities, serverless infrastructure, and EKS cluster.

---

# The Challenge

EKS makes deployment effortless, but that same agility introduces architectural risks:

- Security attachments depend on manual actions or team-specific pipelines
- ALBs may remain publicly exposed without Shield Advanced or WAF
- DNS and health checks differ between services, weakening resilience
- ALB deletion leaves orphaned resources such as health checks
- Audit and security teams cannot enforce protection uniformly

The enterprise needs a platform-level mechanism that enforces secure-by-default ingress across all microservices.

---
<img width="3807" height="1755" alt="ShieldAdvance" src="https://github.com/user-attachments/assets/8aed4f9b-e180-4f89-92d4-f0cb84b49837" />


---

# The Architecture

The solution is built on a principle:
“If an ALB exists, it must be protected.”

When an EKS Ingress triggers ALB creation:

- CloudTrail records the API call
- EventBridge detects the lifecycle event
- A central Lambda function applies all required security controls

The automation:

- Reads ALB attributes and tags
- Attaches the ALB to the appropriate WebACL (managed through CI/CD)
- Registers the ALB with AWS Shield Advanced
- Creates standardised Route 53 health checks
- ExternalDNS creates and reconciles Route 53 records from `HTTPRoute.spec.hostnames`
- Stores all ALB metadata in DynamoDB for reliable cleanup

When the ALB is deleted, the automation reverses the workflow:

- Removes it from Shield Advanced
- Deletes associated health checks
- ExternalDNS removes the DNS records it owns when the corresponding routes are deleted
- Deletes the DynamoDB state

This ensures that ingress security is automatically enforced from creation to deletion.


---

# Architectural Insights

Event-driven enforcement  
Using CloudTrail and EventBridge ensures every ALB—regardless of cluster, namespace, or team—is covered without modifying CI/CD pipelines.

Clear separation of responsibilities  
- CI/CD defines WebACLs, WAF logging, and SIEM ingestion  
- The automation layer enforces the controls for every ALB  
- Security teams govern rules, not lifecycle events

Tag-driven control  
Platform policy references select the WebACL, while `HTTPRoute` hostnames define DNS names, enabling scaling across multi-cluster, multi-tenant, and multi-region environments.

Predictable deletion  
DynamoDB maintains itemised ALB state so cleanup is complete and consistent.

Compliance alignment  
The approach aligns naturally with PCI-DSS, DORA, and ISO 27001 by enforcing security controls uniformly and providing audit-ready evidence.

---

# Business Value

Secure by default  
Every ALB is protected instantly without developer intervention.

Reduced operational risk  
No dependency on manual steps removes misconfiguration risk.

Standardised ingress behaviour  
All workloads inherit the same security and resilience posture.

Improved resilience  
Route 53 health checks and consistent DNS patterns enhance failover strategy.

Traceability and audit readiness  
DynamoDB and CloudWatch provide a full lifecycle trail.

Preserves delivery velocity  
Teams continue using Ingress resources; security enforcement is transparent and automated.

---

# Closing Perspective

This architecture evolves Amazon EKS ingress from independently managed routing and security controls into a governed platform capability. Stage 0 responds to the ALB lifecycle through event-driven automation, Stage 1 moves supported responsibilities to Gateway API and purpose-built controllers, and Stage 2 optionally packages the same deterministic resource graph behind a platform-authored `SecureALB` API.

Across these stages, the principle remains unchanged: if an intended internet-facing ALB exists, its required protection must be consistently applied, verified, reconciled, and removed as part of the resource lifecycle. Application teams declare workload intent, while the platform owns the security-control attachments and cross-service assurance without requiring another deployment step.

That is the foundation of a mature cloud operating model: explicit ownership, deterministic enforcement, auditable lifecycle evidence, and a simple developer experience.

---

