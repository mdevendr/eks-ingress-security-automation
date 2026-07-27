apiVersion: v1
kind: ConfigMap
metadata:
  name: secure-alb-waf-policies
  namespace: secure-alb-system
data:
  regulated-public: __WEB_ACL_ARN__
  standard-public: __WEB_ACL_ARN__
  internal-api: __WEB_ACL_ARN__
