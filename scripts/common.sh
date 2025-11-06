#!/bin/bash
# Common functions library for n8n deployment scripts
# Source this file in other scripts: source "$(dirname "$0")/common.sh"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}ℹ${NC} $*"
}

log_success() {
    echo -e "${GREEN}✅${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}⚠️${NC}  $*"
}

log_error() {
    echo -e "${RED}❌${NC} $*" >&2
}

# Error handling
error_exit() {
    log_error "$1"
    exit "${2:-1}"
}

# Check if command exists
check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        return 1
    fi
    return 0
}

# Check all required commands
check_prerequisites() {
    local missing_cmds=()

    for cmd in "$@"; do
        if ! check_command "$cmd"; then
            missing_cmds+=("$cmd")
        fi
    done

    if [ ${#missing_cmds[@]} -gt 0 ]; then
        log_error "Missing required commands: ${missing_cmds[*]}"
        log_info "Please install the missing commands and try again."
        return 1
    fi

    return 0
}

# Validate AWS credentials
validate_aws_credentials() {
    local profile="${1:-default}"

    if ! aws sts get-caller-identity --profile "$profile" &>/dev/null; then
        log_error "AWS credentials not configured for profile '$profile'"
        log_info "Run 'aws configure --profile $profile' to set up credentials"
        return 1
    fi

    return 0
}

# Validate AWS region
validate_aws_region() {
    local region="$1"
    local valid_regions

    valid_regions=$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>/dev/null)

    if [ $? -ne 0 ]; then
        log_warning "Could not validate region, continuing anyway..."
        return 0
    fi

    if echo "$valid_regions" | grep -qw "$region"; then
        return 0
    else
        log_error "Invalid AWS region: $region"
        log_info "Run 'aws ec2 describe-regions --query \"Regions[].RegionName\"' to see valid regions"
        return 1
    fi
}

# Check if kubernetes namespace exists
check_namespace() {
    local namespace="$1"

    if ! kubectl get namespace "$namespace" &>/dev/null; then
        return 1
    fi

    return 0
}

# Validate namespace or exit
validate_namespace() {
    local namespace="$1"

    if ! check_namespace "$namespace"; then
        error_exit "Namespace '$namespace' not found. Please deploy first using ./scripts/deploy.sh"
    fi
}

# Check if EKS cluster exists
check_cluster_exists() {
    local cluster_name="$1"
    local region="$2"
    local profile="${3:-default}"

    if aws eks describe-cluster \
        --region "$region" \
        --name "$cluster_name" \
        --profile "$profile" &>/dev/null; then
        return 0
    fi

    return 1
}

# Get pod name by label
get_pod_name() {
    local namespace="$1"
    local label="$2"

    kubectl get pods -n "$namespace" -l "$label" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Wait for pod to be ready
wait_for_pod() {
    local namespace="$1"
    local label="$2"
    local timeout="${3:-300}"

    log_info "Waiting for pod with label '$label' to be ready..."

    if kubectl wait --for=condition=ready \
        --timeout="${timeout}s" \
        pod -l "$label" \
        -n "$namespace" &>/dev/null; then
        return 0
    fi

    return 1
}

# Confirm action with user
confirm_action() {
    local prompt="$1"
    local response

    read -r -p "$prompt (yes/no): " response

    if [ "$response" = "yes" ]; then
        return 0
    fi

    return 1
}

# Get secret value from kubernetes
get_secret_value() {
    local namespace="$1"
    local secret_name="$2"
    local key="$3"

    kubectl get secret "$secret_name" -n "$namespace" \
        -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d
}

# Display usage/help message
show_usage() {
    local script_name="$1"
    shift

    echo "Usage: $script_name $*"
    echo ""
}

# Create backup directory if it doesn't exist
ensure_backup_dir() {
    local backup_dir="${1:-./backups}"

    if [ ! -d "$backup_dir" ]; then
        mkdir -p "$backup_dir" || error_exit "Failed to create backup directory: $backup_dir"
        log_info "Created backup directory: $backup_dir"
    fi
}

# Clean old backups (retention policy)
cleanup_old_backups() {
    local backup_dir="$1"
    local retention_days="${2:-7}"

    if [ ! -d "$backup_dir" ]; then
        return 0
    fi

    log_info "Cleaning up backups older than $retention_days days..."

    find "$backup_dir" -name "n8n-backup-*.sql.gz" -type f -mtime +"$retention_days" -delete

    local count
    count=$(find "$backup_dir" -name "n8n-backup-*.sql.gz" -type f | wc -l)
    log_info "Current backups: $count"
}

# Print separator line
print_separator() {
    echo "────────────────────────────────────────────────────────────"
}

# Print header
print_header() {
    local title="$1"
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    printf "║ %-58s ║\n" "$title"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
}
