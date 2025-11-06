#!/bin/bash
# Deploy n8n on AWS EKS
# Usage: ./deploy.sh [options]
#   CLUSTER_NAME: Name of the EKS cluster (default: n8n-cluster)
#   REGION: AWS region (default: us-east-1)
#   AWS_PROFILE: AWS CLI profile (default: default)

set -euo pipefail

# Get script directory for sourcing common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-n8n-cluster}"
REGION="${REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE:-default}"

# Display help message
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    show_usage "$(basename "$0")" "[CLUSTER_NAME=name] [REGION=region] [AWS_PROFILE=profile]"
    echo "Options:"
    echo "  CLUSTER_NAME    Name of the EKS cluster (default: n8n-cluster)"
    echo "  REGION          AWS region (default: us-east-1)"
    echo "  AWS_PROFILE     AWS CLI profile (default: default)"
    echo ""
    echo "Examples:"
    echo "  ./deploy.sh"
    echo "  REGION=us-west-2 ./deploy.sh"
    echo "  CLUSTER_NAME=prod-n8n REGION=eu-west-1 AWS_PROFILE=production ./deploy.sh"
    exit 0
fi

print_header "🚀 n8n EKS Deployment"

log_info "Configuration:"
echo "   Cluster: $CLUSTER_NAME"
echo "   Region: $REGION"
echo "   Profile: $AWS_PROFILE"
echo ""

# Check prerequisites
log_info "Checking prerequisites..."
check_prerequisites aws kubectl eksctl || error_exit "Prerequisites check failed"
log_success "All required commands are available"

# Validate AWS credentials
log_info "Validating AWS credentials..."
validate_aws_credentials "$AWS_PROFILE" || error_exit "AWS credentials validation failed"
log_success "AWS credentials validated"

# Validate AWS region
log_info "Validating AWS region..."
validate_aws_region "$REGION" || error_exit "AWS region validation failed"
log_success "AWS region validated"

# Check if cluster already exists
if check_cluster_exists "$CLUSTER_NAME" "$REGION" "$AWS_PROFILE"; then
    error_exit "Cluster '$CLUSTER_NAME' already exists in region '$REGION'. Please use a different name or delete the existing cluster."
fi

# Validate manifest files exist
log_info "Validating manifest files..."
MANIFEST_DIR="${SCRIPT_DIR}/../manifests"
if [ ! -d "$MANIFEST_DIR" ]; then
    error_exit "Manifests directory not found: $MANIFEST_DIR"
fi
log_success "Manifest directory found"

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

log_info "Creating EKS cluster (this may take 15-20 minutes)..."
if ! eksctl create cluster --config-file=/tmp/cluster.yaml --profile "$AWS_PROFILE"; then
    rm -f /tmp/cluster.yaml
    error_exit "Failed to create EKS cluster"
fi

log_success "Cluster created successfully!"

# Update kubeconfig
log_info "Updating kubeconfig..."
if ! aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" --profile "$AWS_PROFILE"; then
    error_exit "Failed to update kubeconfig"
fi
log_success "Kubeconfig updated"

# Install EBS CSI driver
log_info "Installing EBS CSI driver addon..."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text)

if ! aws eks create-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name aws-ebs-csi-driver \
    --region "$REGION" \
    --profile "$AWS_PROFILE" 2>/dev/null; then
    log_warning "EBS CSI driver addon might already exist or failed. Continuing..."
else
    log_success "EBS CSI driver addon created"
fi

# Wait for addon to be ready
log_info "Waiting for EBS CSI driver to be ready..."
sleep 30

# Create storage class if it doesn't exist
if ! kubectl get storageclass gp3 &>/dev/null; then
    log_info "Creating gp3 storage class..."
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
    log_success "Storage class created"
else
    log_info "Storage class gp3 already exists"
fi

# Deploy n8n manifests in order
log_info "Deploying n8n manifests..."

# Define manifest files in deployment order
MANIFEST_FILES=(
    "00-namespace.yaml"
    "01-postgres-secret.yaml"
    "02-persistent-volumes.yaml"
    "03-postgres-deployment.yaml"
    "04-postgres-service.yaml"
    "05-network-policy.yaml"
    "06-n8n-deployment.yaml"
    "07-n8n-service.yaml"
    "08-hpa.yaml"
    "09-ingress.yaml"
    "10-backup-cronjob.yaml"
    "11-restore-job.yaml"
)

for manifest in "${MANIFEST_FILES[@]}"; do
    manifest_path="${MANIFEST_DIR}/${manifest}"
    if [ -f "$manifest_path" ]; then
        log_info "Applying $manifest..."
        kubectl apply -f "$manifest_path" || log_warning "Failed to apply $manifest, continuing..."
    else
        log_warning "Manifest not found: $manifest (skipping)"
    fi
done

log_success "Manifests deployed"

# Wait for PVCs to be bound
log_info "Waiting for persistent volumes to be ready..."
if ! kubectl wait --for=condition=Bound --timeout=300s pvc/postgres-pvc -n n8n 2>/dev/null; then
    log_warning "PostgreSQL PVC binding may still be in progress"
fi
if ! kubectl wait --for=condition=Bound --timeout=300s pvc/n8n-pvc -n n8n 2>/dev/null; then
    log_warning "n8n PVC binding may still be in progress"
fi

# Wait for deployments
log_info "Waiting for deployments to be ready (this may take several minutes)..."
if ! kubectl wait --for=condition=available --timeout=600s deployment/postgres-simple -n n8n 2>/dev/null; then
    log_warning "PostgreSQL deployment still initializing"
fi
if ! kubectl wait --for=condition=available --timeout=600s deployment/n8n-simple -n n8n 2>/dev/null; then
    log_warning "n8n deployment still initializing"
fi

echo ""
log_success "Deployment complete!"
echo ""

log_info "Current Status:"
print_separator
kubectl get pods -n n8n
echo ""

log_info "Services:"
print_separator
kubectl get services -n n8n
echo ""

log_info "Storage:"
print_separator
kubectl get pvc -n n8n
echo ""

log_info "n8n Access URL:"
print_separator
N8N_URL=$(kubectl get service n8n-service-simple -n n8n -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [ -n "$N8N_URL" ]; then
    echo "   http://${N8N_URL}"
else
    echo "   LoadBalancer URL is pending, please wait a few minutes..."
fi
echo ""

log_info "Next Steps:"
print_separator
echo "   1. Monitor deployment: ./scripts/monitor.sh"
echo "   2. View logs: ./scripts/get-logs.sh"
echo "   3. Create backup: ./scripts/backup.sh"
echo ""

# Cleanup temp file
rm -f /tmp/cluster.yaml

log_success "Setup completed successfully!"
