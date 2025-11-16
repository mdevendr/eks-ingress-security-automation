aws elbv2 create-load-balancer \
  --name test-ingress-alb \
  --type application \
  --scheme internet-facing \
  --subnets subnet-xxx subnet-yyy \
  --security-groups sg-xxx \
  --tags Key=record-name,Value=service.example.com \
         Key=hosted-zone-id,Value=<enter hosted zone id here>
