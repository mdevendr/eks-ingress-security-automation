apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo
  namespace: secure-alb-demo
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}]'
    alb.ingress.kubernetes.io/load-balancer-attributes: deletion_protection.enabled=false,routing.http.drop_invalid_header_fields.enabled=true
    alb.ingress.kubernetes.io/tags: secure-alb/id=secure-alb-demo/demo,secure-alb/stage=ingress-eda
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: demo
                port:
                  number: 80
