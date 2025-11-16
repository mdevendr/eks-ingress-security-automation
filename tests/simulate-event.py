import json, boto3, sys

events = boto3.client('events')
filename = sys.argv[1]

with open(filename) as f:
    event = json.load(f)

events.put_events(Entries=[{
    "Source": "aws.elasticloadbalancing",
    "DetailType": "AWS API Call via CloudTrail",
    "Detail": json.dumps(event["detail"])
}])

print("Event sent:", filename)
