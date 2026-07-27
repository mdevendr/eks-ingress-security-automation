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
| Current deterministic platform model | AWS Load Balancer Controller Gateway API support, ExternalDNS Gateway API sources and ACK allow the ALB, routes, DNS intent and Route 53 health check to be expressed as controller-reconciled resources. | Replaces annotation-heavy Ingress intent with explicit `Gateway`, `HTTPRoute`, `LoadBalancerConfiguration` and `TargetGroupConfiguration` resources. A narrow Lambda remains for the cross-service Shield health-check association and lifecycle inventory. | `stages/01-gateway-api` |
| Current platform-abstraction model | kro can compose Kubernetes and ACK resources behind a platform-authored custom API. Amazon EKS Capabilities can operate ACK and kro as managed cluster capabilities. | Application teams submit `SecureALB`; the platform owns the resource graph, WAF policy catalogue and security defaults. Admission enforcement remains independent of kro. | `stages/02-kro` |
| Next operational layer | Generative AI can assist with diagnosis, correlation and remediation planning, but attack telemetry contains attacker-controlled data. | Normalize untrusted input, keep the model advisory first, validate all output, and expose only deterministic bounded tools behind policy and approval. | `stages/03-ai-operations` |

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

### Stage 2 to Stage 3

- Keep deterministic controllers and reconciliation as the execution layer.
- Add normalized findings and advisory reasoning above that layer.
- Treat WAF and Shield traffic fields as untrusted data, never as model instructions.
- Require schema validation, policy checks and approval before any operational action.

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
