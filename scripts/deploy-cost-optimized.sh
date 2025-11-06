#!/bin/bash
# Deploy cost-optimized n8n on AWS EKS with spot instances
# Usage: ./deploy-cost-optimized.sh [options]
# WARNING: Uses spot instances and minimal resources - suitable for development/testing only

set -euo pipefail

# Get script directory for sourcing common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

# Configuration
REGION="${REGION:-ap-southeast-1}"
CLUSTER_NAME="${CLUSTER_NAME:-n8n-cluster}"
AWS_PROFILE="${AWS_PROFILE:-default}"

# Display help message
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    show_usage "$(basename "$0")" "[CLUSTER_NAME=name] [REGION=region] [AWS_PROFILE=profile]"
    echo "Options:"
    echo "  CLUSTER_NAME    Name of the EKS cluster (default: n8n-cluster)"
    echo "  REGION          AWS region (default: ap-southeast-1)"
    echo "  AWS_PROFILE     AWS CLI profile (default: default)"
    echo ""
    echo "Examples:"
    echo "  ./deploy-cost-optimized.sh"
    echo "  REGION=us-east-1 ./deploy-cost-optimized.sh"
    echo ""
    echo "Note: This deployment uses spot instances and minimal resources."
    echo "      It is suitable for development/testing only, not production."
    exit 0
fi

print_header "🚀 Cost-Optimized n8n EKS Deployment"

log_warning "This deployment uses spot instances and minimal resources"
log_warning "Suitable for development/testing only, NOT for production use"
echo ""

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

# Check if cost-optimized cluster config exists
CLUSTER_CONFIG="${SCRIPT_DIR}/../infrastructure/cost-optimized-cluster.yaml"
if [ ! -f "$CLUSTER_CONFIG" ]; then
    log_warning "Cost-optimized cluster config not found: $CLUSTER_CONFIG"
    log_info "Creating default cost-optimized configuration..."

    # Create infrastructure directory if it doesn't exist
    mkdir -p "$(dirname "$CLUSTER_CONFIG")"

    # Create cost-optimized cluster configuration
    cat > "$CLUSTER_CONFIG" <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: $CLUSTER_NAME
  region: $REGION

nodeGroups:
  - name: n8n-spot-workers
    instanceType: t3.small
    desiredCapacity: 1
    minSize: 1
    maxSize: 2
    spot: true
    ssh:
      allow: false
    iam:
      withAddonPolicies:
        ebs: true
        cloudWatch: true
    volumeSize: 20
    volumeType: gp3
    volumeEncrypted: true

vpc:
  nat:
    gateway: Single
  cidr: "10.0.0.0/16"
EOF
    log_success "Created cost-optimized cluster configuration"
fi

# Create cluster with spot instances
log_info "Creating EKS cluster with spot instances (this may take 15-20 minutes)..."
if ! eksctl create cluster -f "$CLUSTER_CONFIG" --profile="$AWS_PROFILE"; then
    error_exit "Failed to create EKS cluster"
fi

log_success "Cluster created successfully!"

# Update kubeconfig
log_info "Updating kubeconfig..."
if ! aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" --profile "$AWS_PROFILE"; then
    error_exit "Failed to update kubeconfig"
fi
log_success "Kubeconfig updated"

# Deploy n8n manifests
log_info "Deploying n8n with minimal resources..."

MANIFEST_DIR="${SCRIPT_DIR}/../manifests"

# Deploy namespace and secret
log_info "Applying namespace and secrets..."
kubectl apply -f "${MANIFEST_DIR}/00-namespace.yaml" || error_exit "Failed to apply namespace"
kubectl apply -f "${MANIFEST_DIR}/01-postgres-secret.yaml" || error_exit "Failed to apply postgres secret"

