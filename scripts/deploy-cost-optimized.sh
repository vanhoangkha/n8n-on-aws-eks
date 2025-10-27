#!/bin/bash

REGION=${REGION:-ap-southeast-1}
CLUSTER_NAME=${CLUSTER_NAME:-n8n-cluster}
AWS_PROFILE=${AWS_PROFILE:-default}

echo "🚀 Deploying ultra cost-optimized n8n to $REGION..."

# Create cluster with spot instances
eksctl create cluster -f infrastructure/cost-optimized-cluster.yaml --profile=$AWS_PROFILE

# Deploy n8n with reduced resources
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f manifests/01-postgres-secret.yaml

# Deploy PostgreSQL with minimal resources
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-simple
  namespace: n8n
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
        env:
        - name: POSTGRES_DB
          value: n8n
        - name: POSTGRES_USER
          value: n8nuser
        - name: POSTGRES_PASSWORD
          value: n8n-secure-password-2024
        volumeMounts:
        - name: postgres-storage
          mountPath: /var/lib/postgresql/data
      volumes:
      - name: postgres-storage
        emptyDir: {}
EOF

kubectl apply -f manifests/04-postgres-service.yaml

# Deploy n8n with minimal resources
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: n8n-simple
  namespace: n8n
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
          value: n8n
        - name: DB_POSTGRESDB_USER
          value: n8nuser
        - name: DB_POSTGRESDB_PASSWORD
          value: n8n-secure-password-2024
        ports:
        - containerPort: 5678
        volumeMounts:
        - name: n8n-storage
          mountPath: /home/node/.n8n
      volumes:
      - name: n8n-storage
        emptyDir: {}
EOF

kubectl apply -f manifests/07-n8n-service.yaml

echo "✅ Ultra cost-optimized deployment complete!"
echo "💰 Estimated monthly cost: ~$104-108"
