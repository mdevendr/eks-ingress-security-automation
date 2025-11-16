aws dynamodb create-table \
  --table-name AlbStateTable \
  --attribute-definitions AttributeName=ALBArn,AttributeType=S \
  --key-schema AttributeName=ALBArn,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
