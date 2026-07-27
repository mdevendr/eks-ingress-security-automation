apiVersion: platform.eks.example/v1alpha1
kind: SecureALB
metadata:
  name: demo
  namespace: secure-alb-demo
spec:
  hostname: __HOSTNAME__
  serviceName: demo
  servicePort: 80
  wafPolicyRef: regulated-public
  certificateArn: __CERTIFICATE_ARN__
  accessLogBucket: __ACCESS_LOG_BUCKET__
