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

Linkedin Post : https://www.linkedin.com/posts/mahesh-devendran-83a3b214_aws-eks-cloudarchitecture-activity-7395776029266550784-3Y7d

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
<img width="3807" height="1755" alt="ShieldAdvance" src="https://github.com/user-attachments/assets/36b8ce9b-bcec-432c-bc24-38401b3df165" />

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
- Creates or updates corresponding DNS alias records
- Stores all ALB metadata in DynamoDB for reliable cleanup

When the ALB is deleted, the automation reverses the workflow:

- Removes it from Shield Advanced
- Deletes associated health checks
- Cleans up DNS records as appropriate
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
ALB tags define WebACL, hosted zone, and DNS names, enabling scaling across multi-cluster, multi-tenant, and multi-region environments.

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

This design upgrades Amazon EKS ingress from an ad-hoc implementation to a governed, secure, enterprise-grade ingress platform. It ensures security is consistent, automated, and invisible to the developer experience — the hallmark of a mature cloud operating model.

---

