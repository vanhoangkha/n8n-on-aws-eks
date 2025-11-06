#!/bin/bash
# Cleanup script for n8n EKS deployment
# Usage: ./cleanup.sh [options]

set -euo pipefail

# Get script directory for sourcing common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-n8n-cluster}"
REGION="${REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE:-default}"
NAMESPACE_ONLY=false
SKIP_CONFIRMATION=false

# Display help message
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    show_usage "$(basename "$0")" "[options]"
    echo "Options:"
    echo "  --namespace-only    Only delete the n8n namespace (keep cluster)"
    echo "  --yes               Skip confirmation prompt (dangerous!)"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  CLUSTER_NAME        Name of the EKS cluster (default: n8n-cluster)"
    echo "  REGION              AWS region (default: us-east-1)"
    echo "  AWS_PROFILE         AWS CLI profile (default: default)"
    echo ""
    echo "Examples:"
    echo "  ./cleanup.sh"
    echo "  ./cleanup.sh --namespace-only"
    echo "  CLUSTER_NAME=my-cluster REGION=us-west-2 ./cleanup.sh"
    exit 0
fi

# Parse options
while [ $# -gt 0 ]; do
    case "$1" in
        --namespace-only)
            NAMESPACE_ONLY=true
            ;;
        --yes)
            SKIP_CONFIRMATION=true
            ;;
        *)
            log_warning "Unknown option: $1"
            ;;
    esac
    shift
done

print_header "🗑️  n8n Cleanup Script"

log_warning "WARNING: This will delete resources!"
echo "   Cluster: $CLUSTER_NAME"
echo "   Region: $REGION"
echo "   Profile: $AWS_PROFILE"
if [ "$NAMESPACE_ONLY" = true ]; then
    echo "   Mode: Namespace only (cluster will be preserved)"
else
    echo "   Mode: Full cleanup (cluster and all resources)"
fi
echo ""

# Confirm with user
if [ "$SKIP_CONFIRMATION" = false ]; then
    if ! confirm_action "Are you sure you want to continue?"; then
        log_info "Cleanup cancelled by user"
        exit 0
    fi
fi

echo ""

# Check prerequisites
log_info "Checking prerequisites..."
check_prerequisites kubectl aws || error_exit "Prerequisites check failed"

# Validate AWS credentials
log_info "Validating AWS credentials..."
validate_aws_credentials "$AWS_PROFILE" || error_exit "AWS credentials validation failed"

log_info "Starting cleanup process..."
echo ""

# Check if namespace exists
NAMESPACE_EXISTS=false
if check_namespace "n8n"; then
    NAMESPACE_EXISTS=true
fi

# Check if cluster exists
CLUSTER_EXISTS=false
if check_cluster_exists "$CLUSTER_NAME" "$REGION" "$AWS_PROFILE"; then
    CLUSTER_EXISTS=true
fi

# Handle namespace-only cleanup
if [ "$NAMESPACE_ONLY" = true ]; then
    if [ "$NAMESPACE_EXISTS" = true ]; then
        log_info "Deleting n8n namespace and associated resources..."
        if kubectl delete namespace n8n --timeout=120s; then
            log_success "Namespace deleted successfully"
        else
            log_warning "Namespace deletion timed out or failed"
        fi
    else
        log_warning "Namespace 'n8n' not found, nothing to delete"
    fi

    log_success "Namespace cleanup complete!"
    exit 0
fi

# Full cleanup
if [ "$CLUSTER_EXISTS" = false ]; then
    log_warning "Cluster '$CLUSTER_NAME' not found in region '$REGION'"
    log_info "Cluster may already be deleted"
else
    # Update kubeconfig if possible
    if aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" --profile "$AWS_PROFILE" &>/dev/null; then
        # Delete n8n namespace first to clean up PVCs
        if [ "$NAMESPACE_EXISTS" = true ]; then
            log_info "Deleting n8n namespace and PVCs..."
            kubectl delete namespace n8n --timeout=120s 2>/dev/null || log_warning "Namespace deletion timed out, continuing..."
        fi
    else
        log_warning "Could not update kubeconfig, skipping namespace deletion"
    fi

    echo ""
    log_info "Waiting for resources to be cleaned up..."
    sleep 15

    # Delete EKS cluster
    log_info "Deleting EKS cluster (this may take 10-15 minutes)..."
    if ! check_command eksctl; then
        error_exit "eksctl is required for cluster deletion"
    fi

    if eksctl delete cluster --region="$REGION" --name="$CLUSTER_NAME" --profile="$AWS_PROFILE" --wait; then
        log_success "Cluster deleted successfully"
    else
        log_warning "Cluster deletion encountered issues or is still in progress"
    fi
fi

# Clean up remaining resources
echo ""
log_info "Cleaning up remaining AWS resources..."

# Clean up orphaned load balancers
log_info "Checking for orphaned LoadBalancers..."
LB_ARNS=$(aws elbv2 describe-load-balancers --region "$REGION" --profile "$AWS_PROFILE" \
    --query 'LoadBalancers[?contains(LoadBalancerName, `n8n`)].LoadBalancerArn' \
    --output text 2>/dev/null || echo "")

if [ -n "$LB_ARNS" ]; then
    while IFS= read -r lb; do
        if [ -n "$lb" ]; then
            log_info "Deleting LoadBalancer: $lb"
            aws elbv2 delete-load-balancer --load-balancer-arn "$lb" \
                --region "$REGION" --profile "$AWS_PROFILE" 2>/dev/null || \
                log_warning "Failed to delete LoadBalancer: $lb"
        fi
    done <<< "$LB_ARNS"
else
    log_info "No orphaned LoadBalancers found"
fi

echo ""
log_success "Cleanup complete!"
echo ""

log_info "Verify cleanup with these commands:"
print_separator
echo "   kubectl get namespace n8n"
echo "   aws eks list-clusters --region $REGION --profile $AWS_PROFILE"
echo "   aws elbv2 describe-load-balancers --region $REGION --profile $AWS_PROFILE"
echo ""
