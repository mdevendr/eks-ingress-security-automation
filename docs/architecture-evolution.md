# Architecture evolution and version timeline

This document is the repository source of truth for the article's evolution narrative. It records when relevant platform capabilities became available, which architectural gap they addressed, and where that change appears in the repository.

The dates below describe platform availability. They do not claim that every production environment adopted the feature on its release date.

## Timeline

| Date or era | Platform milestone | Architectural consequence | Repository stage |
|---|---|---|---|
| Before Amazon EKS 1.30 | ALBs were commonly exposed through Kubernetes `Ingress` and AWS Load Balancer Controller annotations. Native `ValidatingAdmissionPolicy` was not yet a stable EKS API. Security depended on approved manifests, RBAC, controller configuration, IAM and post-provisioning automation. | Establishes the original annotation-driven model and proves its CloudTrail, EventBridge, Lambda and DynamoDB lifecycle path. Stage 0 intentionally has no `ValidatingAdmissionPolicy` or evolved controller dependencies. | `stages/00-ingress` |
| 19 April 2022 | AWS announced general availability of the first group of AWS Controllers for Kubernetes (ACK) service controllers. | AWS resources could increasingly be represented and reconciled through Kubernetes custom resources instead of bespoke create/delete code. | Architectural precursor to the ACK health check used in Stages 1 and 2. |
| Kubernetes 1.26, December 2022 | `ValidatingAdmissionPolicy` first appeared as an alpha feature. | It was not an appropriate portable production dependency for the original Stage 0 implementation. | Timeline context only. |
| Kubernetes 1.30, 17 April 2024 | `ValidatingAdmissionPolicy` graduated to generally available. | CEL-based admission enforcement became a stable native alternative to a separate validating webhook for these controls. | Used from Stage 1 onward. |
| Amazon EKS 1.30, 23 May 2024 | Amazon EKS made Kubernetes 1.30 available. | EKS users could rely on the stable admission-policy API. This is the version boundary between the historical Stage 0 model and the later enforcement model in this repository. | `shared/kubernetes/admission-policy.yaml` applied by Stages 1 and 2. |
| Current deterministic Gateway API option | AWS Load Balancer Controller Gateway API support, ExternalDNS Gateway API sources and ACK allow the ALB, routes, DNS intent and Route 53 health check to be expressed as controller-reconciled resources. | Replaces annotation-heavy Ingress intent with explicit `Gateway`, `HTTPRoute`, `LoadBalancerConfiguration` and `TargetGroupConfiguration` resources. A narrow Lambda remains for the cross-service Shield health-check association and lifecycle inventory. This is a complete current architecture without kro. | `stages/01-gateway-api` |
| Optional current platform-abstraction option | kro can compose Kubernetes and ACK resources behind a platform-authored custom API. Amazon EKS Capabilities can operate ACK and kro as managed cluster capabilities. | Application teams submit `SecureALB`; the platform owns the resource graph, WAF policy catalogue and security defaults. Admission enforcement remains independent of kro. This is an optional abstraction over Stage 1, not a mandatory successor to it. | `stages/02-kro` |

## Technical responsibility by stage

The stages change how intent is declared and which controller owns each reconciliation step. They do not change the requirement for deterministic enforcement.

| Responsibility | Stage 0: Ingress EDA | Stage 1: Gateway API | Stage 2: Optional kro abstraction |
|---|---|---|---|
| Application-facing API | Kubernetes `Ingress` plus annotations | `Gateway` and `HTTPRoute`, with AWS-specific configuration resources | Platform-authored `SecureALB` custom resource |
| ALB, listener and target groups | AWS Load Balancer Controller reconciles `Ingress` | AWS Load Balancer Controller reconciles `Gateway`, `HTTPRoute`, `LoadBalancerConfiguration` and `TargetGroupConfiguration` | kro creates the Stage 1 Kubernetes resource graph; AWS Load Balancer Controller performs the same AWS reconciliation |
| AWS WAF association | Lifecycle Lambda associates the WebACL after discovering the ALB ARN | AWS Load Balancer Controller reads `LoadBalancerConfiguration.spec.wafV2.webACL` and associates the WebACL | kro resolves the logical WAF policy into `LoadBalancerConfiguration`; AWS Load Balancer Controller performs the association |
| Shield Advanced protection | Lifecycle Lambda creates and deletes the protection | AWS Load Balancer Controller reads `LoadBalancerConfiguration.spec.shieldConfiguration.enabled` and owns the protection lifecycle | kro sets the same `LoadBalancerConfiguration` field; AWS Load Balancer Controller owns the protection lifecycle |
| Route 53 alias | Lifecycle Lambda creates and deletes the alias in the original model | ExternalDNS watches Gateway API route sources and manages the alias from the declared hostname and load-balancer status | Same as Stage 1; kro does not manage Route 53 directly |
| Route 53 health check | Lifecycle Lambda creates and deletes the health check | The deployment creates an ACK `HealthCheck` custom resource; the ACK Route 53 controller watches that CR and invokes the Route 53 API | kro creates the ACK `HealthCheck` CR as part of the graph; the ACK Route 53 controller performs the AWS reconciliation |
| Shield health-check association | Lifecycle Lambda discovers both resources and calls the Shield association API | Narrow lifecycle Lambda correlates the ACK-created health check with the controller-created Shield protection | Same narrow lifecycle Lambda as Stage 1 |
| Lifecycle inventory | Lambda writes ALB and dependent-resource state to DynamoDB | Lambda records cross-controller resource correlation in DynamoDB | Lambda remains the DynamoDB writer; kro does not write per-ALB inventory |
| Drift recovery | Event retry and scheduled reconciliation | Kubernetes controllers reconcile their owned resources; scheduled reconciliation covers the remaining cross-service association | Same as Stage 1 |
| Admission enforcement | Approved manifests, RBAC, controller configuration and IAM; no stable native `ValidatingAdmissionPolicy` dependency | Native CEL `ValidatingAdmissionPolicy`, RBAC and IAM | The same admission policy remains independent of kro, so kro is not the security boundary |

