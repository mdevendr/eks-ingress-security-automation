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
    secure-alb/web-acl-arn: __WEB_ACL_ARN__
    secure-alb/stage: gateway-api-http-evidence
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
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: demo
  namespace: secure-alb-demo
spec:
  parentRefs:
    - name: demo
      sectionName: http
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: demo
          port: 80
