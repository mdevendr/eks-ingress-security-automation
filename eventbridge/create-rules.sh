#!/bin/bash
aws events put-rule --name CreateALBRule --event-pattern '{"source":["aws.elasticloadbalancing"],"detail-type":["AWS API Call via CloudTrail"],"detail":{"eventSource":["elasticloadbalancing.amazonaws.com"],"eventName":["CreateLoadBalancer"]}}'
aws events put-targets --rule CreateALBRule --targets "Id"="1","Arn"="$1"