### Stage 0 technical boundary

The `Ingress` object is the application declaration. The AWS Load Balancer Controller creates the ALB asynchronously, so the ALB ARN does not exist when the manifest is submitted. CloudTrail records the resulting `CreateLoadBalancer` or `DeleteLoadBalancer` API event, EventBridge invokes the lifecycle Lambda, and the Lambda uses ALB tags to decide whether the resource is in scope. DynamoDB preserves the identifiers needed to reverse the dependent-resource lifecycle during deletion.

### Stage 1 technical boundary

The application or platform deploys the following explicit resources:

- `TargetGroupConfiguration` defines target registration and health behaviour.
- `LoadBalancerConfiguration` defines ALB-level settings, including the WebACL reference and Shield configuration.
- `Gateway.spec.infrastructure.parametersRef` connects the Gateway to its `LoadBalancerConfiguration`.
- `HTTPRoute` binds the hostname and routing rules to the Gateway and backend `Service`.
- The ACK `HealthCheck` CR independently declares the Route 53 health check endpoint.

These resources are submitted together but converge independently. The ACK Route 53 controller does not watch `HTTPRoute`, discover the ALB or derive the health-check endpoint from Gateway status. The deployment supplies the same hostname to both declarations. The health check can therefore exist before the ALB and DNS alias are ready and become healthy after the other controllers converge.

The remaining Lambda is intentionally narrow: it discovers the ALB, the Shield protection and the ACK-created health check, associates or disassociates the health check with Shield, and stores their lifecycle correlation. It does not create the ALB, associate the WebACL, create Shield protection, create the Route 53 alias or create the Route 53 health check.

### Stage 2 technical boundary

The platform deploys a kro `ResourceGraphDefinition` that registers the `SecureALB` custom API. An application team then submits a `SecureALB` instance rather than authoring each Stage 1 resource directly. kro evaluates the schema and creates the `TargetGroupConfiguration`, `LoadBalancerConfiguration`, `Gateway`, `HTTPRoute` and ACK `HealthCheck` resources in the graph.

A platform-controlled WAF policy catalogue converts the logical `wafPolicyRef` supplied by the application into the approved WebACL ARN used by `LoadBalancerConfiguration`. Application RBAC permits teams to create `SecureALB` resources while restricting direct modification of the generated infrastructure resources.

kro performs Kubernetes resource composition only. The AWS Load Balancer Controller, ExternalDNS and ACK controller retain the same AWS reconciliation responsibilities as Stage 1, and the lifecycle Lambda retains the cross-service Shield health-check association and DynamoDB inventory responsibilities. Organisations that do not need a platform-authored abstraction can remain on Stage 1 without losing the current deterministic security model.

## Stage-to-stage change record

### Stage 0 to Stage 1

- Replace `Ingress` annotations with Gateway API resources.
- Introduce stable native `ValidatingAdmissionPolicy` enforcement, requiring EKS/Kubernetes 1.30 or later.
- Add WAF, TLS, access logging and platform admission prerequisites to the deterministic baseline.
- Move DNS ownership to ExternalDNS's route source.
- Represent the Route 53 health check as an ACK resource.
- Retain event-driven inventory and reconciliation for cross-controller lifecycle gaps.

### Stage 1 to Stage 2

- Preserve the same resulting AWS controls and Kubernetes resource graph.
- Replace direct application authorship with the `SecureALB` custom API.
- Resolve logical `wafPolicyRef` values through a platform-controlled catalogue.
- Use kro for composition, not as the security boundary or as a writer of per-ALB DynamoDB state.

## Article rules

1. Describe Stage 0 using only capabilities available to the original pre-EKS-1.30 implementation.
2. Introduce `ValidatingAdmissionPolicy` at the EKS 1.30 boundary, not retrospectively in Stage 0.
3. Separate the date a platform feature became available from the date an organization adopted it.
4. Do not attribute DNS record management to the Lambda; ExternalDNS owns it in the evolved design.
5. Do not attribute per-instance DynamoDB writes to kro; the lifecycle Lambda owns them.
6. Add every future stage-boundary change to this file with an authoritative source.

## Authoritative references

- [Kubernetes 1.26: first alpha release of Validating Admission Policies](https://kubernetes.io/blog/2022/12/20/validating-admission-policies-alpha/)
- [Kubernetes 1.30: Validating Admission Policy generally available](https://kubernetes.io/blog/2024/04/24/validating-admission-policy-ga/)
- [Amazon EKS Kubernetes release calendar](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html)
- [Amazon EKS 1.30 availability announcement](https://aws.amazon.com/about-aws/whats-new/2024/05/amazon-eks-distro-kubernetes-version-1-30/)
- [ACK controllers initial general-availability announcement](https://aws.amazon.com/about-aws/whats-new/2022/04/amazon-ack-ecr-dynamodb-s3-aws-application-api-gateway-available/)
- [Amazon EKS Capabilities](https://docs.aws.amazon.com/eks/latest/userguide/capabilities.html)
- [ExternalDNS Gateway API route sources](https://kubernetes-sigs.github.io/external-dns/latest/docs/sources/gateway-api/)
- [AWS Load Balancer Controller Gateway API documentation](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/gateway/gateway/)
