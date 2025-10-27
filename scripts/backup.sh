#!/bin/bash
# Manual backup script for n8n database

echo "📦 Creating manual backup of n8n database..."
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

# Generate backup filename with timestamp
BACKUP_FILE="n8n-backup-$(date +%Y%m%d-%H%M%S).sql"
BACKUP_FILE_GZ="${BACKUP_FILE}.gz"

echo "🔄 Creating backup file: $BACKUP_FILE_GZ"
echo ""

# Execute backup
kubectl exec -n n8n $POD -- env PGPASSWORD=$DB_PASS pg_dump -U $DB_USER $DB_NAME | gzip > $BACKUP_FILE_GZ

if [ $? -eq 0 ]; then
  FILE_SIZE=$(du -h $BACKUP_FILE_GZ | cut -f1)
  echo "✅ Backup created successfully!"
  echo "   File: $BACKUP_FILE_GZ"
  echo "   Size: $FILE_SIZE"
  echo ""
  echo "💾 Backup location: $(pwd)/$BACKUP_FILE_GZ"
  echo ""
  echo "📋 To restore this backup:"
  echo "   ./scripts/restore.sh $BACKUP_FILE_GZ"
else
  echo "❌ Backup failed!"
  exit 1
fi

