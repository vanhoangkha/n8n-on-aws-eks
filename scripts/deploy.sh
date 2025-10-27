#!/bin/bash
set -e

CLUSTER_NAME="${CLUSTER_NAME:-n8n-cluster}"
REGION="${REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE:-default}"

echo "🚀 Creating new n8n cluster..."
echo "   Cluster: $CLUSTER_NAME"
echo "   Region: $REGION"
echo "   Profile: $AWS_PROFILE"
echo ""

# Validate AWS credentials
if ! aws sts get-caller-identity --profile $AWS_PROFILE &>/dev/null; then
  echo "❌ Error: AWS credentials not configured for profile '$AWS_PROFILE'"
  exit 1
fi

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
        imageBuilder: true
    volumeSize: 50
    volumeType: gp3
    volumeEncrypted: true

vpc:
  nat:
    gateway: Single  # Use NAT gateway for better reliability
  cidr: "10.0.0.0/16"

addons:
  - name: vpc-cni
    version: latest
  - name: coredns
    version: latest
  - name: kube-proxy
    version: latest
EOF

echo "📦 Creating EKS cluster (this may take 15-20 minutes)..."
eksctl create cluster --config-file=/tmp/cluster.yaml --profile $AWS_PROFILE || {
  echo "❌ Failed to create cluster"
  rm -f /tmp/cluster.yaml
  exit 1
}

echo "✅ Cluster created successfully!"

# Update kubeconfig
echo "🔧 Updating kubeconfig..."
aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME --profile $AWS_PROFILE || {
  echo "❌ Failed to update kubeconfig"
  exit 1
}

# Install EBS CSI driver
echo "💾 Installing EBS CSI driver..."
aws eks create-addon \
  --cluster-name $CLUSTER_NAME \
  --addon-name aws-ebs-csi-driver \
  --region $REGION \
  --profile $AWS_PROFILE \
  --service-account-role-arn arn:aws:iam::$(aws sts get-caller-identity --profile $AWS_PROFILE --query Account --output text):role/eksctl-${CLUSTER_NAME}-addon-iamservicea-Role1 || {
  echo "⚠️  EBS CSI driver addon might already exist or failed. Continuing..."
}

# Wait for addon to be ready
echo "⏳ Waiting for EBS CSI driver to be ready..."
sleep 30

# Create storage class if it doesn't exist
kubectl get storageclass gp3 &>/dev/null || {
  echo "📦 Creating gp3 storage class..."
  kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  fsType: ext4
volumeBindingMode: WaitForFirstConsumer
EOF
}

# Deploy n8n manifests in order
echo "📦 Deploying n8n manifests..."
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f manifests/01-postgres-secret.yaml
kubectl apply -f manifests/02-persistent-volumes.yaml
kubectl apply -f manifests/03-postgres-deployment.yaml
kubectl apply -f manifests/04-postgres-service.yaml
kubectl apply -f manifests/05-network-policy.yaml
kubectl apply -f manifests/06-n8n-deployment.yaml
kubectl apply -f manifests/07-n8n-service.yaml
kubectl apply -f manifests/08-hpa.yaml
kubectl apply -f manifests/09-ingress.yaml
kubectl apply -f manifests/10-backup-cronjob.yaml
kubectl apply -f manifests/11-restore-job.yaml

# Wait for PVCs to be bound
echo "⏳ Waiting for persistent volumes to be ready..."
kubectl wait --for=condition=Bound --timeout=300s pvc/postgres-pvc -n n8n || echo "⚠️  PVC binding may still be in progress"
kubectl wait --for=condition=Bound --timeout=300s pvc/n8n-pvc -n n8n || echo "⚠️  PVC binding may still be in progress"

# Wait for deployments
echo "⏳ Waiting for deployments to be ready..."
kubectl wait --for=condition=available --timeout=600s deployment/postgres-simple -n n8n || echo "⚠️  Postgres deployment still initializing"
kubectl wait --for=condition=available --timeout=600s deployment/n8n-simple -n n8n || echo "⚠️  n8n deployment still initializing"

echo ""
echo "✅ Deployment complete!"
echo ""
echo "📊 Current Status:"
kubectl get pods -n n8n
echo ""
echo "🌐 Services:"
kubectl get services -n n8n
echo ""
echo "💾 Storage:"
kubectl get pvc -n n8n
echo ""
echo "🔗 n8n URL:"
kubectl get service n8n-service-simple -n n8n -o jsonpath='http://{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null && echo "" || echo "LoadBalancer URL pending..."
echo ""
echo "📈 Monitor deployment:"
echo "   ./scripts/monitor.sh"
echo ""

# Cleanup temp file
rm -f /tmp/cluster.yaml
