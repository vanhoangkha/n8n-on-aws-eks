#!/bin/bash
# Backup script for n8n database
# Usage: ./backup.sh [backup-directory] [retention-days]

set -euo pipefail

# Get script directory for sourcing common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

# Configuration
NAMESPACE="n8n"
BACKUP_DIR="${1:-${SCRIPT_DIR}/../backups}"
RETENTION_DAYS="${2:-7}"

# Display help message
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    show_usage "$(basename "$0")" "[backup-directory] [retention-days]"
    echo "Arguments:"
    echo "  backup-directory    Directory to store backups (default: ../backups)"
    echo "  retention-days      Number of days to keep backups (default: 7)"
    echo ""
    echo "Examples:"
    echo "  ./backup.sh"
    echo "  ./backup.sh /path/to/backups 14"
    exit 0
fi

print_header "📦 n8n Database Backup"

# Check prerequisites
log_info "Checking prerequisites..."
check_prerequisites kubectl || error_exit "Prerequisites check failed"

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

# Ensure backup directory exists
ensure_backup_dir "$BACKUP_DIR"

# Get database credentials from secret
log_info "Retrieving database credentials..."
DB_USER=$(get_secret_value "$NAMESPACE" "postgres-secret" "POSTGRES_USER")
DB_NAME=$(get_secret_value "$NAMESPACE" "postgres-secret" "POSTGRES_DB")
DB_PASS=$(get_secret_value "$NAMESPACE" "postgres-secret" "POSTGRES_PASSWORD")

if [ -z "$DB_USER" ] || [ -z "$DB_NAME" ] || [ -z "$DB_PASS" ]; then
    error_exit "Failed to retrieve database credentials from secret"
fi

# Generate backup filename with timestamp
BACKUP_FILE="n8n-backup-$(date +%Y%m%d-%H%M%S).sql"
BACKUP_FILE_GZ="${BACKUP_FILE}.gz"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_FILE_GZ}"

log_info "Creating backup: $BACKUP_FILE_GZ"

# Execute backup
if kubectl exec -n "$NAMESPACE" "$POD" -- \
    env PGPASSWORD="$DB_PASS" pg_dump -U "$DB_USER" "$DB_NAME" | gzip > "$BACKUP_PATH"; then

    # Verify backup file was created and has content
    if [ -f "$BACKUP_PATH" ] && [ -s "$BACKUP_PATH" ]; then
        FILE_SIZE=$(du -h "$BACKUP_PATH" | cut -f1)
        log_success "Backup created successfully!"
        echo ""
        log_info "Backup Details:"
        print_separator
        echo "   File: $BACKUP_FILE_GZ"
        echo "   Size: $FILE_SIZE"
        echo "   Location: $BACKUP_PATH"
        echo ""

        log_info "To restore this backup:"
        echo "   ./scripts/restore.sh $BACKUP_PATH"
        echo ""

        # Clean up old backups
        cleanup_old_backups "$BACKUP_DIR" "$RETENTION_DAYS"

        log_success "Backup process completed"
    else
        error_exit "Backup file was not created or is empty"
    fi
else
    error_exit "Backup command failed"
fi

