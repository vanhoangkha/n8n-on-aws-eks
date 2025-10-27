#!/bin/bash
# Manual restore script for n8n database

if [ -z "$1" ]; then
  echo "❌ Error: Backup file not specified"
  echo ""
  echo "Usage: ./restore.sh <backup-file.sql.gz>"
  echo "Example: ./restore.sh n8n-backup-20241201-120000.sql.gz"
  exit 1
fi

BACKUP_FILE="$1"

if [ ! -f "$BACKUP_FILE" ]; then
  echo "❌ Error: Backup file '$BACKUP_FILE' not found"
  exit 1
fi

echo "⚠️  WARNING: This will replace the current database!"
echo "   Backup file: $BACKUP_FILE"
echo "   This action cannot be undone!"
echo ""
read -p "Are you sure you want to continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
  echo "❌ Restore cancelled."
  exit 0
fi

echo ""
echo "📦 Restoring n8n database..."
echo ""

# Get the postgres pod name
POD=$(kubectl get pods -n n8n -l app=postgres-simple -o jsonpath='{.items[0].metadata.name}')

if [ -z "$POD" ]; then
  echo "❌ Error: PostgreSQL pod not found"
  exit 1
fi

echo "📌 Using PostgreSQL pod: $POD"
echo ""

# Get database credentials from secret
DB_USER=$(kubectl get secret postgres-secret -n n8n -o jsonpath='{.data.POSTGRES_USER}' | base64 -d)
DB_NAME=$(kubectl get secret postgres-secret -n n8n -o jsonpath='{.data.POSTGRES_DB}' | base64 -d)
DB_PASS=$(kubectl get secret postgres-secret -n n8n -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)

# Scale down n8n to prevent connections
echo "⏸️  Scaling down n8n to prevent active connections..."
kubectl scale deployment n8n-simple --replicas=0 -n n8n

echo "⏳ Waiting for n8n pods to terminate..."
kubectl wait --for=delete pod -l app=n8n-simple -n n8n --timeout=60s || true

# Restore the database
echo "🔄 Restoring database from backup..."
gunzip -c "$BACKUP_FILE" | kubectl exec -i -n n8n $POD -- env PGPASSWORD=$DB_PASS psql -U $DB_USER $DB_NAME

if [ $? -eq 0 ]; then
  echo "✅ Restore completed successfully!"
  echo ""
  
  # Scale up n8n
  echo "▶️  Scaling up n8n..."
  kubectl scale deployment n8n-simple --replicas=1 -n n8n
  
  echo ""
  echo "✅ n8n is being restored and will be available shortly."
  echo "   Monitor with: kubectl get pods -n n8n"
else
  echo "❌ Restore failed!"
  kubectl scale deployment n8n-simple --replicas=1 -n n8n
  exit 1
fi

