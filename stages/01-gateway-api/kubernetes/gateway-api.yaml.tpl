apiVersion: gateway.k8s.aws/v1
kind: TargetGroupConfiguration
metadata:
  name: demo-targets
  namespace: secure-alb-demo
spec:
  defaultConfiguration:
    targetType: ip
    protocol: HTTP
    protocolVersion: HTTP1
    healthCheckConfig:
      healthCheckInterval: 15
      healthCheckPath: /health
      healthCheckPort: traffic-port
      healthCheckProtocol: HTTP
      healthyThresholdCount: 2
      unhealthyThresholdCount: 2
      matcher:
        httpCode: "200"
---
apiVersion: gateway.k8s.aws/v1
kind: LoadBalancerConfiguration
metadata:
  name: demo-alb
  namespace: secure-alb-demo
spec:
  scheme: internet-facing
  ipAddressType: ipv4
  defaultTargetGroupConfiguration:
    name: demo-targets
  listenerConfigurations:
    - protocolPort: HTTPS:443
      defaultCertificate: __CERTIFICATE_ARN__
      sslPolicy: ELBSecurityPolicy-TLS13-1-2-2021-06
  wafV2:
    webACL: __WEB_ACL_ARN__
  shieldConfiguration:
    enabled: false
  loadBalancerAttributes:
    - key: deletion_protection.enabled
      value: "false"
    - key: routing.http.drop_invalid_header_fields.enabled
      value: "true"
    - key: access_logs.s3.enabled
      value: "true"
    - key: access_logs.s3.bucket
      value: __ACCESS_LOG_BUCKET__
    - key: access_logs.s3.prefix
      value: secure-alb/stage-1
  tags:
    secure-alb/id: secure-alb-demo/demo
    secure-alb/hostname: __HOSTNAME__
    secure-alb/web-acl-arn: __WEB_ACL_ARN__
    secure-alb/stage: gateway-api
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: demo
  namespace: secure-alb-demo
spec:
  gatewayClassName: aws-alb-secure
  infrastructure:
    parametersRef:
      group: gateway.k8s.aws
      kind: LoadBalancerConfiguration
      name: demo-alb
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: __HOSTNAME__
      allowedRoutes:
        namespaces:
          from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: demo
  namespace: secure-alb-demo
  annotations:
    external-dns.alpha.kubernetes.io/ttl: "60"
spec:
  parentRefs:
    - name: demo
      sectionName: https
  hostnames:
    - __HOSTNAME__
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: demo
          port: 80
---
apiVersion: route53.services.k8s.aws/v1alpha1
kind: HealthCheck
metadata:
  name: demo
  namespace: secure-alb-demo
spec:
  callerReference: stage-1-__RUN_ID__
  healthCheckConfig:
    type: HTTPS
    fullyQualifiedDomainName: __HOSTNAME__
    port: 443
    resourcePath: /health
    requestInterval: 30
    failureThreshold: 3
  tags:
    - key: secure-alb/id
      value: secure-alb-demo/demo
