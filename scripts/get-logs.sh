#!/bin/bash
# Get logs from n8n or postgres pods

SERVICE="${1:-n8n}"
LINES="${2:-100}"

if [ "$SERVICE" = "n8n" ]; then
  echo "📋 Fetching n8n logs (last $LINES lines)..."
  echo ""
  kubectl logs -n n8n -l app=n8n-simple --tail=$LINES
elif [ "$SERVICE" = "postgres" ]; then
  echo "📋 Fetching PostgreSQL logs (last $LINES lines)..."
  echo ""
  kubectl logs -n n8n -l app=postgres-simple --tail=$LINES
else
  echo "Usage: ./get-logs.sh [n8n|postgres] [lines]"
  echo ""
  echo "Examples:"
  echo "  ./get-logs.sh n8n 100     # Get last 100 lines from n8n"
  echo "  ./get-logs.sh postgres 50 # Get last 50 lines from postgres"
  exit 1
fi