# Deploy PostgreSQL with minimal resources (use emptyDir instead of PVC for cost savings)
log_info "Deploying PostgreSQL with minimal resources..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-simple
  namespace: n8n
  labels:
    app: postgres-simple
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres-simple
  template:
    metadata:
      labels:
        app: postgres-simple
    spec:
      containers:
      - name: postgres
        image: postgres:15-alpine
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 256Mi
        envFrom:
        - secretRef:
            name: postgres-secret
        volumeMounts:
        - name: postgres-storage
          mountPath: /var/lib/postgresql/data
          subPath: postgres
      volumes:
      - name: postgres-storage
        emptyDir: {}
EOF

if [ $? -ne 0 ]; then
    error_exit "Failed to deploy PostgreSQL"
fi
log_success "PostgreSQL deployment created"

# Deploy PostgreSQL service
log_info "Deploying PostgreSQL service..."
kubectl apply -f "${MANIFEST_DIR}/04-postgres-service.yaml" || error_exit "Failed to apply postgres service"

# Wait for PostgreSQL to be ready
log_info "Waiting for PostgreSQL to be ready..."
if ! kubectl wait --for=condition=available --timeout=300s deployment/postgres-simple -n n8n 2>/dev/null; then
    log_warning "PostgreSQL deployment still initializing"
fi

# Deploy n8n with minimal resources
log_info "Deploying n8n with minimal resources..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: n8n-simple
  namespace: n8n
  labels:
    app: n8n-simple
spec:
  replicas: 1
  selector:
    matchLabels:
      app: n8n-simple
  template:
    metadata:
      labels:
        app: n8n-simple
    spec:
      containers:
      - name: n8n
        image: n8nio/n8n:latest
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
        env:
        - name: N8N_SECURE_COOKIE
          value: "false"
        - name: N8N_PROTOCOL
          value: http
        - name: N8N_PORT
          value: "5678"
        - name: N8N_METRICS
          value: "true"
        - name: DB_TYPE
          value: postgresdb
        - name: DB_POSTGRESDB_HOST
          value: postgres-service-simple.n8n.svc.cluster.local
        - name: DB_POSTGRESDB_DATABASE
          valueFrom:
            secretKeyRef:
              name: postgres-secret
              key: POSTGRES_DB
        - name: DB_POSTGRESDB_USER
          valueFrom:
            secretKeyRef:
              name: postgres-secret
              key: POSTGRES_USER
        - name: DB_POSTGRESDB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-secret
              key: POSTGRES_PASSWORD
        ports:
        - containerPort: 5678
          name: http
        volumeMounts:
        - name: n8n-storage
          mountPath: /home/node/.n8n
      volumes:
      - name: n8n-storage
        emptyDir: {}
EOF

if [ $? -ne 0 ]; then
    error_exit "Failed to deploy n8n"
fi
log_success "n8n deployment created"

# Deploy n8n service
log_info "Deploying n8n service..."
kubectl apply -f "${MANIFEST_DIR}/07-n8n-service.yaml" || error_exit "Failed to apply n8n service"

# Wait for n8n to be ready
log_info "Waiting for n8n to be ready..."
if ! kubectl wait --for=condition=available --timeout=600s deployment/n8n-simple -n n8n 2>/dev/null; then
    log_warning "n8n deployment still initializing"
fi

echo ""
log_success "Ultra cost-optimized deployment complete!"
echo ""

log_info "Deployment Summary:"
print_separator
echo "   Instance Type: t3.small (spot)"
echo "   Resource Profile: Minimal (suitable for dev/test)"
echo "   Storage: emptyDir (non-persistent, for cost savings)"
echo "   Estimated Cost: ~$100-110/month"
echo ""

log_warning "Important Notes:"
print_separator
echo "   1. This uses spot instances which can be terminated"
echo "   2. Data is stored in emptyDir (non-persistent)"
echo "   3. NOT suitable for production workloads"
echo "   4. Regular backups are recommended"
echo ""

log_info "Next Steps:"
print_separator
echo "   1. Get access URL: kubectl get service n8n-service-simple -n n8n"
echo "   2. Monitor: ./scripts/monitor.sh"
echo "   3. View logs: ./scripts/get-logs.sh"
echo ""
