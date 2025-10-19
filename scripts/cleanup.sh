#!/bin/bash

CLUSTER_NAME="${CLUSTER_NAME:-n8n-cluster}"
REGION="${REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE:-devops}"

echo "Cleaning up n8n deployment..."
echo "Cluster: $CLUSTER_NAME | Region: $REGION"

# Delete n8n namespace first
kubectl delete namespace n8n --ignore-not-found=true

# Delete EKS cluster
echo "Deleting EKS cluster..."
AWS_PROFILE=$AWS_PROFILE eksctl delete cluster --region=$REGION --name=$CLUSTER_NAME --profile=$AWS_PROFILE

echo "Cleanup complete!"
