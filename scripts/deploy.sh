#!/bin/bash
set -e

CLUSTER_NAME="${CLUSTER_NAME:-n8n-cluster}"
REGION="${REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE:-devops}"

echo "Creating new n8n cluster..."
echo "Cluster: $CLUSTER_NAME | Region: $REGION"

# Create cluster config dynamically
cat > /tmp/cluster.yaml <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: $CLUSTER_NAME
  region: $REGION

nodeGroups:
  - name: n8n-workers
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 1
    maxSize: 4
    ssh:
      allow: false
    iam:
      withAddonPolicies:
        ebs: true
        cloudWatch: true

vpc:
  nat:
    gateway: Disable
EOF

# Create cluster
AWS_PROFILE=$AWS_PROFILE eksctl create cluster --config-file=/tmp/cluster.yaml --profile $AWS_PROFILE

# Update kubeconfig
aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME --profile $AWS_PROFILE

# Install EBS CSI driver
aws eks create-addon --cluster-name $CLUSTER_NAME --addon-name aws-ebs-csi-driver --region $REGION --profile $AWS_PROFILE

# Deploy n8n
kubectl apply -f manifests/

# Wait for deployments
kubectl wait --for=condition=available --timeout=300s deployment/postgres-simple -n n8n
kubectl wait --for=condition=available --timeout=300s deployment/n8n-simple -n n8n

echo "Deployment complete!"
kubectl get services -n n8n
kubectl get service n8n-service-simple -n n8n -o jsonpath='n8n URL: http://{.status.loadBalancer.ingress[0].hostname}' && echo

# Cleanup temp file
rm -f /tmp/cluster.yaml
