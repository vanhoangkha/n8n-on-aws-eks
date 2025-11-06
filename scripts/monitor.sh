#!/bin/bash
# Monitor n8n deployment status
# Usage: ./monitor.sh [options]

set -euo pipefail

# Get script directory for sourcing common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

# Configuration
NAMESPACE="n8n"
WATCH_MODE=false
WATCH_INTERVAL=5

# Display help message
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    show_usage "$(basename "$0")" "[options]"
    echo "Options:"
    echo "  -w, --watch       Continuous monitoring mode (refresh every 5 seconds)"
    echo "  -i, --interval N  Set watch interval in seconds (default: 5, requires -w)"
    echo "  -h, --help        Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./monitor.sh"
    echo "  ./monitor.sh --watch"
    echo "  ./monitor.sh -w -i 10"
    exit 0
fi

# Parse options
while [ $# -gt 0 ]; do
    case "$1" in
        -w|--watch)
            WATCH_MODE=true
            ;;
        -i|--interval)
            WATCH_INTERVAL="${2:-5}"
            shift
            ;;
        *)
            log_warning "Unknown option: $1"
            ;;
    esac
    shift
done

# Check prerequisites
check_prerequisites kubectl || error_exit "Prerequisites check failed"

# Check if namespace exists
if ! check_namespace "$NAMESPACE"; then
    error_exit "Namespace '$NAMESPACE' not found. Please deploy first using ./scripts/deploy.sh"
fi

# Function to display monitoring information
display_monitoring_info() {
    print_header "📊 n8n Monitoring Dashboard"

    echo "🔍 PODS STATUS:"
    print_separator
    kubectl get pods -n "$NAMESPACE" -o wide

    echo ""
    echo "📊 POD DETAILS:"
    print_separator
    for pod in $(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}'); do
        echo ""
        echo "📦 $pod"
        kubectl describe pod "$pod" -n "$NAMESPACE" 2>/dev/null | grep -A 5 "Status:" | head -6 || true
        kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='  Restarts: {.status.containerStatuses[0].restartCount}' 2>/dev/null && echo "" || true
    done

    echo ""
    echo "🌐 SERVICES:"
    print_separator
    kubectl get services -n "$NAMESPACE"

    echo ""
    echo "💾 PERSISTENT VOLUMES:"
    print_separator
    kubectl get pvc -n "$NAMESPACE" 2>/dev/null || echo "No PVCs found"

    echo ""
    echo "📈 RESOURCE USAGE:"
    print_separator
    if kubectl top pods -n "$NAMESPACE" 2>/dev/null; then
        echo ""
        echo "Node Resource Usage:"
        kubectl top nodes 2>/dev/null || true
    else
        log_warning "Metrics server not available. Install metrics server to see resource usage."
    fi

    echo ""
    echo "🔐 RECENT EVENTS:"
    print_separator
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null | tail -10 || echo "No events found"

    echo ""
    echo "🔗 ACCESS URL:"
    print_separator
    URL=$(kubectl get service n8n-service-simple -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
    if [ -n "$URL" ]; then
        log_success "n8n is accessible at: http://${URL}"
    else
        log_warning "LoadBalancer URL is still pending..."
        echo "   Check with: kubectl get service n8n-service-simple -n $NAMESPACE"
    fi

    echo ""
    echo "📋 QUICK COMMANDS:"
    print_separator
    echo "  View logs:       ./scripts/get-logs.sh n8n --follow"
    echo "  Restart:         kubectl rollout restart deployment/n8n-simple -n $NAMESPACE"
    echo "  Scale:           kubectl scale deployment n8n-simple --replicas=2 -n $NAMESPACE"
    echo "  Create backup:   ./scripts/backup.sh"
    echo ""
}

# Main execution
if [ "$WATCH_MODE" = true ]; then
    log_info "Starting continuous monitoring (refresh every ${WATCH_INTERVAL}s, press Ctrl+C to stop)..."
    echo ""

    while true; do
        clear
        display_monitoring_info
        sleep "$WATCH_INTERVAL"
    done
else
    display_monitoring_info
fi
