apiVersion: platform.eks.example/v1alpha1
kind: SecureALB
metadata:
  name: demo
  namespace: secure-alb-demo
spec:
  serviceName: demo
  servicePort: 80
  wafPolicyRef: regulated-public
  accessLogBucket: __ACCESS_LOG_BUCKET__
