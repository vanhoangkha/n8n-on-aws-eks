#!/bin/bash
# Restore script for n8n database
# Usage: ./restore.sh <backup-file.sql.gz> [--skip-backup]

set -euo pipefail

# Get script directory for sourcing common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

# Configuration
NAMESPACE="n8n"
SKIP_BACKUP=false

# Parse arguments
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    show_usage "$(basename "$0")" "<backup-file.sql.gz> [--skip-backup]"
    echo "Arguments:"
    echo "  backup-file.sql.gz    Path to the backup file to restore"
    echo "  --skip-backup         Skip creating a backup before restore (not recommended)"
    echo ""
    echo "Examples:"
    echo "  ./restore.sh backups/n8n-backup-20241201-120000.sql.gz"
    echo "  ./restore.sh n8n-backup.sql.gz --skip-backup"
    exit 0
fi

if [ -z "${1:-}" ]; then
    error_exit "Backup file not specified\n\nUsage: ./restore.sh <backup-file.sql.gz>"
fi

BACKUP_FILE="$1"
shift

# Check for --skip-backup flag
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-backup)
            SKIP_BACKUP=true
            ;;
        *)
            log_warning "Unknown option: $1"
            ;;
    esac
    shift
done

# Validate backup file exists
if [ ! -f "$BACKUP_FILE" ]; then
    error_exit "Backup file not found: $BACKUP_FILE"
fi

# Validate backup file is not empty
if [ ! -s "$BACKUP_FILE" ]; then
    error_exit "Backup file is empty: $BACKUP_FILE"
fi

print_header "📦 n8n Database Restore"

log_warning "WARNING: This will replace the current database!"
echo "   Backup file: $BACKUP_FILE"
echo "   This action cannot be undone!"
echo ""

# Confirm with user
if ! confirm_action "Are you sure you want to continue?"; then
    log_info "Restore cancelled by user"
    exit 0
fi

echo ""

# Check prerequisites
log_info "Checking prerequisites..."
check_prerequisites kubectl gunzip || error_exit "Prerequisites check failed"

# Validate namespace exists
log_info "Validating namespace..."
validate_namespace "$NAMESPACE"

# Get the postgres pod name
log_info "Finding PostgreSQL pod..."
POD=$(get_pod_name "$NAMESPACE" "app=postgres-simple")

if [ -z "$POD" ]; then
    error_exit "PostgreSQL pod not found in namespace '$NAMESPACE'"
fi

log_success "Using PostgreSQL pod: $POD"

# Get database credentials from secret
log_info "Retrieving database credentials..."
DB_USER=$(get_secret_value "$NAMESPACE" "postgres-secret" "POSTGRES_USER")
DB_NAME=$(get_secret_value "$NAMESPACE" "postgres-secret" "POSTGRES_DB")
DB_PASS=$(get_secret_value "$NAMESPACE" "postgres-secret" "POSTGRES_PASSWORD")

if [ -z "$DB_USER" ] || [ -z "$DB_NAME" ] || [ -z "$DB_PASS" ]; then
    error_exit "Failed to retrieve database credentials from secret"
fi

# Create pre-restore backup unless skipped
if [ "$SKIP_BACKUP" = false ]; then
    log_info "Creating pre-restore backup (recommended safety measure)..."
    PRE_RESTORE_BACKUP="${SCRIPT_DIR}/../backups/pre-restore-$(date +%Y%m%d-%H%M%S).sql.gz"
    ensure_backup_dir "$(dirname "$PRE_RESTORE_BACKUP")"

    if kubectl exec -n "$NAMESPACE" "$POD" -- \
        env PGPASSWORD="$DB_PASS" pg_dump -U "$DB_USER" "$DB_NAME" | gzip > "$PRE_RESTORE_BACKUP"; then
        log_success "Pre-restore backup created: $PRE_RESTORE_BACKUP"
    else
        log_warning "Pre-restore backup failed, but continuing with restore..."
    fi
else
    log_warning "Skipping pre-restore backup (as requested)"
fi

# Scale down n8n to prevent connections
log_info "Scaling down n8n to prevent active connections..."
kubectl scale deployment n8n-simple --replicas=0 -n "$NAMESPACE"

log_info "Waiting for n8n pods to terminate..."
kubectl wait --for=delete pod -l app=n8n-simple -n "$NAMESPACE" --timeout=60s 2>/dev/null || true

# Restore the database
log_info "Restoring database from backup..."
if gunzip -c "$BACKUP_FILE" | kubectl exec -i -n "$NAMESPACE" "$POD" -- \
    env PGPASSWORD="$DB_PASS" psql -U "$DB_USER" "$DB_NAME" >/dev/null 2>&1; then

    log_success "Database restore completed successfully!"
    echo ""

    # Scale up n8n
    log_info "Scaling up n8n deployment..."
    kubectl scale deployment n8n-simple --replicas=1 -n "$NAMESPACE"

    echo ""
    log_success "n8n is being restored and will be available shortly"
    log_info "Monitor status with: kubectl get pods -n $NAMESPACE"

    if [ "$SKIP_BACKUP" = false ] && [ -n "${PRE_RESTORE_BACKUP:-}" ]; then
        echo ""
        log_info "Pre-restore backup is available at:"
        echo "   $PRE_RESTORE_BACKUP"
    fi
else
    log_error "Database restore failed!"
    log_info "Scaling n8n back up..."
    kubectl scale deployment n8n-simple --replicas=1 -n "$NAMESPACE"

    if [ "$SKIP_BACKUP" = false ] && [ -n "${PRE_RESTORE_BACKUP:-}" ]; then
        echo ""
        log_info "Your pre-restore backup is available at:"
        echo "   $PRE_RESTORE_BACKUP"
    fi

    error_exit "Restore process failed"
fi

