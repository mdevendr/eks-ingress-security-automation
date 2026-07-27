#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../../scripts/lib.sh"
load_config "${1:-}"
kubectl delete httproutes.gateway.networking.k8s.io demo -n secure-alb-demo --ignore-not-found
kubectl delete gateways.gateway.networking.k8s.io demo -n secure-alb-demo --ignore-not-found --wait=true --timeout=15m
kubectl delete healthchecks.route53.services.k8s.aws demo -n secure-alb-demo --ignore-not-found
kubectl delete loadbalancerconfigurations.gateway.k8s.aws demo-alb -n secure-alb-demo --ignore-not-found
kubectl delete targetgroupconfigurations.gateway.k8s.aws demo-targets -n secure-alb-demo --ignore-not-found
