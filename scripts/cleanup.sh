#!/bin/bash
set -e

CLUSTER_NAME="${CLUSTER_NAME:-n8n-cluster}"
REGION="${REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE:-default}"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║         🗑️  n8n Cleanup Script                             ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "⚠️  WARNING: This will delete all resources!"
echo "   Cluster: $CLUSTER_NAME"
echo "   Region: $REGION"
echo "   Profile: $AWS_PROFILE"
echo ""
read -p "Are you sure you want to continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
  echo "❌ Cleanup cancelled."
  exit 0
fi

echo ""
echo "🗑️  Starting cleanup process..."
echo ""

# Check if cluster exists
if ! aws eks describe-cluster --region $REGION --name $CLUSTER_NAME --profile $AWS_PROFILE &>/dev/null; then
  echo "⚠️  Cluster '$CLUSTER_NAME' not found in region '$REGION'"
  echo "✅ Skipping cluster deletion (may already be deleted)"
else
  # Delete n8n namespace first to clean up PVCs
  echo "📦 Deleting n8n namespace and PVCs..."
  kubectl delete namespace n8n --ignore-not-found=true --timeout=60s || echo "⚠️  Namespace deletion timed out, continuing..."
  
  echo ""
  echo "⏳ Waiting for resources to be deleted..."
  sleep 15
  
  # Delete EKS cluster
  echo "🗑️  Deleting EKS cluster (this may take 10-15 minutes)..."
  eksctl delete cluster --region=$REGION --name=$CLUSTER_NAME --profile=$AWS_PROFILE --wait || {
    echo "⚠️  Cluster deletion in progress..."
  }
fi

# Clean up remaining resources
echo ""
echo "🧹 Cleaning up remaining resources..."
echo "   Checking for orphaned LoadBalancers..."
aws elbv2 describe-load-balancers --region $REGION --profile $AWS_PROFILE \
  --query 'LoadBalancers[?contains(LoadBalancerName, `n8n`)].LoadBalancerArn' \
  --output text | while read lb; do
  if [ ! -z "$lb" ]; then
    echo "   Deleting LoadBalancer: $lb"
    aws elbv2 delete-load-balancer --load-balancer-arn "$lb" --region $REGION --profile $AWS_PROFILE
  fi
done

echo ""
echo "✅ Cleanup complete!"
echo ""
echo "📋 Verify cleanup:"
echo "   kubectl get namespace n8n"
echo "   aws eks list-clusters --region $REGION"
echo ""
