#!/bin/bash
# Get logs from n8n or postgres pods
# Usage: ./get-logs.sh [service] [options]

set -euo pipefail

# Get script directory for sourcing common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

# Configuration
NAMESPACE="n8n"
SERVICE="${1:-n8n}"
LINES="100"
FOLLOW=false
ALL_PODS=false

# Display help message
show_help() {
    show_usage "$(basename "$0")" "[service] [options]"
    echo "Arguments:"
    echo "  service           Service to get logs from: n8n, postgres, or all (default: n8n)"
    echo ""
    echo "Options:"
    echo "  -f, --follow      Follow log output (stream logs)"
    echo "  -n, --lines NUM   Number of lines to show (default: 100)"
    echo "  -a, --all         Show logs from all pods"
    echo "  -h, --help        Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./get-logs.sh n8n"
    echo "  ./get-logs.sh postgres -n 50"
    echo "  ./get-logs.sh n8n --follow"
    echo "  ./get-logs.sh all --lines 200"
    exit 0
}

# Parse arguments
if [ $# -eq 0 ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    show_help
fi

# First argument is service if it doesn't start with -
if [[ "${1:-}" != -* ]]; then
    SERVICE="$1"
    shift
fi

# Parse options
while [ $# -gt 0 ]; do
    case "$1" in
        -f|--follow)
            FOLLOW=true
            ;;
        -n|--lines)
            LINES="${2:-100}"
            shift
            ;;
        -a|--all)
            ALL_PODS=true
            ;;
        -h|--help)
            show_help
            ;;
        *)
            log_warning "Unknown option: $1"
            ;;
    esac
    shift
done

# Check prerequisites
check_prerequisites kubectl || error_exit "Prerequisites check failed"

# Validate namespace exists
validate_namespace "$NAMESPACE"

# Function to get logs from a service
get_service_logs() {
    local service_name="$1"
    local label="$2"
    local title="$3"

    print_header "$title"

    if [ "$FOLLOW" = true ]; then
        log_info "Following logs (press Ctrl+C to stop)..."
        kubectl logs -n "$NAMESPACE" -l "$label" -f
    else
        if [ "$ALL_PODS" = true ]; then
            kubectl logs -n "$NAMESPACE" -l "$label" --tail="$LINES" --all-containers=true
        else
            kubectl logs -n "$NAMESPACE" -l "$label" --tail="$LINES"
        fi
    fi
}

# Get logs based on service selection
case "$SERVICE" in
    n8n)
        get_service_logs "n8n" "app=n8n-simple" "📋 n8n Logs (last $LINES lines)"
        ;;
    postgres|postgresql|db)
        get_service_logs "postgres" "app=postgres-simple" "📋 PostgreSQL Logs (last $LINES lines)"
        ;;
    all)
        log_info "Fetching logs from all services..."
        echo ""
        get_service_logs "n8n" "app=n8n-simple" "📋 n8n Logs (last $LINES lines)"
        echo ""
        print_separator
        echo ""
        get_service_logs "postgres" "app=postgres-simple" "📋 PostgreSQL Logs (last $LINES lines)"
        ;;
    *)
        error_exit "Unknown service: $SERVICE\n\nValid services: n8n, postgres, all\nUse --help for more information"
        ;;
esac

